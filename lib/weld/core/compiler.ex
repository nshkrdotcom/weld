defmodule Weld.Core.Compiler do
  @moduledoc "Deterministic artifact compilation from supplied manifest, graph and source facts."
  alias Weld.Core.{Facts, Selection}
  alias Weld.Core.Inventory, as: CoreInventory
  alias Weld.{Error, Graph, Violation}
  alias Weld.Layout.{Components, Flat, Preserve}
  alias Weld.Plan.Boundary
  alias Weld.Plan.Inventory
  alias Weld.Core.Inputs
  @doc false
  def compile!(manifest, workspace, artifact, _opts) do
    graph = workspace.graph

    seed_ids =
      artifact.roots
      |> Kernel.++(artifact.include)
      |> Kernel.++(Selection.optional_feature_projects(manifest, artifact.optional_features))
      |> Enum.uniq()
      |> Enum.sort()

    selection_violations =
      seed_ids
      |> Enum.reject(&Map.has_key?(workspace.projects, &1))
      |> Enum.map(fn project_id ->
        Violation.new(:missing_project, "artifact references a project that was not discovered",
          project: project_id
        )
      end)

    known_seeds = Enum.filter(seed_ids, &Map.has_key?(workspace.projects, &1))
    source_projects = Selection.source_projects!(artifact, workspace.projects)

    {artifact_graph, externalized_edges, boundary_violations} =
      Boundary.build(workspace, artifact, known_seeds)

    dependency_ids = Graph.reachable_from(artifact_graph, known_seeds, :package)
    selected_projects = Selection.projects_for_ids(workspace, artifact_graph, dependency_ids)

    test_graph = Selection.graph_for_view(artifact_graph, artifact, dependency_ids, :test)

    verification_projects =
      Selection.verification_projects(workspace, test_graph, artifact, dependency_ids)

    {source_roots, source_inventory} =
      Inventory.build(
        workspace,
        artifact,
        source_projects,
        selected_projects,
        verification_projects
      )

    compiled = Selection.owners(source_roots ++ source_inventory, [:compiled])

    source_member_ids =
      if artifact.mode == :source_project do
        Selection.sorted_difference(
          compiled,
          dependency_ids ++ Enum.map(verification_projects, & &1.id)
        )
      else
        Enum.uniq(compiled) |> Enum.sort()
      end

    selected_ids = Enum.uniq(dependency_ids ++ source_member_ids) |> Enum.sort()

    test_owners = Selection.owners(source_roots ++ source_inventory, [:test, :artifact_test])

    verification_ids =
      Selection.sorted_difference(
        Enum.map(verification_projects, & &1.id) ++ test_owners,
        selected_ids
      )

    inventory_member_ids =
      source_roots
      |> Kernel.++(source_inventory)
      |> Selection.owners([:runtime, :docs, :metadata])
      |> Selection.sorted_difference(selected_ids ++ verification_ids)

    excluded_ids =
      workspace.projects
      |> Map.keys()
      |> Selection.sorted_difference(selected_ids ++ verification_ids ++ inventory_member_ids)

    merge_result = Selection.merge_external_deps(artifact_graph, dependency_ids, :docs)
    test_ids = Graph.reachable_from(test_graph, dependency_ids, :test)
    checked_ids = dependency_ids ++ Enum.map(verification_projects, & &1.id)

    violations =
      graph.violations
      |> Selection.relevant_graph_violations(checked_ids, artifact_graph)
      |> Kernel.++(selection_violations)
      |> Kernel.++(boundary_violations)
      |> Kernel.++(
        Selection.copied_boundary_violations(
          artifact,
          selected_ids ++ verification_ids ++ inventory_member_ids
        )
      )
      |> Kernel.++(merge_result.violations)
      |> Kernel.++(
        Selection.portable_dependency_violations(
          manifest,
          artifact,
          artifact_graph,
          dependency_ids
        )
      )
      |> Kernel.++(
        Selection.publication_dependency_violations(artifact, artifact_graph, dependency_ids)
      )
      |> Kernel.++(Selection.verification_violations(artifact, test_graph, test_ids))
      |> Kernel.++(Selection.source_dependency_violations(artifact, artifact_graph, known_seeds))
      |> Kernel.++(
        Selection.selection_policy_violations(workspace.projects, dependency_ids, artifact_graph)
      )
      |> Enum.uniq()
      |> Enum.sort_by(fn violation ->
        {violation.code, violation.project || "", violation.dependency || :none}
      end)

    plan = %{
      facts: workspace.facts,
      input_watches: [],
      layout: nil,
      output_inventory: [],
      manifest: manifest,
      artifact: artifact,
      workspace: workspace,
      graph: graph,
      artifact_graph: artifact_graph,
      dependency_ids: dependency_ids,
      source_member_ids: source_member_ids,
      inventory_member_ids: inventory_member_ids,
      verification_ids: verification_ids,
      externalized_edges: externalized_edges,
      source_root: Selection.source_root(source_projects),
      source_roots: source_roots,
      source_inventory: source_inventory,
      structural_inputs:
        structural_inputs!(
          workspace.facts,
          manifest,
          artifact,
          source_projects,
          selected_ids ++ verification_ids ++ artifact.external_projects
        ),
      selected_ids: selected_ids,
      excluded_ids: excluded_ids,
      selected_projects: selected_projects,
      external_deps: merge_result.external_deps,
      violations: violations
    }

    probe_inputs =
      for id <- Enum.uniq(selected_ids ++ verification_ids ++ artifact.external_projects),
          project = Map.get(workspace.projects, id),
          not is_nil(project),
          path <- Map.get(project, :probe_inputs, []),
          do: path

    plan = %{
      plan
      | structural_inputs: Enum.sort(Enum.uniq(plan.structural_inputs ++ probe_inputs))
    }

    watches = Inputs.collect(plan)

    plan = %{
      plan
      | input_watches: watches,
        structural_inputs: Enum.sort(Enum.uniq(plan.structural_inputs ++ Inputs.sources(watches)))
    }

    finalize_layout!(plan)
  end

  defp finalize_layout!(%{violations: []} = plan) do
    layout =
      case plan.artifact.mode do
        :monolith -> Flat.plan!(plan)
        :package_projection -> Components.plan!(plan)
        :source_project -> Preserve.plan!(plan)
      end

    empty =
      for entry <- plan.source_roots,
          entry.directory,
          source = Path.join(plan.manifest.repo_root, entry.source),
          {path, :directory} <- Facts.topology(plan.facts, source),
          Facts.ls!(plan.facts, path) == [],
          do:
            if(path == source,
              do: entry.target,
              else: Path.join(entry.target, Path.relative_to(path, source))
            )

    empty =
      empty
      |> Enum.uniq()
      |> Enum.reject(fn path ->
        Enum.any?(layout.full, &Inventory.covered?(&1.target, path))
      end)
      |> Enum.sort()

    layout = Map.put(layout, :empty_dirs, empty)
    {sources, outputs} = Inventory.layout_inventory(plan, layout)
    outputs = CoreInventory.validate!(outputs)
    %{plan | layout: layout, source_inventory: sources, output_inventory: outputs}
  end

  defp finalize_layout!(plan), do: plan

  defp structural_inputs!(facts, manifest, artifact, _source_projects, project_ids) do
    # Typed input declarations are observed after graph selection.
    hook_inputs =
      if artifact.package.docs.mermaid, do: List.wrap(artifact.package.docs.hook_file), else: []

    for path <- hook_inputs do
      unless Facts.regular?(facts, Facts.source!(facts, manifest.repo_root, path)),
        do: raise(Error, "missing structural input: #{path}")
    end

    smoke_inputs = List.wrap(artifact.verify.smoke.entry_file)

    declared_inputs =
      hook_inputs ++ smoke_inputs ++ [".formatter.exs", ".credo.exs", ".dialyzer_ignore.exs"]

    project_metadata =
      for id <- Enum.uniq(["." | project_ids]), path <- ["mix.exs", "mix.lock"] do
        if id == ".", do: path, else: Path.join(id, path)
      end

    Enum.uniq(declared_inputs ++ project_metadata) |> Enum.sort()
  end
end
