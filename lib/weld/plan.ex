defmodule Weld.Plan do
  @moduledoc """
  Resolves one artifact view from the manifest and workspace graph.
  """

  alias Weld.Error
  alias Weld.Graph
  alias Weld.Graph.View
  alias Weld.Manifest
  alias Weld.Output
  alias Weld.Plan.Boundary
  alias Weld.Plan.Inventory
  alias Weld.Layout.{Components, Flat}
  alias Weld.Violation
  alias Weld.Workspace
  alias Weld.Workspace.Project

  @enforce_keys [
    :manifest,
    :artifact,
    :workspace,
    :graph,
    :selected_ids,
    :excluded_ids,
    :selected_projects,
    :external_deps,
    :violations
  ]
  defstruct @enforce_keys ++
              [
                artifact_graph: nil,
                dependency_ids: [],
                source_member_ids: [],
                inventory_member_ids: [],
                verification_ids: [],
                externalized_edges: [],
                source_root: nil,
                source_roots: [],
                source_inventory: [],
                structural_inputs: [],
                layout: nil,
                output_inventory: [],
                input_watches: []
              ]

  @type external_dep :: Graph.external_dep()

  @typedoc """
  A source-to-target inventory relationship within an artifact plan.

  Monolith entries also describe the materialization operation and
  whether the destination belongs to the publication inventory.
  """
  @type inventory_entry :: %{
          optional(:operation) => :link_or_copy | :copy | :transform | :generate,
          optional(:publish) => boolean(),
          source: String.t(),
          target: String.t(),
          owner: String.t() | nil,
          kind: :compiled | :runtime | :test | :docs | :metadata | :artifact_test,
          directory: boolean()
        }

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          artifact: Manifest.Artifact.t(),
          workspace: Workspace.t(),
          graph: Graph.t(),
          artifact_graph: Graph.t() | nil,
          dependency_ids: [String.t()],
          source_member_ids: [String.t()],
          inventory_member_ids: [String.t()],
          verification_ids: [String.t()],
          externalized_edges: [Weld.Graph.Edge.t()],
          source_root: Path.t() | nil,
          source_roots: [inventory_entry()],
          source_inventory: [inventory_entry()],
          structural_inputs: [Path.t()],
          layout: map() | nil,
          output_inventory: [map()],
          input_watches: [map()],
          selected_ids: [String.t()],
          excluded_ids: [String.t()],
          selected_projects: [Project.t()],
          external_deps: [external_dep()],
          violations: [Violation.t()]
        }

  @spec build!(Path.t() | Manifest.t(), keyword()) :: t()
  def build!(manifest_path_or_manifest, opts \\ [])

  def build!(manifest_path, opts) when is_binary(manifest_path) do
    manifest_path |> Manifest.load!() |> build!(opts)
  end

  def build!(%Manifest{} = manifest, opts) do
    artifact = Manifest.artifact!(manifest, opts[:artifact])
    workspace = Workspace.load!(manifest)
    artifact = Manifest.bind_native(artifact, workspace.projects)
    graph = workspace.graph

    seed_ids =
      artifact.roots
      |> Kernel.++(artifact.include)
      |> Kernel.++(optional_feature_projects(manifest, artifact.optional_features))
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
    source_projects = source_projects!(artifact, workspace.projects)

    {artifact_graph, externalized_edges, boundary_violations} =
      Boundary.build(workspace, artifact, known_seeds)

    dependency_ids = Graph.reachable_from(artifact_graph, known_seeds, :package)
    selected_projects = projects_for_ids(workspace, artifact_graph, dependency_ids)

    test_graph = graph_for_view(artifact_graph, artifact, dependency_ids, :test)

    verification_projects =
      verification_projects(workspace, test_graph, artifact, dependency_ids)

    {source_roots, source_inventory} =
      Inventory.build(
        workspace,
        artifact,
        source_projects,
        selected_projects,
        verification_projects
      )

    compiled = owners(source_roots ++ source_inventory, [:compiled])

    source_member_ids =
      if artifact.mode == :source_project do
        sorted_difference(compiled, dependency_ids ++ Enum.map(verification_projects, & &1.id))
      else
        Enum.uniq(compiled) |> Enum.sort()
      end

    selected_ids = Enum.uniq(dependency_ids ++ source_member_ids) |> Enum.sort()

    test_owners = owners(source_roots ++ source_inventory, [:test, :artifact_test])

    verification_ids =
      sorted_difference(Enum.map(verification_projects, & &1.id) ++ test_owners, selected_ids)

    inventory_member_ids =
      source_roots
      |> Kernel.++(source_inventory)
      |> owners([:runtime, :docs, :metadata])
      |> sorted_difference(selected_ids ++ verification_ids)

    excluded_ids =
      workspace.projects
      |> Map.keys()
      |> sorted_difference(selected_ids ++ verification_ids ++ inventory_member_ids)

    merge_result = merge_external_deps(artifact_graph, dependency_ids, :docs)
    test_ids = Graph.reachable_from(test_graph, dependency_ids, :test)
    checked_ids = dependency_ids ++ Enum.map(verification_projects, & &1.id)

    violations =
      graph.violations
      |> relevant_graph_violations(checked_ids, artifact_graph)
      |> Kernel.++(selection_violations)
      |> Kernel.++(boundary_violations)
      |> Kernel.++(
        copied_boundary_violations(
          artifact,
          selected_ids ++ verification_ids ++ inventory_member_ids
        )
      )
      |> Kernel.++(merge_result.violations)
      |> Kernel.++(verification_violations(artifact, test_graph, test_ids))
      |> Kernel.++(source_dependency_violations(artifact, artifact_graph, known_seeds))
      |> Kernel.++(
        selection_policy_violations(workspace.projects, dependency_ids, artifact_graph)
      )
      |> Enum.uniq()
      |> Enum.sort_by(fn violation ->
        {violation.code, violation.project || "", violation.dependency || :none}
      end)

    plan = %__MODULE__{
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
      source_root: source_root(source_projects),
      source_roots: source_roots,
      source_inventory: source_inventory,
      structural_inputs:
        structural_inputs!(
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

    watches = Weld.Shell.Inputs.collect!(plan)

    plan = %{
      plan
      | input_watches: watches,
        structural_inputs:
          Enum.sort(Enum.uniq(plan.structural_inputs ++ Weld.Shell.Inputs.sources(watches)))
    }

    finalize_layout!(plan)
  end

  defp finalize_layout!(%__MODULE__{violations: [], artifact: %{mode: mode}} = plan)
       when mode in [:monolith, :package_projection] do
    layout = if mode == :monolith, do: Flat.plan!(plan), else: Components.plan!(plan)
    {sources, outputs} = Inventory.layout_inventory(plan, layout)
    outputs = Weld.Core.Inventory.validate!(outputs)
    %{plan | layout: layout, source_inventory: sources, output_inventory: outputs}
  end

  defp finalize_layout!(%__MODULE__{violations: [], artifact: %{mode: :source_project}} = plan) do
    outputs = Inventory.preserve_inventory(plan)

    for entry <- Weld.Shell.Inputs.mapped(plan) do
      unless Enum.any?(outputs, &(&1.target == entry.target and &1.publish == entry.publish)),
        do:
          raise(
            Error,
            "native preserve inventory does not cover declared target/publication: #{entry.target}"
          )
    end

    %{plan | output_inventory: outputs}
  end

  defp finalize_layout!(plan), do: plan

  defp source_projects!(%{mode: :source_project, roots: [root], package: package}, projects) do
    case Map.get(projects, root) do
      %{app: app, version: version, package_name: name} = project
      when app == package.otp_app and version == package.version and name == package.name ->
        [project]

      nil ->
        raise Error, "source_project root was not discovered: #{root}"

      _ ->
        raise Error,
              "source project app, version and package name must match the artifact package"
    end
  end

  defp source_projects!(_artifact, _projects), do: []

  defp source_root([project]), do: project.abs_path
  defp source_root([]), do: nil

  defp structural_inputs!(manifest, artifact, _source_projects, project_ids) do
    # Typed input declarations are observed after graph selection.
    hook_inputs =
      if artifact.package.docs.mermaid, do: List.wrap(artifact.package.docs.hook_file), else: []

    for path <- hook_inputs do
      unless File.regular?(Output.source!(manifest.repo_root, path)),
        do: raise(Error, "missing structural input: #{path}")
    end

    declared_inputs = hook_inputs

    project_metadata =
      for id <- Enum.uniq(["." | project_ids]), path <- ["mix.exs", "mix.lock"] do
        if id == ".", do: path, else: Path.join(id, path)
      end

    Enum.uniq(declared_inputs ++ project_metadata) |> Enum.sort()
  end

  @spec selected?(t(), String.t()) :: boolean()
  def selected?(%__MODULE__{} = plan, project_id), do: project_id in plan.selected_ids

  @spec projects_for_view(t(), View.t()) :: [Project.t()]
  def projects_for_view(%__MODULE__{} = plan, view) do
    {artifact_graph, ids} = graph_and_dependencies(plan)
    graph = graph_for_view(artifact_graph, plan.artifact, ids, view)
    projects_for_ids(plan.workspace, graph, Graph.reachable_from(graph, ids, view))
  end

  @spec external_deps_for_view(t(), View.t()) :: [external_dep()]
  def external_deps_for_view(%__MODULE__{} = plan, view) do
    {artifact_graph, ids} = graph_and_dependencies(plan)
    graph = graph_for_view(artifact_graph, plan.artifact, ids, view)

    graph
    |> merge_external_deps(Graph.reachable_from(graph, ids, view), view)
    |> Map.fetch!(:external_deps)
  end

  # Each selected component runs as a test owner. Its test-only dependencies
  # contribute their package dependencies, without recursively selecting their suites.
  defp graph_for_view(
         graph,
         %{mode: :package_projection, verify: %{component_tests: true}},
         ids,
         :test
       ) do
    owners = MapSet.new(ids)
    keep? = fn id, kind -> MapSet.member?(owners, id) or View.allowed?(kind, :package) end

    external =
      Map.new(graph.external_deps, fn {id, deps} ->
        {id, Enum.filter(deps, fn dep -> keep?.(id, dep.kind) end)}
      end)

    graph = Graph.filter_edges(graph, fn edge -> keep?.(edge.from, edge.kind) end)
    %{graph | external_deps: external}
  end

  defp graph_for_view(graph, _artifact, _ids, _view), do: graph

  defp graph_and_dependencies(%__MODULE__{artifact_graph: nil} = plan),
    do: {plan.graph, plan.selected_ids}

  defp graph_and_dependencies(plan), do: {plan.artifact_graph, plan.dependency_ids}

  defp projects_for_ids(workspace, graph, ids) do
    graph
    |> topologically_selected(ids)
    |> Enum.map(&Map.fetch!(workspace.projects, &1))
  end

  defp verification_projects(workspace, graph, artifact, dependency_ids) do
    if artifact.mode in [:monolith, :source_project] or artifact.verify.component_tests do
      ids = sorted_difference(Graph.reachable_from(graph, dependency_ids, :test), dependency_ids)
      projects_for_ids(workspace, graph, ids)
    else
      []
    end
  end

  defp verification_violations(artifact, graph, test_ids) do
    if artifact.mode == :monolith or artifact.verify.component_tests do
      merge_external_deps(graph, test_ids, :test).violations
    else
      []
    end
  end

  defp source_dependency_violations(%{mode: :source_project}, graph, seeds) do
    included = Graph.reachable_from(graph, seeds, :all)

    for edge <- Graph.edges(graph),
        edge.from in included,
        not Keyword.has_key?(edge.opts, :path) do
      Violation.new(
        :source_package_requires_boundary,
        "source_project preserves this versioned dependency as a package; declare the target in external_projects",
        project: edge.from,
        dependency: edge.app,
        details: %{target: edge.to}
      )
    end
  end

  defp source_dependency_violations(_artifact, _graph, _seeds), do: []

  defp copied_boundary_violations(artifact, included) do
    artifact.external_projects
    |> Enum.filter(&(&1 in included))
    |> Enum.map(fn id ->
      Violation.new(
        :external_project_included,
        "external project is also included by the artifact inventory",
        project: id
      )
    end)
  end

  defp owners(entries, kinds) do
    for entry <- entries, entry.kind in kinds, not is_nil(entry.owner), do: entry.owner
  end

  defp sorted_difference(values, excluded) do
    values |> Enum.uniq() |> Enum.reject(&(&1 in excluded)) |> Enum.sort()
  end

  @spec ensure_valid!(t()) :: t()
  def ensure_valid!(%__MODULE__{violations: []} = plan), do: plan

  def ensure_valid!(%__MODULE__{violations: violations}) do
    messages =
      Enum.map_join(violations, "\n", fn violation ->
        prefix =
          [violation.code, violation.project, violation.dependency]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join(" | ", &to_string/1)

        "- #{prefix}: #{violation.message}"
      end)

    raise Error, "weld plan is invalid:\n#{messages}"
  end

  defp optional_feature_projects(manifest, features) do
    features
    |> Enum.flat_map(fn feature ->
      manifest.publication.optional
      |> Map.get(feature, MapSet.new())
      |> MapSet.to_list()
    end)
    |> Enum.sort()
  end

  defp topologically_selected(graph, selected_ids) do
    graph
    |> Graph.topo_sort(:package)
    |> case do
      [] -> selected_ids
      sorted -> Enum.filter(sorted, &(&1 in selected_ids))
    end
  end

  defp merge_external_deps(graph, selected_ids, view) do
    Enum.reduce(selected_ids, %{external_deps: %{}, violations: []}, fn project_id, acc ->
      Graph.external_deps(graph, project_id)
      |> Enum.filter(&View.allowed?(&1.kind, view))
      |> Enum.reduce(acc, &merge_external_dep/2)
    end)
    |> Map.update!(:external_deps, fn deps ->
      deps
      |> Map.values()
      |> Enum.sort_by(&Atom.to_string(&1.app))
    end)
  end

  defp merge_external_dep(dep, current) do
    comparable = comparable_dep(dep)

    case Map.get(current.external_deps, dep.app) do
      nil ->
        %{current | external_deps: Map.put(current.external_deps, dep.app, dep)}

      existing ->
        if comparable == comparable_dep(existing) do
          current
        else
          violation =
            Violation.new(
              :conflicting_external_dependency,
              "selected projects declare incompatible external dependency requirements",
              dependency: dep.app
            )

          %{current | violations: [violation | current.violations]}
        end
    end
  end

  defp comparable_dep(dep) do
    {dep.requirement, Enum.sort(dep.opts)}
  end

  defp selection_policy_violations(projects, selected_ids, graph) do
    selected_ids
    |> Enum.flat_map(fn project_id ->
      project = Map.fetch!(projects, project_id)
      project_level_violations(project)
    end)
    |> Kernel.++(
      Graph.edges(graph)
      |> Enum.flat_map(fn edge ->
        if edge.from in selected_ids and edge.to in selected_ids do
          target = Map.fetch!(projects, edge.to)
          maybe_tooling_violation(edge, target)
        else
          []
        end
      end)
    )
  end

  defp project_level_violations(%Project{classification: :ignored, id: project_id}) do
    [
      Violation.new(:ignored_project_selected, "ignored projects cannot be selected",
        project: project_id
      )
    ]
  end

  defp project_level_violations(%Project{}), do: []

  defp maybe_tooling_violation(edge, %Project{
         classification: :tooling,
         publication_role: :internal_only
       }) do
    if edge.kind in [:runtime, :compile, :docs] do
      [
        Violation.new(
          :runtime_depends_on_internal_only,
          "runtime closure depends on internal-only tooling",
          project: edge.from,
          dependency: edge.app,
          details: %{target: edge.to}
        )
      ]
    else
      []
    end
  end

  defp maybe_tooling_violation(_edge, _project), do: []

  defp relevant_graph_violations(violations, selected_ids, graph) do
    Enum.filter(violations, fn violation ->
      case violation.code do
        :cycle_detected -> Graph.topo_sort(graph, :package) == []
        _ -> is_nil(violation.project) or violation.project in selected_ids
      end
    end)
  end
end
