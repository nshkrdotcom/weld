defmodule Weld.Plan do
  @moduledoc """
  Resolves one artifact view from the manifest and workspace graph.
  """

  alias Weld.Error
  alias Weld.Graph
  alias Weld.Graph.View
  alias Weld.Manifest
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
  defstruct @enforce_keys

  @type external_dep :: Graph.external_dep()

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          artifact: Manifest.Artifact.t(),
          workspace: Workspace.t(),
          graph: Graph.t(),
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

    selected_ids =
      graph
      |> Graph.reachable_from(seed_ids, :package)
      |> Enum.uniq()
      |> Enum.sort()

    selected_projects =
      graph
      |> topologically_selected(selected_ids)
      |> Enum.map(&Map.fetch!(workspace.projects, &1))

    excluded_ids =
      workspace.projects
      |> Map.keys()
      |> Enum.reject(&(&1 in selected_ids))
      |> Enum.sort()

    merge_result = merge_external_deps(graph, selected_ids)

    violations =
      graph.violations
      |> relevant_graph_violations(selected_ids)
      |> Kernel.++(selection_violations)
      |> Kernel.++(merge_result.violations)
      |> Kernel.++(selection_policy_violations(workspace.projects, selected_ids, graph))
      |> Enum.sort_by(fn violation ->
        {violation.code, violation.project || "", violation.dependency || :none}
      end)

    %__MODULE__{
      manifest: manifest,
      artifact: artifact,
      workspace: workspace,
      graph: graph,
      selected_ids: selected_ids,
      excluded_ids: excluded_ids,
      selected_projects: selected_projects,
      external_deps: merge_result.external_deps,
      violations: violations
    }
  end

  @spec selected?(t(), String.t()) :: boolean()
  def selected?(%__MODULE__{} = plan, project_id), do: project_id in plan.selected_ids

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

  defp merge_external_deps(graph, selected_ids) do
    Enum.reduce(selected_ids, %{external_deps: %{}, violations: []}, fn project_id, acc ->
      Graph.external_deps(graph, project_id)
      |> Enum.filter(&View.allowed?(&1.kind, :docs))
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
    {dep.requirement, Keyword.drop(dep.opts, [:path, :git, :github])}
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

  defp relevant_graph_violations(violations, selected_ids) do
    Enum.filter(violations, fn violation ->
      is_nil(violation.project) or violation.project in selected_ids
    end)
  end
end
