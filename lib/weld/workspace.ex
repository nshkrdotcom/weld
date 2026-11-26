defmodule Weld.Workspace do
  @moduledoc """
  Discovers and loads a monorepo workspace into a graph-native representation.
  """

  alias Weld.Error
  alias Weld.Graph
  alias Weld.Graph.Edge
  alias Weld.Manifest
  alias Weld.Output
  alias Weld.Shell.Runner
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

      path == workspace.manifest.repo_root or
          String.starts_with?(path, workspace.manifest.repo_root <> "/") ->
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

  @doc false
  @spec external_dependency(Project.dep()) :: Graph.external_dep()
  def external_dependency(dep), do: Map.put(dep, :kind, infer_external_kind(dep.opts))

  defp load_projects!(manifest, project_ids) do
    projects =
      project_ids
      |> Task.async_stream(&load_project_result(manifest, &1),
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Map.new(fn
        {:ok, {:ok, project}} -> {project.id, project}
        {:ok, {:error, error}} -> raise error
        {:exit, reason} -> raise Error, "workspace probe stopped unexpectedly: #{inspect(reason)}"
      end)

    duplicate_apps = projects |> Map.values() |> Enum.frequencies_by(& &1.app)

    case duplicate_apps |> Enum.filter(fn {_app, count} -> count > 1 end) |> Enum.sort() do
      [{app, _} | _] -> raise Error, "workspace projects declare duplicate app #{app}"
      [] -> projects
    end
  end

  defp load_project_result(manifest, project_id) do
    {:ok, load_project!(manifest, project_id)}
  rescue
    error in [Error, File.Error, KeyError, ArgumentError] -> {:error, error}
  end

  defp load_project!(manifest, "."), do: load_project!(manifest, ".", manifest.repo_root)

  defp load_project!(manifest, project_id) do
    load_project!(manifest, project_id, Output.source!(manifest.repo_root, project_id))
  end

  defp load_project!(manifest, project_id, abs_path) do
    unless File.regular?(Output.source!(abs_path, "mix.exs")) do
      raise Error, "project #{project_id} is missing mix.exs"
    end

    {config, application} = probe_project!(abs_path, project_id, :dev)
    {test_config, _application} = probe_project!(abs_path, project_id, :test)

    package = Keyword.get(config, :package) || []
    app = Keyword.fetch!(config, :app)

    %Project{
      id: project_id,
      abs_path: abs_path,
      app: app,
      version: Keyword.fetch!(config, :version),
      package_name: to_string(Keyword.get(package, :name, app)),
      package_files: Keyword.get(package, :files),
      description: Keyword.get(config, :description, ""),
      docs_source_ref: if(is_list(config[:docs]), do: config[:docs][:source_ref]),
      elixir: Keyword.get(config, :elixir, "~> 1.18"),
      deps: configured_deps(config, test_config),
      application: normalize_application(application),
      elixirc_paths: normalize_paths(Keyword.get(config, :elixirc_paths, ["lib"])),
      erlc_paths: normalize_paths(Keyword.get(config, :erlc_paths, ["src"])),
      erlc_include_path: Keyword.get(config, :erlc_include_path, "include"),
      test_paths: normalize_paths(Keyword.get(test_config, :test_paths, ["test"])),
      test_elixirc_paths: normalize_paths(Keyword.get(test_config, :elixirc_paths, ["lib"])),
      test_erlc_paths: normalize_paths(Keyword.get(test_config, :erlc_paths, ["src"])),
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

    within_repo? =
      dep_path == manifest.repo_root or String.starts_with?(dep_path, manifest.repo_root <> "/")

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

    build_canonical_external_dep(dep.app, requirement, opts)
  end

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

  defp canonical_external_requirement(nil, dep), do: dep.requirement
  defp canonical_external_requirement(manifest_decl, _dep), do: manifest_decl.requirement

  defp canonical_external_opts(manifest_decl, dep) do
    dep.opts
    |> Keyword.drop([:path, :git, :github, :override, :branch, :tag, :ref, :subdir])
    |> Keyword.merge((manifest_decl && manifest_decl.opts) || [])
  end

  defp build_canonical_external_dep(app, requirement, opts)
       when is_binary(requirement) and requirement != "" do
    {:ok,
     %{
       app: app,
       requirement: requirement,
       opts: opts,
       original: canonical_dep_original(app, requirement, opts),
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

  defp canonical_dep_original(app, nil, opts), do: {app, opts}
  defp canonical_dep_original(app, requirement, []), do: {app, requirement}
  defp canonical_dep_original(app, requirement, opts), do: {app, requirement, opts}

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

  defp configured_deps(config, test_config) do
    deps = normalize_deps(Keyword.get(config, :deps, []))
    apps = MapSet.new(deps, & &1.app)

    test_deps =
      test_config
      |> Keyword.get(:deps, [])
      |> normalize_deps()
      |> Enum.reject(&MapSet.member?(apps, &1.app))
      |> Enum.map(fn dep ->
        opts = Keyword.put_new(dep.opts, :only, :test)
        %{dep | opts: opts, original: canonical_dep_original(dep.app, dep.requirement, opts)}
      end)

    deps ++ test_deps
  end

  defp normalize_paths(path) when is_binary(path), do: [path]
  defp normalize_paths(paths) when is_list(paths), do: Enum.sort(paths)

  defp normalize_application(application) when is_list(application) do
    mod =
      case Keyword.get(application, :mod) do
        nil ->
          nil

        {module, args} when is_atom(module) ->
          {module, args}

        other ->
          raise Error, "unsupported application mod shape: #{inspect(other)}"
      end

    %{
      extra_applications: normalize_atoms(Keyword.get(application, :extra_applications, [])),
      included_applications:
        normalize_atoms(Keyword.get(application, :included_applications, [])),
      registered: normalize_atoms(Keyword.get(application, :registered, [])),
      mod: mod
    }
  end

  defp normalize_atoms(values) when is_atom(values), do: [values]

  defp normalize_atoms(values) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_atom(value) -> value
      other -> raise Error, "expected atom in application config, got: #{inspect(other)}"
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp existing_copy_dirs(abs_path) do
    ["lib", "src", "c_src", "include", "priv"]
    |> Enum.filter(&File.dir?(Path.join(abs_path, &1)))
  end

  defp classify_relative_owner(workspace, relative) do
    owner =
      workspace
      |> projects()
      |> Enum.filter(&owns_relative_path?(&1, relative))
      |> Enum.max_by(&byte_size(&1.id), fn -> nil end)

    if owner, do: {:project, owner.id}, else: :global
  end

  defp owns_relative_path?(%Project{id: "."}, _relative), do: true

  defp owns_relative_path?(project, relative) do
    relative == project.id or String.starts_with?(relative, "#{project.id}/")
  end

  @probe_marker "WELD_PROJECT_FACTS:"

  defp probe_project!(path, id, env) do
    script = """
    Mix.start()
    Mix.Project.in_project(:weld_probe, ".", [], fn module ->
      config = Mix.Project.config()
      keys = ~w(app version package description docs elixir deps elixirc_paths erlc_paths
                erlc_include_path test_paths)a
      config = Keyword.take(config, keys)
      config = Keyword.update(config, :docs, [], fn
        docs when is_list(docs) -> Keyword.take(docs, [:source_ref])
        _ -> []
      end)
      application = if function_exported?(module, :application, 0), do: module.application(), else: []
      encoded = {config, application} |> :erlang.term_to_binary() |> Base.encode64()
      IO.puts("\n#{@probe_marker}" <> encoded)
    end)
    """

    result =
      Runner.run!("elixir", ["-e", script],
        cd: path,
        seconds: 30,
        env: %{"MIX_ENV" => to_string(env)}
      )

    with {output, 0} <- result,
         line when not is_nil(line) <-
           Enum.find(
             String.split(output, "\n", trim: true),
             &String.starts_with?(&1, @probe_marker)
           ),
         {:ok, binary} <- Base.decode64(String.replace_prefix(line, @probe_marker, "")) do
      # Source Mix code is already trusted. Decode only the explicitly selected
      # metadata fields from the isolated VM, never an external network value.
      :erlang.binary_to_term(binary)
    else
      {_, status} -> raise Error, "Mix metadata probe failed for #{id} in #{env} (exit #{status})"
      _ -> raise Error, "invalid Mix metadata from #{id} in #{env}"
    end
  end
end
