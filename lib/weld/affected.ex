defmodule Weld.Affected do
  @moduledoc """
  Computes affected projects for one task using Git file diffs and reverse
  dependency traversal.
  """

  alias Weld.Git
  alias Weld.Plan
  alias Weld.Plan.Inventory
  alias Weld.Workspace

  @doc "Compare one batch snapshot of each genuine Git tree, including removed artifacts."
  def compare!(manifest_path, opts) do
    root =
      Git.root(opts[:root] || Path.dirname(Path.expand(manifest_path))) ||
        raise(Weld.Error,
          code: :git_required,
          message: "affected requires Git; pass --root for the checkout"
        )

    relative = Path.relative_to(Path.expand(manifest_path), root)
    Weld.Core.Inventory.validate_path!(relative)
    base = resolve_revision!(root, Keyword.fetch!(opts, :base))
    head = resolve_revision!(root, Keyword.fetch!(opts, :head))
    task = Keyword.get(opts, :task, "verify")
    before = snapshot(root, base, relative, opts)
    after_ = snapshot(root, head, relative, opts)
    changed = changed_files(root, before.revision, after_.revision)

    ids =
      if opts[:artifact],
        do: [opts[:artifact]],
        else: Enum.sort(Enum.uniq(Map.keys(before.plans) ++ Map.keys(after_.plans)))

    common = %{
      base: before.revision,
      head: after_.revision,
      task: task,
      changed_files: changed.files
    }

    errors = List.wrap(before[:error]) ++ List.wrap(after_[:error]) ++ List.wrap(changed[:error])

    results =
      Enum.map(ids, fn id ->
        report =
          artifact_report(
            id,
            before.plans[id],
            after_.plans[id],
            relative,
            changed.files,
            common,
            errors,
            opts
          )

        %{artifact: id, ok: true, data: report}
      end)

    if opts[:artifact] do
      hd(results).data
    else
      Map.merge(common, %{
        results: results,
        affected_artifacts: for(%{artifact: id, data: %{affected?: true}} <- results, do: id),
        affected?: errors != [] or Enum.any?(results, & &1.data.affected?),
        unknown?: errors != [] or Enum.any?(results, & &1.data.unknown?),
        reasons: errors,
        partial_failure: false
      })
    end
  end

  defp artifact_report(id, old, new, relative, changed, common, errors, opts) do
    plan_errors =
      Enum.flat_map([old, new], fn
        %{error: error} -> [error]
        _ -> []
      end)

    cond do
      errors != [] or plan_errors != [] ->
        Map.merge(common, %{
          artifact: id,
          affected?: true,
          unknown?: true,
          reasons: errors ++ plan_errors,
          direct_projects: [],
          affected_projects: []
        })

      is_nil(old) or is_nil(new) ->
        artifact_membership_change(id, old, new, common)

      true ->
        compare_plans(id, old, new, relative, changed, common, opts)
    end
  end

  defp artifact_membership_change(id, old, new, common) do
    {plan, reason} =
      case {old, new} do
        {nil, nil} -> {nil, :artifact_unavailable}
        {nil, added} -> {added, :artifact_added}
        {removed, nil} -> {removed, :artifact_removed}
      end

    Map.merge(common, %{
      artifact: id,
      affected?: true,
      unknown?: is_nil(plan),
      reasons: [reason],
      direct_projects: [],
      affected_projects: if(plan, do: plan.selected_ids, else: [])
    })
  end

  defp compare_plans(id, before, after_, relative, changed, common, opts) do
    role = affected_role(common.task)
    expected = Weld.Core.Inventory.view(before.output_inventory, role)
    observed = Weld.Core.Inventory.view(after_.output_inventory, role)

    delta =
      Weld.Core.Inventory.diff(expected, Map.new(observed, &{&1.target, &1}))
      |> Enum.reject(&(&1.state == :identical))

    structural = Enum.uniq(before.structural_inputs ++ after_.structural_inputs)
    structural_changed? = relative in changed or Enum.any?(changed, &(&1 in structural))
    contributors = for entry <- expected ++ observed, input <- entry.inputs, do: input.source
    relevant = Enum.filter(changed, &(&1 in contributors or &1 in structural or &1 == relative))
    options = Keyword.merge(opts, base: common.base, head: common.head, task: common.task)
    old_report = run!(before, Keyword.put(options, :changed_files, relevant))
    new_report = run!(after_, Keyword.put(options, :changed_files, relevant))
    projects = Enum.sort(Enum.uniq(old_report.affected_projects ++ new_report.affected_projects))
    revision_changed? = common.base != common.head

    opaque? = Enum.any?([before, after_], &opaque_inputs?/1)
    release_changed? = common.task == "release" and revision_changed?
    affected? = opaque? or delta != [] or structural_changed? or release_changed?
    projects = if opaque?, do: possible_contributors(before, after_), else: projects

    Map.merge(common, %{
      artifact: id,
      affected?: affected?,
      unknown?: opaque?,
      content_changed: delta != [],
      source_revision_changed: revision_changed?,
      structural_changed?: structural_changed?,
      entries: delta,
      reasons: affected_reasons(opaque?, release_changed?),
      direct_projects:
        Enum.sort(Enum.uniq(old_report.direct_projects ++ new_report.direct_projects)),
      affected_projects: if(affected?, do: projects, else: [])
    })
  end

  defp affected_role("package"), do: :package
  defp affected_role("docs"), do: :docs
  defp affected_role("project"), do: :project
  defp affected_role(_), do: :verify

  defp opaque_inputs?(plan) do
    Enum.any?(Inventory.portable(plan)["inputs"], fn input ->
      input["kind"] == "external" and input["fact"]["opaque"]
    end)
  end

  defp possible_contributors(before, after_) do
    [before, after_]
    |> Enum.flat_map(&(&1.selected_ids ++ &1.verification_ids ++ &1.inventory_member_ids))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp affected_reasons(opaque?, release_changed?) do
    for {reason, true} <- [opaque_inputs: opaque?, source_revision_changed: release_changed?],
        do: reason
  end

  defp resolve_revision!(root, ref) do
    case Git.run(root, ["rev-parse", "--verify", "--end-of-options", ref <> "^{commit}"]) do
      {:ok, revision} ->
        revision = String.trim(revision)

        unless Regex.match?(~r/\A[0-9a-f]{40,64}\z/, revision),
          do:
            raise(Weld.Error,
              code: :invalid_arguments,
              message: "invalid Git revision #{inspect(ref)}"
            )

        revision

      _ ->
        raise Weld.Error,
          code: :invalid_arguments,
          message: "invalid Git revision #{inspect(ref)}"
    end
  end

  defp snapshot(root, ref, relative, opts) do
    Git.with_tree!(root, ref, fn directory, commit ->
      try do
        manifest = Weld.Manifest.load!(Path.join(directory, relative), checkout_root: directory)
        workspace = Workspace.load!(manifest, Keyword.put(opts, :checkout_root, directory))

        ids =
          if opts[:artifact],
            do: Enum.filter(Map.keys(manifest.artifacts), &(&1 == opts[:artifact])),
            else: Map.keys(manifest.artifacts)

        plans =
          ids
          |> Enum.sort()
          |> Map.new(fn id ->
            plan =
              try do
                plan =
                  Plan.build_from_workspace!(
                    manifest,
                    workspace,
                    Keyword.put(opts, :artifact, id)
                  )
                  |> Plan.ensure_valid!()

                _ = Inventory.portable(plan)
                plan
              rescue
                error -> %{error: Exception.message(error)}
              end

            {id, plan}
          end)

        %{revision: commit, plans: plans}
      rescue
        error ->
          %{revision: commit, plans: %{}, error: Exception.message(error)}
      end
    end)
  rescue
    error ->
      %{revision: ref, plans: %{}, error: Exception.message(error)}
  end

  defp changed_files(root, base, head) do
    %{files: Git.changed_files(root, base, head)}
  rescue
    error -> %{files: [], error: Exception.message(error)}
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
