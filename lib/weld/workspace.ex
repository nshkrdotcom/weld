defmodule Weld.Workspace do
  @moduledoc """
  Discovers and loads a monorepo workspace into a graph-native representation.
  """

  alias Weld.Error
  alias Weld.Graph
  alias Weld.Graph.Edge
  alias Weld.Manifest
  alias Weld.Violation
  alias Weld.Workspace.Discovery
  alias Weld.Workspace.Project

  @enforce_keys [:manifest, :discovery, :projects, :graph]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          discovery: Discovery.result(),
          projects: %{optional(String.t()) => Project.t()},
          graph: Graph.t()
        }

  @spec load!(Manifest.t()) :: t()
  def load!(%Manifest{} = manifest) do
    discovery = Discovery.discover(manifest)
    projects = load_projects!(manifest, discovery.project_ids)
    graph = build_graph(projects, manifest)

    %__MODULE__{
      manifest: manifest,
      discovery: discovery,
      projects: projects,
      graph: graph
    }
  end

  @spec file_owner(t(), Path.t()) :: {:project, String.t()} | :global | :unknown
  def file_owner(%__MODULE__{} = workspace, path) do
    path = Path.expand(path)

    cond do
      path == workspace.manifest.manifest_path ->
        :global

      String.starts_with?(path, workspace.manifest.repo_root) ->
        relative = Path.relative_to(path, workspace.manifest.repo_root)
        classify_relative_owner(workspace, relative)

      true ->
        :unknown
    end
  end

  @spec projects(t()) :: [Project.t()]
  def projects(%__MODULE__{} = workspace) do
    workspace.projects
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp load_projects!(manifest, project_ids) do
    project_ids
    |> Enum.map(&load_project!(manifest, &1))
    |> Map.new(fn project -> {project.id, project} end)
  end

  defp load_project!(manifest, ".") do
    load_project!(manifest, ".", manifest.repo_root)
  end

  defp load_project!(manifest, project_id) do
    load_project!(manifest, project_id, Path.join(manifest.repo_root, project_id))
  end

  defp load_project!(manifest, project_id, abs_path) do
    unless File.regular?(Path.join(abs_path, "mix.exs")) do
      raise Error, "project #{project_id} is missing mix.exs"
    end

    config =
      without_module_conflicts(fn ->
        Mix.Project.in_project(unique_probe(project_id), abs_path, [], fn _module ->
          Mix.Project.config()
        end)
      end)

    %Project{
      id: project_id,
      abs_path: abs_path,
      app: Keyword.fetch!(config, :app),
      version: Keyword.fetch!(config, :version),
      elixir: Keyword.get(config, :elixir, "~> 1.18"),
      deps: normalize_deps(Keyword.get(config, :deps, [])),
      elixirc_paths: normalize_paths(Keyword.get(config, :elixirc_paths, ["lib"])),
      erlc_paths: normalize_paths(Keyword.get(config, :erlc_paths, ["src"])),
      copy_dirs: existing_copy_dirs(abs_path),
      classification: classification_for(project_id, manifest),
      publication_role: publication_role_for(project_id, manifest)
    }
  end

  defp build_graph(projects, manifest) do
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
        Graph.add_violation(
          graph,
          Violation.new(
            :external_git_dependency,
            "git dependencies are not supported in weld artifacts",
            project: project.id,
            dependency: dep.app
          )
        )

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
        Graph.add_external_dep(
          graph,
          project.id,
          Map.put(dep, :kind, infer_external_kind(dep.opts))
        )
    end
  end

  defp path_dep(graph, manifest, project, dep, path_index) do
    dep_path = Path.expand(dep.opts[:path], project.abs_path)

    cond do
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

      File.regular?(Path.join(dep_path, "mix.exs")) ->
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

      String.starts_with?(dep_path, manifest.repo_root) ->
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

      true ->
        Graph.add_violation(
          graph,
          Violation.new(
            :external_path_dependency,
            "path dependency points outside the workspace",
            project: project.id,
            dependency: dep.app,
            details: %{path: dep_path}
          )
        )
    end
  end

  defp finalize(graph) do
    if Graph.topo_sort(graph, :all) == [] and map_size(graph.projects) > 0 do
      Graph.add_violation(
        graph,
        Violation.new(:cycle_detected, "workspace graph contains a cycle")
      )
    else
      graph
    end
  end

  defp classification_for(project_id, manifest) do
    cond do
      MapSet.member?(manifest.classify.ignored, project_id) -> :ignored
      MapSet.member?(manifest.classify.tooling, project_id) -> :tooling
      MapSet.member?(manifest.classify.proofs, project_id) -> :proof
      true -> :runtime
    end
  end

  defp publication_role_for(project_id, manifest) do
    cond do
      MapSet.member?(manifest.publication.internal_only, project_id) ->
        :internal_only

      MapSet.member?(manifest.publication.separate, project_id) ->
        :separate

      feature = optional_feature_for(project_id, manifest.publication.optional) ->
        {:optional, feature}

      true ->
        :default
    end
  end

  defp optional_feature_for(project_id, optional) do
    Enum.find_value(optional, fn {feature, project_ids} ->
      if MapSet.member?(project_ids, project_id), do: feature
    end)
  end

  defp infer_external_kind(opts), do: infer_kind(opts, :runtime, :runtime)

  defp infer_kind(opts, _caller_classification, target_classification) do
    only = normalize_only(opts[:only])

    cond do
      only == [:docs] ->
        :docs

      only == [:test] ->
        :test

      only != [] and Enum.all?(only, &(&1 in [:dev, :test])) ->
        :dev_only

      opts[:runtime] == false ->
        :compile

      target_classification == :tooling ->
        :tooling

      true ->
        :runtime
    end
  end

  defp normalize_only(nil), do: []
  defp normalize_only(scope) when is_atom(scope), do: [scope]
  defp normalize_only(scopes) when is_list(scopes), do: Enum.sort(scopes)

  defp normalize_deps(deps) do
    Enum.map(deps, fn
      {app, requirement} when is_atom(app) and is_binary(requirement) ->
        %{app: app, requirement: requirement, opts: [], original: {app, requirement}}

      {app, requirement, opts} when is_atom(app) and is_list(opts) ->
        %{app: app, requirement: requirement, opts: opts, original: {app, requirement, opts}}

      {app, opts} when is_atom(app) and is_list(opts) ->
        %{app: app, requirement: nil, opts: opts, original: {app, opts}}

      other ->
        raise Error, "unsupported dependency shape: #{inspect(other)}"
    end)
  end

  defp normalize_paths(path) when is_binary(path), do: [path]
  defp normalize_paths(paths) when is_list(paths), do: Enum.sort(paths)

  defp existing_copy_dirs(abs_path) do
    ["lib", "src", "c_src", "include", "priv"]
    |> Enum.filter(&File.dir?(Path.join(abs_path, &1)))
  end

  defp classify_relative_owner(workspace, relative) do
    case Enum.find(projects(workspace), &owns_relative_path?(&1, relative)) do
      %Project{id: project_id} -> {:project, project_id}
      nil -> :global
    end
  end

  defp owns_relative_path?(project, relative) do
    relative == project.id or String.starts_with?(relative, "#{project.id}/")
  end

  defp unique_probe(project_id) do
    suffix =
      project_id
      |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
      |> String.downcase()

    String.to_atom("weld_probe_#{suffix}_#{System.unique_integer([:positive])}")
  end

  defp without_module_conflicts(fun) do
    previous = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      fun.()
    after
      Code.compiler_options(ignore_module_conflict: previous[:ignore_module_conflict])
    end
  end
end
