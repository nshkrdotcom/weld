defmodule Weld.Affected do
  @moduledoc """
  Computes affected projects for one task using Git file diffs and reverse
  dependency traversal.
  """

  alias Weld.Git
  alias Weld.Plan
  alias Weld.Plan.Inventory
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

    members = Enum.uniq(plan.selected_ids ++ plan.verification_ids ++ plan.inventory_member_ids)
    source_matches = matching_inventory(plan, changed_files)
    global_change? = Enum.any?(ownership, &global_change?(plan, &1))
    external_projects = Enum.filter(direct_projects, &(&1 in plan.artifact.external_projects))
    directly_affected = Enum.filter(direct_projects, &(&1 in members))

    affected_projects =
      cond do
        global_change? ->
          Enum.sort(Enum.uniq(plan.selected_ids ++ plan.verification_ids))

        source_matches != [] and plan.artifact.mode == :source_project ->
          [hd(plan.artifact.roots) | directly_affected] |> Enum.uniq() |> Enum.sort()

        true ->
          affected_by_membership(plan, directly_affected, source_matches)
      end

    %{
      task: task,
      base: base,
      head: head,
      changed_files: changed_files,
      direct_projects: direct_projects,
      affected_projects: affected_projects,
      source_changes: source_matches,
      external_dependency_projects: external_projects,
      global_change?: global_change?
    }
  end

  defp global_change?(plan, {path, owner}) do
    absolute = Path.join(plan.manifest.repo_root, path)

    absolute == plan.manifest.manifest_path or path in plan.structural_inputs or
      owner in [:global, :unknown] or
      (owner == {:project, "."} and "." not in plan.artifact.external_projects)
  end

  defp matching_inventory(plan, paths) do
    for path <- paths,
        entry <- plan.source_roots,
        path == entry.source or (entry.directory and Inventory.covered?(path, entry.source)) do
      %{path: path, owner: source_owner(plan, path), kind: entry.kind}
    end
    |> Enum.uniq()
  end

  defp source_owner(plan, path) do
    case Workspace.file_owner(plan.workspace, Path.join(plan.manifest.repo_root, path)) do
      {:project, id} -> id
      _ -> nil
    end
  end

  defp affected_by_membership(plan, projects, matches) do
    graph = plan.artifact_graph || plan.graph
    selected = plan.selected_ids ++ plan.verification_ids
    view = if plan.verification_ids == [], do: :package, else: :test

    graph_projects =
      graph
      |> Weld.Graph.reaching(projects, view)
      |> Enum.filter(&(&1 in selected))

    linked_projects =
      if Enum.any?(matches, &(&1.owner not in selected)) do
        plan.selected_ids
      else
        Enum.filter(projects, &(&1 in selected))
      end

    Enum.uniq(graph_projects ++ linked_projects) |> Enum.sort()
  end
end
