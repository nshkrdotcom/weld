defmodule Weld.Affected do
  @moduledoc """
  Computes affected projects for one task using Git file diffs and reverse
  dependency traversal.
  """

  alias Weld.Git
  alias Weld.Plan
  alias Weld.Plan.Inventory
  alias Weld.Workspace

  @doc "Compare independently planned Git snapshots, without checking out either revision."
  def compare!(manifest_path, opts) do
    root =
      Git.root(Path.dirname(Path.expand(manifest_path))) ||
        raise(Weld.Error, "affected requires Git")

    relative = Path.relative_to(Path.expand(manifest_path), root)
    base = Keyword.fetch!(opts, :base)
    head = Keyword.fetch!(opts, :head)
    task = Keyword.get(opts, :task, "verify")

    snapshots =
      for ref <- [base, head] do
        Git.with_tree!(root, ref, fn directory, commit ->
          try do
            plan = Plan.build!(Path.join(directory, relative), opts)
            entries = Map.new(plan.output_inventory, &{&1.target, &1})
            %{revision: commit, plan: plan, entries: entries}
          rescue
            error in [Weld.Error, File.Error, ArgumentError, KeyError] ->
              %{revision: commit, error: Exception.message(error)}
          end
        end)
      end

    [before, after_] = snapshots
    changed = Git.changed_files(root, before.revision, after_.revision)

    if Map.has_key?(before, :error) or Map.has_key?(after_, :error) do
      %{
        base: before.revision,
        head: after_.revision,
        task: task,
        changed_files: changed,
        affected?: true,
        unknown?: true,
        reasons: Enum.flat_map(snapshots, &List.wrap(&1[:error]))
      }
    else
      role = if task in ["package", "publish"], do: :package, else: :verify
      expected = Weld.Core.Inventory.view(before.plan.output_inventory, role)

      actual =
        after_.plan.output_inventory
        |> Weld.Core.Inventory.view(role)
        |> Map.new(&{&1.target, &1})

      delta = Weld.Core.Inventory.diff(expected, actual) |> Enum.reject(&(&1.state == :identical))
      structural = Enum.uniq(before.plan.structural_inputs ++ after_.plan.structural_inputs)
      structural_changed? = relative in changed or Enum.any?(changed, &(&1 in structural))

      old_report =
        run!(
          before.plan,
          Keyword.merge(opts,
            base: before.revision,
            head: after_.revision,
            task: task,
            changed_files: changed
          )
        )

      new_report =
        run!(
          after_.plan,
          Keyword.merge(opts,
            base: before.revision,
            head: after_.revision,
            task: task,
            changed_files: changed
          )
        )

      projects =
        Enum.sort(Enum.uniq(old_report.affected_projects ++ new_report.affected_projects))

      %{
        base: before.revision,
        head: after_.revision,
        task: task,
        changed_files: changed,
        affected?: delta != [] or structural_changed? or projects != [],
        unknown?: false,
        structural_changed?: structural_changed?,
        entries: delta,
        affected_projects: projects
      }
    end
  end

  @spec run!(Plan.t(), keyword()) :: map()
  def run!(%Plan{} = plan, opts) do
    base = Keyword.fetch!(opts, :base)
    head = Keyword.fetch!(opts, :head)
    task = Keyword.fetch!(opts, :task)

    changed_files =
      Keyword.get_lazy(opts, :changed_files, fn ->
        Git.changed_files(plan.manifest.repo_root, base, head)
      end)

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
    exact =
      for path <- paths, entry <- plan.source_inventory, path == entry.source do
        %{path: path, owner: source_owner(plan, path), kind: entry.kind, target: entry.target}
      end

    # Directory membership covers paths absent in the current tree (add/delete/rename).
    roots =
      for path <- paths,
          not Enum.any?(exact, &(&1.path == path)),
          entry <- plan.source_roots,
          path == entry.source or (entry.directory and Inventory.covered?(path, entry.source)) do
        %{path: path, owner: source_owner(plan, path), kind: entry.kind}
      end

    Enum.uniq(exact ++ roots)
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
