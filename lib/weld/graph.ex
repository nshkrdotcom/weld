defmodule Weld.Graph do
  @moduledoc """
  Immutable workspace dependency graph.
  """

  alias __MODULE__, as: Graph
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

  @doc "Whether a Git source is a filesystem locator rather than a remote URL or scp address."
  def local_git_locator?(value) when is_binary(value) do
    Path.type(value) == :absolute or
      String.starts_with?(value, ["./", "../", "\\"]) or
      Regex.match?(~r{\A(?:file://|[A-Za-z]:[/\\])}i, value) or
      not Regex.match?(~r{\A[^/\\]+:}, value)
  end

  @doc "Build actual dependency facts from explicit manifest/project observations."
  def build(manifest, projects) do
    apps = Enum.map(projects, fn {_id, project} -> project.app end)
    unless length(Enum.uniq(apps)) == length(apps), do: raise(Weld.Error, code: :duplicate_app, phase: :plan, message: "workspace projects declare duplicate apps")
    app_index = Map.new(projects, fn {project_id, project} -> {project.app, project_id} end)
    path_index = Map.new(projects, fn {project_id, project} -> {project.abs_path, project_id} end)

    Enum.reduce(projects, Graph.new(), fn {_project_id, project}, graph ->
      Graph.add_project(graph, project)
    end)
    |> add_dependencies(projects, manifest, app_index, path_index)
  end

  defp add_dependencies(graph, projects, manifest, app_index, path_index) do
    Enum.reduce(projects, graph, fn {_project_id, project}, current_graph ->
      Enum.reduce(project.deps, current_graph, fn dep, acc ->
        handle_dep(acc, manifest, project, dep, app_index, path_index)
      end)
    end)
    |> finalize()
  end

  defp handle_dep(graph, manifest, project, dep, app_index, path_index) do
    opts = dep.opts

    cond do
      opts[:path] ->
        path_dep(graph, manifest, project, dep, path_index)

      opts[:git] || opts[:github] ->
        case canonical_external_dep(manifest, dep) do
          {:ok, external_dep} ->
            Graph.add_external_dep(graph, project.id, external_dep)

          :error ->
            Graph.add_violation(
              graph,
              Violation.new(
                :external_git_dependency,
                "git dependencies are not supported in weld artifacts without a canonical dependency declaration",
                project: project.id,
                dependency: dep.app
              )
            )
        end

      Map.has_key?(app_index, dep.app) and not compatible_project_dependency?(dep, Map.fetch!(graph.projects, Map.fetch!(app_index, dep.app))) ->
        Graph.add_violation(graph, Violation.new(:incompatible_dependency_identity,
          "declared dependency package/version conflicts with the discovered project",
          project: project.id, dependency: dep.app,
          details: %{target: Map.fetch!(app_index, dep.app)}))

      Map.has_key?(app_index, dep.app) ->
        target = Map.fetch!(app_index, dep.app)

        Graph.add_edge(
          graph,
          %Edge{
            from: project.id,
            to: target,
            app: dep.app,
            requirement: dep.requirement,
            kind:
              infer_kind(
                dep.opts,
                project.classification,
                Map.fetch!(graph.classifications, target)
              ),
            opts: dep.opts
          }
        )

      true ->
        case external_package_dependency(manifest, dep) do
          {:ok, external_dep} -> Graph.add_external_dep(graph, project.id, external_dep)
          {:error, message} ->
            Graph.add_violation(graph, Violation.new(:conflicting_dependency, message,
              project: project.id, dependency: dep.app,
              details: %{source: Path.join(project.id, "mix.exs"), requirement: dep.requirement,
                hint: "Declare one compatible versioned dependency or an explicit canonical source."}))
        end
    end
  end

  defp compatible_project_dependency?(dep, project) do
    package_matches = to_string(dep.opts[:hex] || dep.app) == (project.package_name || to_string(project.app))
    requirement_matches = case dep.requirement do
      nil -> true
      value when is_binary(value) ->
        case Version.parse_requirement(value) do
          {:ok, requirement} -> Version.match?(project.version, requirement)
          :error -> false
        end
      _ -> false
    end
    package_matches and requirement_matches
  end

  defp path_dep(graph, manifest, project, dep, path_index) do
    dep_path = Path.expand(dep.opts[:path], project.abs_path)

    within_repo? =
      dep_path == manifest.repo_root or String.starts_with?(dep_path, manifest.repo_root <> "/")

    cond do
      Map.has_key?(path_index, dep_path) and Map.fetch!(graph.projects, Map.fetch!(path_index, dep_path)).app != dep.app ->
        Graph.add_violation(graph, Violation.new(:incompatible_dependency_app,
          "path dependency app does not match the target project", project: project.id,
          dependency: dep.app, details: %{target: Map.fetch!(path_index, dep_path)}))

      Map.has_key?(path_index, dep_path) ->
        target = Map.fetch!(path_index, dep_path)

        Graph.add_edge(
          graph,
          %Edge{
            from: project.id,
            to: target,
            app: dep.app,
            requirement: dep.requirement,
            kind:
              infer_kind(
                dep.opts,
                project.classification,
                Map.fetch!(graph.classifications, target)
              ),
            opts: dep.opts
          }
        )

      not within_repo? and not Map.has_key?(manifest.dependencies, dep.app) ->
        Graph.add_violation(graph, Violation.new(:external_path_dependency,
          "path dependency outside the workspace requires an explicit canonical dependency declaration",
          project: project.id, dependency: dep.app))

      not within_repo? ->
        case canonical_external_dep(manifest, dep) do
          {:ok, external_dep} ->
            Graph.add_external_dep(graph, project.id, external_dep)

          :error ->
            Graph.add_violation(
              graph,
              Violation.new(
                :external_path_dependency,
                "path dependency points outside the workspace without a canonical dependency declaration",
                project: project.id,
                dependency: dep.app,
                details: %{path: dep_path}
              )
            )
        end

      Weld.Core.Facts.regular?(project.facts, Path.join(dep_path, "mix.exs")) ->
        Graph.add_violation(
          graph,
          Violation.new(
            :path_dep_to_undiscovered_project,
            "path dependency points at a workspace project that was not discovered",
            project: project.id,
            dependency: dep.app,
            details: %{path: Path.relative_to(dep_path, manifest.repo_root)}
          )
        )

      within_repo? ->
        Graph.add_violation(
          graph,
          Violation.new(
            :unresolved_path_dependency,
            "path dependency could not be resolved",
            project: project.id,
            dependency: dep.app,
            details: %{path: Path.relative_to(dep_path, manifest.repo_root)}
          )
        )
    end
  end

  defp canonical_external_dep(manifest, dep) do
    manifest_decl = Map.get(manifest.dependencies, dep.app)
    requirement = canonical_external_requirement(manifest_decl, dep)
    opts = canonical_external_opts(manifest_decl, dep)

    if Enum.all?([:runtime, :optional, :only, :targets], &same_scope?(&1, dep.opts, opts)) do
      build_canonical_external_dep(dep.app, requirement, normalize_dependency_options(opts))
    else
      :error
    end
  end

  defp external_package_dependency(manifest, dep) do
    policy = Map.get(manifest.dependencies, dep.app)
    cond do
      not is_binary(dep.requirement) or not match?({:ok, _}, Version.parse_requirement(dep.requirement)) ->
        {:error, "external package dependency has no valid version requirement"}
      is_nil(policy) ->
        build_canonical_external_dep(dep.app, dep.requirement, normalize_dependency_options(dep.opts))
      policy.requirement != dep.requirement ->
        {:error, "canonical requirement conflicts with the native external package requirement"}
      true ->
        candidate = canonical_external_opts(policy, dep) |> normalize_dependency_options()
        if normalize_dependency_options(dep.opts) == candidate do
          build_canonical_external_dep(dep.app, dep.requirement, candidate)
        else
          {:error, "canonical source or options conflict with the native external package declaration"}
        end
    end
  end

  defp same_scope?(:runtime, left, right), do: Keyword.get(left, :runtime, true) == Keyword.get(right, :runtime, true)
  defp same_scope?(:optional, left, right), do: Keyword.get(left, :optional, false) == Keyword.get(right, :optional, false)
  defp same_scope?(key, left, right), do: Enum.sort(List.wrap(left[key])) == Enum.sort(List.wrap(right[key]))

  defp finalize(graph) do
    case Graph.topology(graph, :package) do
      {:ok, _} ->
        graph

      {:cycle, cycle} ->
        Graph.add_violation(
          graph,
          Violation.new(:cycle_detected, "package graph contains a cycle",
            details: %{cycle: cycle}
          )
        )
    end
  end

  defp infer_external_kind(opts), do: infer_kind(opts, :runtime, :runtime)

  defp canonical_external_requirement(nil, dep), do: dep.requirement
  defp canonical_external_requirement(manifest_decl, _dep), do: manifest_decl.requirement

  defp canonical_external_opts(manifest_decl, dep) do
    removed = if manifest_decl, do: [:path, :git, :github, :override, :branch, :tag, :ref, :subdir, :sparse, :depth, :submodules], else: [:path, :override]
    dep.opts |> Keyword.drop(removed) |> Keyword.merge((manifest_decl && manifest_decl.opts) || [])
  end

  defp build_canonical_external_dep(app, requirement, opts)
       when is_binary(requirement) and requirement != "" do
    {:ok,
     %{
       app: app,
       requirement: requirement,
       opts: opts,
       original: dependency_tuple(app, requirement, opts),
       kind: infer_external_kind(opts)
     }}
  end

  defp build_canonical_external_dep(app, nil, opts) do
    case opts[:git] || opts[:github] do
      value when not is_nil(value) ->
        {:ok,
         %{
           app: app,
           requirement: nil,
           opts: opts,
           original: {app, opts},
           kind: infer_external_kind(opts)
         }}

      nil ->
        :error
    end
  end

  defp build_canonical_external_dep(_app, _requirement, _opts), do: :error

  def dependency_tuple(app, nil, opts), do: {app, opts}
  def dependency_tuple(app, requirement, []), do: {app, requirement}
  def dependency_tuple(app, requirement, opts), do: {app, requirement, opts}

  defp infer_kind(opts, _caller_classification, target_classification),
    do: Graph.dependency_kind(opts, target_classification)

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

  @doc false
  def normalize_dependency_options(opts) do
    opts = Enum.reduce([runtime: true, optional: false, override: false], opts, fn {key, default}, opts ->
      if opts[key] == default, do: Keyword.delete(opts, key), else: opts
    end)
    Enum.reduce([:only, :targets], opts, fn key, opts ->
      if Keyword.has_key?(opts, key), do: Keyword.put(opts, key, Enum.sort(List.wrap(opts[key]))), else: opts
    end) |> Enum.sort_by(&elem(&1, 0))
  end

  @doc false
  def merge_dependency_scopes(left, right) do
    left = %{left | opts: normalize_dependency_options(left.opts)}
    right = %{right | opts: normalize_dependency_options(right.opts)}
    left_source = {left.app, left.requirement, Keyword.delete(left.opts, :only)}
    right_source = {right.app, right.requirement, Keyword.delete(right.opts, :only)}
    if left_source == right_source do
      opts = if is_nil(left.opts[:only]) or is_nil(right.opts[:only]) do
        Keyword.delete(left.opts, :only)
      else
        scopes = (List.wrap(left.opts[:only]) ++ List.wrap(right.opts[:only])) |> Enum.uniq() |> Enum.sort()
        Keyword.put(left.opts, :only, scopes)
      end |> Enum.sort_by(&elem(&1, 0))
      dep = %{left | opts: opts, original: dependency_tuple(left.app, left.requirement, opts)}
      origins = (Map.get(left, :origins, []) ++ Map.get(right, :origins, [])) |> Enum.uniq() |> Enum.sort()
      dep = if origins == [], do: dep, else: Map.put(dep, :origins, origins)
      {:ok, if(Map.has_key?(left, :kind), do: external_dependency(dep), else: dep)}
    else
      :error
    end
  end

  @doc false
  def normalize_dependencies(deps) do
    deps |> Enum.map(fn dep ->
      opts = normalize_dependency_options(dep.opts)
      %{dep | opts: opts, original: dependency_tuple(dep.app, dep.requirement, opts)}
    end) |> Enum.group_by(&{&1.app, &1.requirement, Enum.sort(Keyword.delete(&1.opts, :only))})
    |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {_key, [first | rest]} ->
      Enum.reduce(rest, first, fn dep, acc -> {:ok, merged} = merge_dependency_scopes(acc, dep); merged end)
    end)
  end

  @doc false
  def external_dependency(dep), do: Map.put(dep, :kind, dependency_kind(dep.opts, :runtime))

  @doc false
  def dependency_kind(opts, target_classification) do
    only = opts[:only] |> List.wrap() |> Enum.uniq() |> Enum.sort()
    base = cond do
      opts[:runtime] == false -> :compile
      target_classification == :tooling -> :tooling
      true -> :runtime
    end
    if only == [] or :prod in only do
      base
    else
      kinds =
        (if :docs in only, do: [:docs], else: []) ++
        (cond do
          :dev in only -> [:dev_only]
          :test in only -> [:test]
          true -> []
        end) ++
        (if Enum.any?(only, &(&1 not in [:dev, :test, :docs])), do: [:tooling], else: [])
      case Enum.sort(Enum.uniq(kinds)) do
        [kind] -> kind
        kinds -> kinds
      end
    end
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
    origin = if project_id == ".", do: "mix.exs", else: Path.join(project_id, "mix.exs")
    dep = Map.update(dep, :origins, [origin], &Enum.sort(Enum.uniq([origin | &1])))
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
    |> Enum.sort_by(fn edge -> {edge.from, edge.to, edge.kind, Atom.to_string(edge.app), edge.requirement, edge.opts} end)
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
    |> Enum.sort_by(fn dep -> {Atom.to_string(dep.app), dep.kind, dep.requirement, dep.opts} end)
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

  @doc "Return dependencies first, with canonical ID order among each ready set."
  def topology(%__MODULE__{} = graph, view) do
    neighbors = adjacency(graph, view, :outgoing)
    vertices = graph.projects |> Map.keys() |> Enum.sort()
    dependency_layers(vertices, neighbors, [])
  end

  defp dependency_layers([], _neighbors, ordered), do: {:ok, ordered}
  defp dependency_layers(remaining, neighbors, ordered) do
    pending = MapSet.new(remaining)
    {ready, blocked} = Enum.split_with(remaining, fn id ->
      Enum.all?(Map.get(neighbors, id, []), &(not MapSet.member?(pending, &1)))
    end)
    if ready == [] do
      case order(remaining, neighbors, {%{}, []}, []) do
        {:cycle, witness} -> {:cycle, witness}
        _ -> {:cycle, remaining}
      end
    else
      dependency_layers(blocked, neighbors, ordered ++ ready)
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
