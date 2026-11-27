defmodule Weld.Core.Selection do
  @moduledoc "Pure graph selection and dependency views over explicit workspace facts."
  alias Weld.{Error, Graph, Violation}
  alias Weld.Graph.View
  alias Weld.Workspace.Project
  def source_projects!(%{mode: :source_project, roots: [root], package: package}, projects) do
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

  def source_projects!(_artifact, _projects), do: []

  def source_root([project]), do: project.abs_path
  def source_root([]), do: nil

  @spec selected?(map(), String.t()) :: boolean()
  def selected?(%{} = plan, project_id), do: project_id in plan.selected_ids

  @spec projects_for_view(map(), View.t()) :: [Project.t()]
  def projects_for_view(%{} = plan, view) do
    {artifact_graph, ids} = graph_and_dependencies(plan)
    graph = graph_for_view(artifact_graph, plan.artifact, ids, view)
    projects_for_ids(plan.workspace, graph, Graph.reachable_from(graph, ids, view))
  end

  @spec external_deps_for_view(map(), View.t()) :: [Graph.external_dep()]
  def external_deps_for_view(%{} = plan, view) do
    {artifact_graph, ids} = graph_and_dependencies(plan)
    graph = graph_for_view(artifact_graph, plan.artifact, ids, view)

    graph
    |> merge_external_deps(Graph.reachable_from(graph, ids, view), view)
    |> Map.fetch!(:external_deps)
  end

  # Each selected component runs as a test owner. Its test-only dependencies
  # contribute their package dependencies, without recursively selecting their suites.
  def graph_for_view(
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

  def graph_for_view(graph, _artifact, _ids, _view), do: graph

  def graph_and_dependencies(%{artifact_graph: nil} = plan),
    do: {plan.graph, plan.selected_ids}

  def graph_and_dependencies(plan), do: {plan.artifact_graph, plan.dependency_ids}

  def projects_for_ids(workspace, graph, ids) do
    graph
    |> topologically_selected(ids)
    |> Enum.map(&Map.fetch!(workspace.projects, &1))
  end

  def verification_projects(workspace, graph, artifact, dependency_ids) do
    if artifact.mode in [:monolith, :source_project] or artifact.verify.component_tests do
      ids = sorted_difference(Graph.reachable_from(graph, dependency_ids, :test), dependency_ids)
      projects_for_ids(workspace, graph, ids)
    else
      []
    end
  end

  def verification_violations(artifact, graph, test_ids) do
    if artifact.mode == :monolith or artifact.verify.component_tests do
      merge_external_deps(graph, test_ids, :test).violations
    else
      []
    end
  end

  # Preserve never rewrites native Mix code, so a canonical graph replacement
  # cannot make an original local Git declaration portable.
  def portable_dependency_violations(_manifest, %{mode: :source_project}, graph, ids) do
    for id <- Graph.reachable_from(graph, ids, :all),
        dep <- Map.fetch!(graph.projects, id).deps,
        is_binary(dep.opts[:git]),
        Graph.local_git_locator?(dep.opts[:git]) do
      local_git_violation(id, dep.app, :native)
    end
  end

  def portable_dependency_violations(manifest, artifact, graph, ids) do
    dependencies = for id <- Enum.sort(ids), dep <- Graph.external_deps(graph, id),
      View.allowed?(dep.kind, :docs), do: {id, dep, :generated}
    test_dependencies =
      if artifact.mode == :monolith or artifact.verify.component_tests do
        test_graph = graph_for_view(graph, artifact, ids, :test)
        for id <- Graph.reachable_from(test_graph, ids, :test),
            dep <- Graph.external_deps(test_graph, id),
            View.allowed?(dep.kind, :test), do: {id, dep, :generated}
      else
        []
      end
    forced =
      if artifact.mode == :monolith do
        for app <- artifact.monolith_opts[:extra_test_deps] || [],
            policy = manifest.dependencies[app], not is_nil(policy),
            do: {nil, %{app: app, opts: policy.opts}, :flat_extra_test}
      else
        []
      end

    for {id, dep, kind} <- dependencies ++ test_dependencies ++ forced,
        is_binary(dep.opts[:git]),
        Graph.local_git_locator?(dep.opts[:git]) do
      local_git_violation(id, dep.app, kind)
    end
    |> Enum.uniq()
  end

  defp local_git_violation(id, app, kind) do
    hint = if kind == :native,
      do: "replace the Git source in native mix.exs with a remote Git or versioned package dependency",
      else: "declare a canonical remote Git or versioned Hex dependency"
    Violation.new(:nonportable_git_dependency,
      "standalone dependency uses a local Git repository; " <> hint,
      project: id, dependency: app,
      details: %{option: :git, source_kind: kind,
        declaration: if(kind == :flat_extra_test, do: "flat.extra_test_deps", else: "deps"),
        hint: hint})
  end

  def publication_dependency_violations(%{verify: %{hex_build: false}}, _graph, _ids), do: []
  def publication_dependency_violations(_artifact, graph, ids) do
    for id <- Enum.sort(ids), dep <- Graph.external_deps(graph, id),
        View.allowed?(dep.kind, :package),
        not is_nil(dep.opts[:git]) or not is_nil(dep.opts[:github]) or not is_nil(dep.opts[:path]) do
      Violation.new(:unsupported_publication_dependency,
        "Hex publication requires a versioned package dependency; use a canonical Hex declaration or a non-Hex artifact",
        project: id, dependency: dep.app,
        details: %{requirement: dep.requirement, source: if(dep.opts[:path], do: :path, else: :git)})
    end
  end

  def source_dependency_violations(%{mode: :source_project}, graph, seeds) do
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

  def source_dependency_violations(_artifact, _graph, _seeds), do: []

  def copied_boundary_violations(artifact, included) do
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

  def owners(entries, kinds) do
    for entry <- entries, entry.kind in kinds, not is_nil(entry.owner), do: entry.owner
  end

  def sorted_difference(values, excluded) do
    values |> Enum.uniq() |> Enum.reject(&(&1 in excluded)) |> Enum.sort()
  end

  @spec ensure_valid!(map()) :: map()
  def ensure_valid!(%{violations: []} = plan), do: plan

  def ensure_valid!(%{violations: violations}) do
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

  def optional_feature_projects(manifest, features) do
    features
    |> Enum.flat_map(fn feature ->
      manifest.publication.optional
      |> Map.get(feature, MapSet.new())
      |> MapSet.to_list()
    end)
    |> Enum.sort()
  end

  def topologically_selected(graph, selected_ids) do
    graph
    |> Graph.topo_sort(:package)
    |> case do
      [] -> selected_ids
      sorted -> Enum.filter(sorted, &(&1 in selected_ids))
    end
  end

  def merge_external_deps(graph, selected_ids, view) do
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

  def merge_external_dep(dep, current) do
    case Map.get(current.external_deps, dep.app) do
      nil -> %{current | external_deps: Map.put(current.external_deps, dep.app, dep)}
      existing ->
        case Graph.merge_dependency_scopes(existing, dep) do
          {:ok, merged} -> %{current | external_deps: Map.put(current.external_deps, dep.app, merged)}
          :error ->
            violation = Violation.new(:conflicting_external_dependency,
              "selected projects declare incompatible external dependency requirements or sources",
              dependency: dep.app,
              details: %{requirements: [existing.requirement, dep.requirement],
                origins: Enum.sort(Enum.uniq(Map.get(existing, :origins, []) ++ Map.get(dep, :origins, []))),
                hint: "Declare one compatible requirement/source; scopes alone may be merged."})
            %{current | violations: [violation | current.violations]}
        end
    end
  end

  def selection_policy_violations(projects, selected_ids, graph) do
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

  def project_level_violations(%Project{classification: :ignored, id: project_id}) do
    [
      Violation.new(:ignored_project_selected, "ignored projects cannot be selected",
        project: project_id
      )
    ]
  end

  def project_level_violations(%Project{}), do: []

  def maybe_tooling_violation(edge, %Project{
         classification: :tooling,
         publication_role: :internal_only
       }) do
    if View.allowed?(edge.kind, :docs) do
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

  def maybe_tooling_violation(_edge, _project), do: []

  def relevant_graph_violations(violations, selected_ids, graph) do
    Enum.filter(violations, fn violation ->
      case violation.code do
        :cycle_detected -> Graph.topo_sort(graph, :package) == []
        _ -> is_nil(violation.project) or violation.project in selected_ids
      end
    end)
  end
end
