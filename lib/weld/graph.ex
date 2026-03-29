defmodule Weld.Graph do
  @moduledoc """
  Immutable workspace graph wrapper built on top of `:libgraph`.
  """

  alias Weld.Graph.Edge
  alias Weld.Graph.View
  alias Weld.Violation
  alias Weld.Workspace.Project

  @enforce_keys [
    :dag,
    :projects,
    :edges,
    :classifications,
    :publication_roles,
    :external_deps,
    :violations
  ]
  defstruct @enforce_keys

  @type project_id :: String.t()

  @type external_dep :: %{
          app: atom(),
          requirement: String.t() | nil,
          opts: keyword(),
          original: tuple(),
          kind: Edge.kind()
        }

  @type t :: %__MODULE__{
          dag: Graph.t(),
          projects: %{optional(project_id()) => Project.t()},
          edges: %{optional({project_id(), project_id()}) => [Edge.t()]},
          classifications: %{optional(project_id()) => Project.classification()},
          publication_roles: %{optional(project_id()) => Project.publication_role()},
          external_deps: %{optional(project_id()) => [external_dep()]},
          violations: [Violation.t()]
        }

  @spec new() :: t()
  def new do
    %__MODULE__{
      dag: Graph.new(type: :directed, vertex_identifier: & &1),
      projects: %{},
      edges: %{},
      classifications: %{},
      publication_roles: %{},
      external_deps: %{},
      violations: []
    }
  end

  @spec add_project(t(), Project.t()) :: t()
  def add_project(%__MODULE__{} = graph, %Project{} = project) do
    %{
      graph
      | dag: Graph.add_vertex(graph.dag, project.id),
        projects: Map.put(graph.projects, project.id, project),
        classifications: Map.put(graph.classifications, project.id, project.classification),
        publication_roles: Map.put(graph.publication_roles, project.id, project.publication_role),
        external_deps: Map.put_new(graph.external_deps, project.id, [])
    }
  end

  @spec add_edge(t(), Edge.t()) :: t()
  def add_edge(%__MODULE__{} = graph, %Edge{} = edge) do
    edge_key = {edge.from, edge.to}
    updated_edges = Map.update(graph.edges, edge_key, [edge], &[edge | &1])

    %{
      graph
      | dag: Graph.add_edge(graph.dag, edge.from, edge.to, label: edge.kind),
        edges: updated_edges
    }
  end

  @spec add_external_dep(t(), project_id(), external_dep()) :: t()
  def add_external_dep(%__MODULE__{} = graph, project_id, dep) do
    update_in(graph.external_deps[project_id], fn deps -> [dep | deps || []] end)
  end

  @spec add_violation(t(), Violation.t()) :: t()
  def add_violation(%__MODULE__{} = graph, %Violation{} = violation) do
    %{graph | violations: [violation | graph.violations]}
  end

  @spec project(t(), project_id()) :: {:ok, Project.t()} | :error
  def project(%__MODULE__{} = graph, project_id), do: Map.fetch(graph.projects, project_id)

  @spec projects(t()) :: [Project.t()]
  def projects(%__MODULE__{} = graph) do
    graph.projects
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @spec edges(t()) :: [Edge.t()]
  def edges(%__MODULE__{} = graph) do
    graph.edges
    |> Map.values()
    |> List.flatten()
    |> Enum.sort_by(fn edge -> {edge.from, edge.to, edge.kind, Atom.to_string(edge.app)} end)
  end

  @spec external_deps(t(), project_id()) :: [external_dep()]
  def external_deps(%__MODULE__{} = graph, project_id) do
    graph.external_deps
    |> Map.get(project_id, [])
    |> Enum.sort_by(fn dep -> {Atom.to_string(dep.app), dep.kind} end)
  end

  @spec reachable_from(t(), project_id() | [project_id()], View.t()) :: [project_id()]
  def reachable_from(%__MODULE__{} = graph, project_ids, view) when is_list(project_ids) do
    view_graph = subgraph(graph, view)
    Graph.reachable(view_graph, project_ids) |> Enum.sort()
  end

  def reachable_from(%__MODULE__{} = graph, project_id, view) do
    reachable_from(graph, [project_id], view)
  end

  @spec reaching(t(), project_id() | [project_id()], View.t()) :: [project_id()]
  def reaching(graph, project_ids, view \\ :all)

  def reaching(%__MODULE__{} = graph, project_ids, view) when is_list(project_ids) do
    view_graph = subgraph(graph, view)
    Graph.reaching(view_graph, project_ids) |> Enum.sort()
  end

  def reaching(%__MODULE__{} = graph, project_id, view) do
    reaching(graph, [project_id], view)
  end

  @spec path(t(), project_id(), project_id(), View.t()) :: {:ok, [project_id()]} | :no_path
  def path(%__MODULE__{} = graph, from, to, view \\ :all) do
    case Graph.get_shortest_path(subgraph(graph, view), from, to) do
      nil -> :no_path
      path -> {:ok, path}
    end
  end

  @spec topo_sort(t(), View.t()) :: [project_id()]
  def topo_sort(%__MODULE__{} = graph, view \\ :all) do
    case Graph.topsort(subgraph(graph, view)) do
      false -> []
      sorted -> sorted
    end
  end

  @spec violations(t(), map()) :: [Violation.t()]
  def violations(%__MODULE__{} = graph, _policy \\ %{}) do
    Enum.sort_by(graph.violations, fn violation ->
      {violation.code, violation.project || "", violation.dependency || :none}
    end)
  end

  @spec subgraph(t(), View.t()) :: Graph.t()
  def subgraph(%__MODULE__{} = graph, view) do
    projects = Map.keys(graph.projects)

    dag =
      Enum.reduce(
        projects,
        Graph.new(type: :directed, vertex_identifier: & &1),
        &Graph.add_vertex(&2, &1)
      )

    Enum.reduce(edges(graph), dag, fn edge, acc ->
      if View.allowed?(edge.kind, view) do
        Graph.add_edge(acc, edge.from, edge.to, label: edge.kind)
      else
        acc
      end
    end)
  end
end
