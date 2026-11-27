defmodule Weld.Workspace do
  @moduledoc """
  Discovers and loads a monorepo workspace into a graph-native representation.
  """

  alias Weld.Core.Facts
  alias Weld.{Error, Graph, Manifest, Output}
  alias Weld.Shell.Snapshot
  alias Weld.Workspace.{Discovery, Probe, Project}

  @enforce_keys [:manifest, :discovery, :projects, :graph]
  defstruct @enforce_keys ++ [facts: nil]

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          discovery: Discovery.result(),
          projects: %{optional(String.t()) => Project.t()},
          graph: Graph.t()
        }

  @spec load!(Manifest.t()) :: t()
  def load!(%Manifest{} = manifest, opts \\ []) do
    facts = Snapshot.collect!(manifest, opts)
    discovery = Discovery.discover(manifest, facts)
    validate_references!(manifest, discovery.project_ids)
    observations = Probe.collect!(manifest.repo_root, discovery.project_ids, opts)
    projects = load_projects!(manifest, discovery.project_ids, observations, facts)
    # The second observation detects changed helper bytes and dynamic input trees,
    # including additions/removals that were not named by Code.required_files/0.
    Snapshot.recheck!(facts)
    graph = Graph.build(manifest, projects)

    %__MODULE__{
      manifest: manifest,
      discovery: discovery,
      projects: projects,
      graph: graph,
      facts: facts
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
  defdelegate external_dependency(dep), to: Graph

  defp validate_references!(manifest, discovered) do
    classified = Enum.flat_map(manifest.classify, fn {_class, ids} -> Enum.to_list(ids) end)

    roles =
      Enum.to_list(manifest.publication.internal_only) ++
        Enum.to_list(manifest.publication.separate) ++
        Enum.flat_map(manifest.publication.optional, fn {_feature, ids} -> Enum.to_list(ids) end)

    for id <- Enum.sort(Enum.uniq(classified ++ roles ++ Map.keys(manifest.project_inputs))),
        id not in discovered do
      raise Error,
        code: :unknown_project,
        phase: :manifest,
        message: "declaration references undiscovered workspace project #{id}",
        details: %{project: id}
    end
  end

  defp load_projects!(manifest, project_ids, observations, facts) do
    projects =
      Map.new(project_ids, fn id ->
        project = load_project!(manifest, id, observations, facts)
        {id, project}
      end)

    duplicate_apps = projects |> Map.values() |> Enum.frequencies_by(& &1.app)

    case duplicate_apps |> Enum.filter(fn {_app, count} -> count > 1 end) |> Enum.sort() do
      [{app, _} | _] ->
        raise Error,
          code: :duplicate_app,
          phase: :snapshot,
          message: "workspace projects declare duplicate app #{app}"

      [] ->
        projects
    end
  end

  defp load_project!(manifest, project_id, observations, facts) do
    abs_path =
      if project_id == ".",
        do: manifest.repo_root,
        else: Output.source!(manifest.repo_root, project_id)

    environments =
      Map.new(Probe.environments(), &{&1, Map.fetch!(observations, {project_id, &1})})

    validate_environment_semantics!(project_id, environments)
    %{config: config, application: application} = Map.fetch!(environments, :dev)
    %{config: test_config} = Map.fetch!(environments, :test)

    deps_by_env =
      Map.new(environments, fn {env, observation} ->
        {env, normalize_deps(observation.config[:deps] || [])}
      end)

    required_files =
      environments
      |> Map.values()
      |> Enum.flat_map(& &1.required_files)
      |> Enum.uniq()
      |> Enum.sort()

    for path <- required_files,
        not Map.has_key?(facts.nodes, Path.join(manifest.repo_root, path)),
        do:
          raise(Error,
            code: :inputs_changed,
            phase: :snapshot,
            message: "probe required a file absent from the workspace snapshot: #{path}"
          )

    package = Keyword.get(config, :package) || []
    app = Keyword.fetch!(config, :app)

    %Project{
      id: project_id,
      abs_path: abs_path,
      app: app,
      version: Keyword.fetch!(config, :version),
      package_name: to_string(Keyword.get(package, :name, app)),
      package_files: package[:files],
      package_exclude_patterns: package[:exclude_patterns] || [],
      package_metadata: package,
      description: Keyword.get(config, :description, ""),
      docs_source_ref: if(is_list(config[:docs]), do: config[:docs][:source_ref]),
      docs: config[:docs] || [],
      compilers: config[:compilers] || [],
      elixir: Keyword.get(config, :elixir, "~> 1.18"),
      deps: configured_deps(project_id, deps_by_env),
      deps_by_env: deps_by_env,
      config_by_env:
        Map.new(environments, fn {env, observation} -> {env, observation.config} end),
      application_by_env:
        Map.new(environments, fn {env, observation} -> {env, observation.application} end),
      probe_context:
        Map.new(environments, fn {env, observation} ->
          {env, %{environment: observation.environment, target: observation.target}}
        end),
      application: normalize_application(application),
      elixirc_paths: normalize_paths(Keyword.get(config, :elixirc_paths, ["lib"])),
      erlc_paths: normalize_paths(Keyword.get(config, :erlc_paths, ["src"])),
      erlc_include_path: Keyword.get(config, :erlc_include_path, "include"),
      test_paths: normalize_paths(Keyword.get(test_config, :test_paths, ["test"])),
      test_elixirc_paths: normalize_paths(Keyword.get(test_config, :elixirc_paths, ["lib"])),
      test_erlc_paths: normalize_paths(Keyword.get(test_config, :erlc_paths, ["src"])),
      copy_dirs: existing_copy_dirs(facts, abs_path),
      classification: classification_for(project_id, manifest),
      publication_role: publication_role_for(project_id, manifest),
      probe_inputs: required_files,
      facts: facts
    }
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

  defp normalize_deps(deps) when is_list(deps) do
    Enum.map(deps, fn
      {app, requirement} when is_binary(requirement) ->
        normalized_dep!(app, requirement, [])

      {app, requirement, opts} ->
        normalized_dep!(app, requirement, opts)

      {app, opts} when is_list(opts) ->
        normalized_dep!(app, nil, opts)

      _ ->
        raise Error,
          code: :invalid_project_facts,
          phase: :snapshot,
          message: "unsupported dependency shape in Mix metadata"
    end)
  end

  defp normalize_deps(_),
    do:
      raise(Error,
        code: :invalid_project_facts,
        phase: :snapshot,
        message: "Mix deps must be a list"
      )

  defp normalized_dep!(app, requirement, opts) do
    validate_dependency_shape!(app, requirement, opts)
    validate_dependency_scope_options!(app, opts)

    %{
      app: app,
      requirement: requirement,
      opts: opts,
      original: Graph.dependency_tuple(app, requirement, opts)
    }
  end

  defp validate_dependency_shape!(app, requirement, opts) do
    unless is_atom(app) and app not in [nil, true, false] and
             (is_nil(requirement) or is_binary(requirement)) and Keyword.keyword?(opts),
           do:
             raise(Error,
               code: :invalid_project_facts,
               phase: :snapshot,
               message: "invalid dependency metadata"
             )

    unless Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts),
      do:
        raise(Error,
          code: :invalid_project_facts,
          phase: :snapshot,
          message: "duplicate dependency options for #{app}"
        )

    if is_binary(requirement) and not match?({:ok, _}, Version.parse_requirement(requirement)),
      do:
        raise(Error,
          code: :invalid_project_facts,
          phase: :snapshot,
          message: "invalid dependency requirement for #{app}"
        )
  end

  defp validate_dependency_scope_options!(app, opts) do
    for key <- [:path, :git, :github],
        Keyword.has_key?(opts, key),
        not valid_dependency_locator?(opts[key]),
        do:
          raise(Error,
            code: :invalid_project_facts,
            phase: :snapshot,
            message: "invalid #{key} dependency option for #{app}"
          )

    for key <- [:only, :targets], Keyword.has_key?(opts, key) do
      unless valid_dependency_scope?(List.wrap(opts[key])),
        do:
          raise(Error,
            code: :invalid_project_facts,
            phase: :snapshot,
            message: "invalid #{key} dependency scope for #{app}"
          )
    end
  end

  defp valid_dependency_locator?(value),
    do: is_binary(value) and value != "" and not String.contains?(value, <<0>>)

  defp valid_dependency_scope?(values),
    do: values != [] and Enum.all?(values, &(is_atom(&1) and &1 not in [nil, true, false]))

  # Preserve identical native declarations. For declarations conditional on
  # Mix.env/0, infer only the environments in which that requirement is active.
  # An unobserved custom environment cannot be guessed from differing branches.
  defp configured_deps(project_id, deps_by_env) do
    deps_by_env
    |> Enum.flat_map(fn {env, deps} -> Enum.map(deps, &{env, &1}) end)
    |> Enum.group_by(fn {_env, dep} ->
      {dep.app, dep.requirement,
       dep.app |> Graph.normalize_dependency_options(dep.opts) |> Keyword.delete(:only)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_key, observations} ->
      configured_dependency(project_id, observations)
    end)
    |> Graph.normalize_dependencies()
  end

  defp configured_dependency(project_id, observations) do
    present = observations |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    declarations = observations |> Enum.map(&elem(&1, 1)) |> Graph.normalize_dependencies()

    signatures =
      observations
      |> Enum.map(fn {_env, dep} -> Graph.normalize_dependency_options(dep.app, dep.opts) end)
      |> Enum.uniq()

    if present == Enum.sort(Probe.environments()) and length(signatures) == 1 do
      declarations
    else
      scopes =
        observations
        |> Enum.flat_map(&observed_scope!(&1, project_id))
        |> Enum.uniq()
        |> Enum.sort()

      scoped_declaration(declarations, scopes)
    end
  end

  defp observed_scope!({env, dep}, project_id) do
    declared = List.wrap(dep.opts[:only])

    if Enum.any?(declared, &(&1 not in Probe.environments())),
      do:
        environment_error!(
          project_id,
          env,
          :dependencies,
          "conditional dependency scopes name an unobserved environment; make the declaration identical across dev/test/prod"
        )

    if declared == [] or env in declared, do: [env], else: []
  end

  defp scoped_declaration(_declarations, []), do: []

  defp scoped_declaration([dep], scopes) do
    opts = Keyword.put(dep.opts, :only, scopes)
    [%{dep | opts: opts, original: Graph.dependency_tuple(dep.app, dep.requirement, opts)}]
  end

  defp validate_environment_semantics!(project_id, environments) do
    baseline = Map.fetch!(environments, :dev)

    for env <- [:test, :prod] do
      observed = Map.fetch!(environments, env)

      for key <- [:app, :version],
          observed.config[key] != baseline.config[key],
          do:
            raise(Error,
              code: :conflicting_project_identity,
              phase: :snapshot,
              message: "project #{project_id} changes #{key} between dev and #{env}",
              details: %{project: project_id, environment: env, field: key}
            )

      for key <- [
            :package,
            :description,
            :elixir,
            :compilers,
            :elixirc_options,
            :erlc_options,
            :erlc_include_path
          ],
          environment_value(observed.config, key) != environment_value(baseline.config, key),
          do:
            environment_error!(
              project_id,
              env,
              key,
              "environment-dependent package/compiler metadata is unsupported"
            )

      if Enum.sort(observed.application) != Enum.sort(baseline.application),
        do:
          environment_error!(
            project_id,
            env,
            :application,
            "environment-dependent application callbacks are unsupported"
          )

      if observed.target != baseline.target,
        do:
          environment_error!(
            project_id,
            env,
            :target,
            "the Mix target changes during source evaluation"
          )
    end

    prod = Map.fetch!(environments, :prod)

    for key <- [:elixirc_paths, :erlc_paths],
        environment_value(prod.config, key) != environment_value(baseline.config, key),
        do:
          environment_error!(
            project_id,
            :prod,
            key,
            "production compiler roots differ from dev; declare stable roots or use an explicitly supported artifact layout"
          )

    :ok
  end

  defp environment_value(config, :package), do: Enum.sort(config[:package] || [])

  defp environment_value(config, :elixirc_paths),
    do: normalize_paths(config[:elixirc_paths] || ["lib"])

  defp environment_value(config, :erlc_paths), do: normalize_paths(config[:erlc_paths] || ["src"])
  defp environment_value(config, :erlc_include_path), do: config[:erlc_include_path] || "include"

  defp environment_value(config, key) when key in [:elixirc_options, :erlc_options],
    do: Enum.sort(config[key] || [])

  defp environment_value(config, key), do: config[key]

  @spec environment_error!(binary(), atom(), atom(), binary()) :: no_return()
  defp environment_error!(project_id, env, field, reason),
    do:
      raise(Error,
        code: :unsupported_environment_semantics,
        phase: :plan,
        message: "project #{project_id} has unsupported #{env} #{field} semantics: #{reason}",
        details: %{
          project: project_id,
          environment: env,
          field: field,
          hint:
            "Keep identity, package/compiler metadata and application behavior stable; express dependency environments with explicit only scopes."
        }
      )

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

  defp existing_copy_dirs(facts, abs_path) do
    ["lib", "src", "c_src", "include", "priv"]
    |> Enum.filter(&Facts.dir?(facts, Path.join(abs_path, &1)))
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
end
