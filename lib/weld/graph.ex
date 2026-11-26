defmodule Weld.Graph do
  @moduledoc """
  Immutable workspace dependency graph.
  """

  alias Weld.Graph.Edge
  alias Weld.Graph.View
  alias Weld.Violation
  alias Weld.Workspace.Project

  @enforce_keys [
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
      | projects: Map.put(graph.projects, project.id, project),
        classifications: Map.put(graph.classifications, project.id, project.classification),
        publication_roles: Map.put(graph.publication_roles, project.id, project.publication_role),
        external_deps: Map.put_new(graph.external_deps, project.id, [])
    }
  end

  @spec add_edge(t(), Edge.t()) :: t()
  def add_edge(%__MODULE__{} = graph, %Edge{} = edge) do
    edge_key = {edge.from, edge.to}
    updated_edges = Map.update(graph.edges, edge_key, [edge], &[edge | &1])

    %{graph | edges: updated_edges}
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

  @doc false
  @spec filter_edges(t(), (Edge.t() -> boolean())) :: t()
  def filter_edges(%__MODULE__{} = graph, accept?) do
    edges =
      graph
      |> edges()
      |> Enum.filter(accept?)
      |> Enum.group_by(&{&1.from, &1.to})

    %{graph | edges: edges}
  end

  @spec external_deps(t(), project_id()) :: [external_dep()]
  def external_deps(%__MODULE__{} = graph, project_id) do
    graph.external_deps
    |> Map.get(project_id, [])
    |> Enum.sort_by(fn dep -> {Atom.to_string(dep.app), dep.kind} end)
  end

  @spec reachable_from(t(), project_id() | [project_id()], View.t()) :: [project_id()]
  def reachable_from(%__MODULE__{} = graph, project_ids, view) when is_list(project_ids) do
    reachable(project_ids, adjacency(graph, view, :outgoing), %{})
  end

  def reachable_from(%__MODULE__{} = graph, project_id, view) do
    reachable_from(graph, [project_id], view)
  end

  @spec reaching(t(), project_id() | [project_id()], View.t()) :: [project_id()]
  def reaching(graph, project_ids, view \\ :all)

  def reaching(%__MODULE__{} = graph, project_ids, view) when is_list(project_ids) do
    reachable(project_ids, adjacency(graph, view, :incoming), %{})
  end

  def reaching(%__MODULE__{} = graph, project_id, view) do
    reaching(graph, [project_id], view)
  end

  @spec path(t(), project_id(), project_id(), View.t()) :: {:ok, [project_id()]} | :no_path
  def path(%__MODULE__{} = graph, from, to, view \\ :all) do
    neighbors = adjacency(graph, view, :outgoing)

    if Map.has_key?(graph.projects, from) and Map.has_key?(graph.projects, to) do
      shortest_path(:queue.in([from], :queue.new()), to, neighbors, %{from => true})
    else
      :no_path
    end
  end

  @spec topo_sort(t(), View.t()) :: [project_id()]
  def topo_sort(%__MODULE__{} = graph, view \\ :all) do
    case topology(graph, view) do
      {:ok, sorted} -> sorted
      {:cycle, _witness} -> []
    end
  end

  @doc false
  def topology(%__MODULE__{} = graph, view) do
    neighbors = adjacency(graph, view, :outgoing)
    vertices = graph.projects |> Map.keys() |> Enum.sort()

    case order(vertices, neighbors, {%{}, []}, []) do
      {:ok, {_visited, sorted}} -> {:ok, sorted}
      {:cycle, _witness} = cycle -> cycle
    end
  end

  defp order([], _neighbors, result, _ancestors), do: {:ok, result}

  defp order([vertex | rest], neighbors, {visited, sorted} = result, ancestors) do
    cond do
      Map.has_key?(visited, vertex) ->
        order(rest, neighbors, result, ancestors)

      vertex in ancestors ->
        participants = Enum.take_while(ancestors, &(&1 != vertex))
        {:cycle, [vertex | Enum.reverse(participants, [vertex])]}

      true ->
        with {:ok, {visited, sorted}} <-
               order(Map.get(neighbors, vertex, []), neighbors, {visited, sorted}, [
                 vertex | ancestors
               ]) do
          order(rest, neighbors, {Map.put(visited, vertex, true), [vertex | sorted]}, ancestors)
        end
    end
  end

  defp reachable([], _neighbors, visited), do: visited |> Map.keys() |> Enum.sort()

  defp reachable([vertex | rest], neighbors, visited) do
    if Map.has_key?(visited, vertex),
      do: reachable(rest, neighbors, visited),
      else:
        reachable(
          Map.get(neighbors, vertex, []) ++ rest,
          neighbors,
          Map.put(visited, vertex, true)
        )
  end

  defp shortest_path(queue, target, neighbors, visited) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        :no_path

      {{:value, [^target | _] = path}, _queue} ->
        {:ok, Enum.reverse(path)}

      {{:value, [vertex | _] = path}, queue} ->
        next = Enum.reject(Map.get(neighbors, vertex, []), &Map.has_key?(visited, &1))

        queue =
          Enum.reduce(next, queue, fn neighbor, acc -> :queue.in([neighbor | path], acc) end)

        shortest_path(
          queue,
          target,
          neighbors,
          Enum.reduce(next, visited, &Map.put(&2, &1, true))
        )
    end
  end

  @spec violations(t(), map()) :: [Violation.t()]
  def violations(%__MODULE__{} = graph, _policy \\ %{}) do
    Enum.sort_by(graph.violations, fn violation ->
      {violation.code, violation.project || "", violation.dependency || :none}
    end)
  end

  @doc false
  def scoped_edges(%__MODULE__{} = graph, view) do
    graph |> edges() |> Enum.filter(&View.allowed?(&1.kind, view))
  end

  defp adjacency(graph, view, direction) do
    {from, to} = if direction == :outgoing, do: {:from, :to}, else: {:to, :from}

    graph
    |> scoped_edges(view)
    |> Enum.group_by(&Map.fetch!(&1, from), &Map.fetch!(&1, to))
    |> Map.new(fn {id, neighbors} -> {id, neighbors |> Enum.uniq() |> Enum.sort()} end)
  end
end
