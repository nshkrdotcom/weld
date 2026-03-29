defmodule Weld.Affected do
  @moduledoc """
  Computes affected projects for one task using Git file diffs and reverse
  dependency traversal.
  """

  alias Weld.Git
  alias Weld.Plan
  alias Weld.Workspace

  @spec run!(Plan.t(), keyword()) :: map()
  def run!(%Plan{} = plan, opts) do
    base = Keyword.fetch!(opts, :base)
    head = Keyword.fetch!(opts, :head)
    task = Keyword.fetch!(opts, :task)

    changed_files = Git.changed_files(plan.manifest.repo_root, base, head)

    ownership =
      Enum.map(changed_files, fn relative ->
        abs = Path.join(plan.manifest.repo_root, relative)
        {relative, Workspace.file_owner(plan.workspace, abs)}
      end)

    direct_projects =
      ownership
      |> Enum.flat_map(fn
        {_relative, {:project, project_id}} -> [project_id]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    global_change? =
      Enum.any?(ownership, fn
        {_relative, :global} -> true
        {_relative, :unknown} -> true
        _ -> false
      end)

    affected_projects =
      cond do
        global_change? ->
          plan.selected_ids

        direct_projects == [] ->
          []

        true ->
          plan.graph
          |> Weld.Graph.reaching(direct_projects, :package)
          |> Enum.filter(&(&1 in plan.selected_ids))
      end

    %{
      task: task,
      base: base,
      head: head,
      changed_files: changed_files,
      direct_projects: direct_projects,
      affected_projects: affected_projects,
      global_change?: global_change?
    }
  end
end
