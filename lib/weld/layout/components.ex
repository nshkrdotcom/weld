defmodule Weld.Layout.Components do
  @moduledoc false

  alias Weld.{Error, Git, Hash, Plan, SourceFormatter}
  alias Weld.Config.Generator
  alias Weld.Layout.{FilePlan, Support}
  alias Weld.Plan.Inventory
  alias Weld.Projector.{Live, SourceProject}

  # The component layout produces the same operations as flat layout before
  # the materializer creates the output. Generation is never rerun in the stage.
  def plan!(%Plan{} = plan) do
    Support.validate_inputs!(plan)
    validate_component_test_paths!(plan)
    validate_include_paths!(Plan.projects_for_view(plan, :test))

    compiler_roots =
      Enum.flat_map(plan.selected_projects, fn project ->
        Enum.map(project.elixirc_paths, &Path.expand(&1, project.abs_path))
      end)

    SourceProject.validate_modules!(compiler_roots)
    root = plan.manifest.repo_root
    repos = Support.detect_repo_infos(plan.selected_projects)

    structural = [
      plan.manifest.manifest_path | Enum.map(plan.structural_inputs, &Path.join(root, &1))
    ]

    inputs = Enum.filter(structural, &File.regular?/1)

    config =
      Generator.plan!(plan.selected_projects, repos, package_repo_layout(plan.selected_projects),
        shared_test_configs: Enum.map(plan.selected_projects, & &1.id),
        planning_inputs: Enum.map(repos, & &1.source) ++ inputs,
        root_config_overlays:
          List.wrap(root_ecto_repos_overlay(repos, plan.artifact.package.otp_app))
      )

    roots =
      Enum.reject(
        plan.source_roots,
        &(&1.target == "test" and not plan.artifact.verify.component_tests)
      )

    source_ops =
      for entry <- plan.source_inventory do
        operation =
          if entry.kind == :artifact_test and not plan.artifact.verify.component_tests,
            do: :copy,
            else: :link_or_copy

        FilePlan.copy(Path.join(root, entry.source), entry.target, entry.kind, operation)
      end

    operations = Weld.Shell.Inputs.add_operations!(plan, source_ops ++ config.operations)

    operations =
      if Enum.any?(operations, &(&1.target == "README.md")),
        do: operations,
        else:
          operations ++
            [FilePlan.generated("README.md", "# #{plan.artifact.package.name}\n", :docs)]

    for path <- projected_test_paths(plan) do
      unless Enum.any?(operations, &(&1.target == Path.join(path, "test_helper.exs"))) do
        raise Error, "projected test path requires test_helper.exs: #{path}"
      end
    end

    opts = [
      bootstrapped_apps: config.bootstrapped_apps,
      bootstrapped_config_sources: config.bootstrapped_sources,
      generate_config?: true
    ]

    app = generated_application(plan, opts)

    targets =
      Enum.map(operations, & &1.target) ++
        ["mix.exs"] ++ if(app.module, do: [generated_application_relative_path(plan)], else: [])

    opts =
      Keyword.put(
        opts,
        :package_files,
        Weld.Shell.Inputs.publication_files(plan, targets, package_files(plan, opts))
      )

    generated_inputs = Enum.uniq(inputs ++ Enum.flat_map(config.operations, & &1.sources))
    full = FilePlan.validate!(operations ++ generated_operations(plan, opts, generated_inputs))

    guard =
      Live.guard_source(plan,
        directories: Enum.map(roots, &Path.join(root, &1.source)),
        digests: for(op <- full, op.operation != :link_or_copy, source <- op.sources, do: source),
        topology:
          if(plan.artifact.verify.component_tests,
            do: [],
            else: Enum.map(plan.artifact.verify.artifact_tests, &Path.join(root, &1))
          )
      )

    live =
      FilePlan.validate!(
        operations ++
          generated_operations(plan, opts ++ [live?: true, live_guard: guard], generated_inputs)
      )

    %{
      full: full,
      live: live,
      package_files: opts[:package_files],
      live_roots: roots,
      config_warnings: config.warnings
    }
  end

  defp generated_operations(plan, opts, inputs) do
    app = generated_application(plan, opts)

    app_ops =
      if app.module do
        content =
          application_module_contents(app, plan.artifact.package.otp_app)
          |> SourceFormatter.format!()

        [
          FilePlan.generated(
            generated_application_relative_path(plan),
            content,
            :compiled,
            inputs
          )
        ]
      else
        []
      end

    mix = mixfile_contents(plan, opts) |> SourceFormatter.format!()
    [FilePlan.generated("mix.exs", mix, :metadata, inputs) | app_ops]
  end

  @spec package_files(Plan.t(), keyword()) :: [String.t()]
  def package_files(%Plan{} = plan, opts \\ []) do
    component_roots =
      plan.selected_projects
      |> Enum.flat_map(fn project ->
        runtime_roots(project)
        |> Enum.map(&Path.join(["components", component_dir(project), &1]))
      end)

    ["mix.exs"]
    |> Kernel.++(generated_root_paths(plan, opts))
    |> Kernel.++(bootstrap_package_paths(opts))
    |> Kernel.++(component_roots)
    |> Kernel.++(Support.root_tooling_files(plan))
    |> Kernel.++(plan.artifact.output.docs)
    |> Kernel.++(plan.artifact.output.assets)
    |> Enum.uniq()
    |> List.delete("projection.lock.json")
    |> Enum.sort()
  end

  defp bootstrap_package_paths(opts) do
    if Keyword.get(opts, :bootstrapped_config_sources, []) == [],
      do: [],
      else: ["priv/weld/config"]
  end

  defp runtime_roots(project) do
    Inventory.normalize_paths(
      project,
      project.copy_dirs ++
        project.elixirc_paths ++ project.erlc_paths ++ [project.erlc_include_path]
    )
    |> Enum.uniq()
    |> Enum.filter(&File.dir?(Path.expand(&1, project.abs_path)))
    |> then(fn roots ->
      Enum.reject(roots, fn path ->
        Enum.any?(roots, &(&1 != path and String.starts_with?(path, &1 <> "/")))
      end)
    end)
    |> Enum.sort()
  end

  defp projected_test_paths(%Plan{artifact: %{verify: %{component_tests: false}}} = plan) do
    if plan.artifact.verify.artifact_tests == [], do: [], else: ["test"]
  end

  defp projected_test_paths(plan) do
    components =
      plan.selected_projects
      |> Enum.flat_map(fn project ->
        Inventory.normalize_paths(project, project.test_paths)
        |> Enum.filter(&File.dir?(Path.expand(&1, project.abs_path)))
        |> Enum.map(&Path.join(["components", component_dir(project), &1]))
      end)

    artifacts =
      plan.artifact.verify.artifact_tests
      |> Enum.with_index(1)
      |> Enum.map(fn {_path, index} -> "test/artifact_#{index}" end)

    Enum.uniq(components ++ artifacts)
  end

  defp component_test_compile_paths(%Plan{artifact: %{verify: %{component_tests: false}}}), do: []

  defp component_test_compile_paths(plan) do
    Plan.projects_for_view(plan, :test)
    |> Enum.flat_map(fn project ->
      paths =
        if Plan.selected?(plan, project.id),
          do: project.test_elixirc_paths,
          else: project.elixirc_paths

      project
      |> Inventory.normalize_paths(paths)
      |> Enum.filter(&File.dir?(Path.expand(&1, project.abs_path)))
      |> Enum.map(&Path.join(["components", component_dir(project), &1]))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp component_test_erlc_paths(%Plan{artifact: %{verify: %{component_tests: false}}}, runtime),
    do: runtime

  defp component_test_erlc_paths(plan, _runtime) do
    Plan.projects_for_view(plan, :test)
    |> Enum.flat_map(fn project ->
      paths =
        if Plan.selected?(plan, project.id), do: project.test_erlc_paths, else: project.erlc_paths

      project
      |> Inventory.normalize_paths(paths)
      |> Enum.map(&Path.join(["components", component_dir(project), &1]))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp package_external_deps(%Plan{artifact: %{verify: %{component_tests: false}}} = plan),
    do: plan.external_deps

  defp package_external_deps(plan) do
    runtime_apps = Enum.map(plan.external_deps, & &1.app)

    test_deps =
      plan
      |> Plan.external_deps_for_view(:test)
      |> Enum.reject(&(&1.app in runtime_apps))
      |> Enum.map(fn dep ->
        opts = Keyword.put_new(dep.opts, :only, :test)
        original = if dep.requirement, do: {dep.app, dep.requirement, opts}, else: {dep.app, opts}
        %{dep | opts: opts, original: original}
      end)

    plan.external_deps ++ test_deps
  end

  defp validate_component_test_paths!(%Plan{artifact: %{verify: %{component_tests: false}}}),
    do: :ok

  defp validate_component_test_paths!(plan) do
    for project <- plan.selected_projects do
      compiled = Inventory.normalize_paths(project, project.elixirc_paths ++ project.erlc_paths)

      test_compiled =
        Inventory.normalize_paths(
          project,
          project.test_elixirc_paths ++ project.test_erlc_paths
        ) -- compiled

      tests = Inventory.normalize_paths(project, project.test_paths) ++ test_compiled

      for runtime <- runtime_roots(project),
          test <- tests,
          Inventory.covered?(test, runtime) or Inventory.covered?(runtime, test) do
        raise Error,
              "component #{project.id} test input overlaps a published runtime root: #{test}"
      end
    end
  end

  # Mix compiler roots inside the project must remain relative.
  defp render_paths(paths, _opts), do: inspect(paths)

  defp mixfile_contents(plan, opts) do
    package = plan.artifact.package
    module_name = "#{Macro.camelize(to_string(package.otp_app))}.MixProject"
    application = generated_application(plan, opts)
    elixirc_paths = component_paths(plan.selected_projects, & &1.elixirc_paths, plan, opts)
    erlc_paths = component_paths(plan.selected_projects, & &1.erlc_paths)
    test_paths = projected_test_paths(plan)
    test_compile_paths = component_test_compile_paths(plan)

    test_elixirc_paths =
      if plan.artifact.verify.component_tests,
        do: Enum.uniq(generated_root_paths(plan, opts) ++ test_compile_paths),
        else: elixirc_paths

    test_erlc_paths = component_test_erlc_paths(plan, erlc_paths)
    include_paths = component_include_paths(plan.selected_projects)

    test_include_paths =
      if plan.artifact.verify.component_tests,
        do: component_include_paths(Plan.projects_for_view(plan, :test)),
        else: include_paths

    deps = render_deps(package_external_deps(plan), package.development_dependencies)

    files =
      Keyword.get(opts, :package_files, package_files(plan, opts))
      |> Enum.map_join(",\n        ", &inspect/1)

    docs = Support.render_docs_options(plan)
    links = package.links |> fallback_links(plan.manifest.repo_root) |> inspect(pretty: true)
    application_config = application_config_literal(application)

    """
    defmodule #{module_name} do
      use Mix.Project

      def project do
        #{opts[:live_guard] || ""}
        [
          app: #{inspect(package.otp_app)},
          version: #{inspect(package.version)},
          #{if(opts[:live?], do: "", else: "build_path: \"_build\",")}
          elixir: #{inspect(package.elixir)},
          start_permanent: Mix.env() == :prod,
          elixirc_paths: elixirc_paths(Mix.env()),
          erlc_paths: erlc_paths(Mix.env()),
          erlc_options: erlc_options(Mix.env()),
          test_paths: #{render_paths(test_paths, opts)},
          #{if(opts[:live?], do: "aliases: #{Live.aliases_source()},", else: "")}
          deps: deps(),
          description: #{inspect(package.description)},
          package: package(),
          docs: docs()
        ]
      end

      def application do
        #{application_config}
      end

      def elixirc_paths(:test) do
        base = #{render_paths(test_elixirc_paths, opts)}

        if File.dir?(Path.expand("test/support", __DIR__)) do
          base ++ ["test/support"]
        else
          base
        end
      end

      def elixirc_paths(_env), do: #{render_paths(elixirc_paths, opts)}

      defp erlc_paths(:test), do: #{render_paths(test_erlc_paths, opts)}
      defp erlc_paths(_env), do: #{render_paths(erlc_paths, opts)}

      defp erlc_options(env) do
        paths = if env == :test, do: #{inspect(test_include_paths)}, else: #{inspect(include_paths)}
        Enum.map(paths, fn path -> {:i, path |> Path.expand(__DIR__) |> String.to_charlist()} end)
      end

      defp deps do
        [
    #{deps}
        ]
      end

      defp package do
        [
          licenses: #{inspect(package.licenses)},
          maintainers: #{inspect(package.maintainers)},
          links: #{links},
          files: [
            #{files}
          ]
        ]
      end

      defp docs do
        #{docs}
      end
    end
    """
  end

  defp component_paths(projects, path_fun, plan \\ nil, opts \\ []) do
    root_paths =
      case generated_root_paths(plan, opts) do
        [] -> []
        root_paths -> root_paths
      end

    root_paths ++
      (projects
       |> Enum.flat_map(fn project ->
         project
         |> Inventory.normalize_paths(path_fun.(project))
         |> Enum.map(fn relative ->
           Path.join(["components", component_dir(project), relative])
         end)
       end)
       |> Enum.uniq()
       |> Enum.sort())
  end

  defp component_include_paths(projects) do
    for project <- projects,
        relative <- Inventory.normalize_paths(project, [project.erlc_include_path]),
        File.dir?(Path.expand(relative, project.abs_path)),
        do: Path.join(["components", component_dir(project), relative])
  end

  defp validate_include_paths!(projects) do
    headers =
      for project <- projects,
          root = Path.expand(project.erlc_include_path, project.abs_path),
          File.dir?(root),
          path <- Hash.list_files(root),
          do: {Path.relative_to(path, root), path}

    for {relative, files} <- Enum.group_by(headers, &elem(&1, 0), &elem(&1, 1)) do
      if length(Enum.uniq_by(files, &Hash.sha256_file/1)) > 1,
        do: raise(Error, "conflicting Erlang include #{relative} across selected projects")
    end
  end

  defp render_deps(external_deps, development_dependencies) do
    external = Enum.map(external_deps, fn dep -> dep.original end)

    (external ++ development_dependencies ++ [{:ex_doc, "~> 0.40", only: :dev, runtime: false}])
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map_join(",\n      ", &inspect/1)
  end

  defp fallback_links(links, _repo_root) when map_size(links) > 0, do: links

  defp fallback_links(_links, repo_root) do
    case Git.remote_url(repo_root) do
      nil -> %{"Source" => "https://github.com/nshkrdotcom/weld"}
      remote -> %{"Source" => remote}
    end
  end

  defp generated_root_paths(nil, _opts), do: []

  defp generated_root_paths(plan, opts) do
    []
    |> maybe_add_generated_root_path(
      case generated_application(plan, opts) do
        %{module: nil} -> nil
        _application -> "lib"
      end
    )
    |> maybe_add_generated_root_path(
      if(Keyword.get(opts, :generate_config?, false), do: "config")
    )
  end

  defp generated_application(%Plan{} = plan, opts) do
    children =
      plan.selected_projects
      |> Enum.map(& &1.application.mod)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    bootstrapped_apps =
      opts
      |> Keyword.get(:bootstrapped_apps, [])
      |> Enum.uniq()
      |> Enum.sort()

    bootstrapped_sources =
      opts
      |> Keyword.get(:bootstrapped_config_sources, [])
      |> Enum.uniq()

    %{
      module:
        if(children == [] and bootstrapped_sources == [],
          do: nil,
          else:
            Module.concat([
              Macro.camelize(to_string(plan.artifact.package.otp_app)),
              "Application"
            ])
        ),
      bootstrapped_apps: bootstrapped_apps,
      bootstrapped_sources: bootstrapped_sources,
      children: children,
      extra_applications:
        plan.selected_projects
        |> Enum.flat_map(& &1.application.extra_applications)
        |> Kernel.++([:logger])
        |> Enum.uniq()
        |> Enum.sort(),
      included_applications:
        plan.selected_projects
        |> Enum.flat_map(& &1.application.included_applications)
        |> Enum.uniq()
        |> Enum.sort(),
      registered:
        plan.selected_projects
        |> Enum.flat_map(& &1.application.registered)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp application_config_literal(application) do
    [
      extra_applications: application.extra_applications
    ]
    |> maybe_put_config(:included_applications, application.included_applications)
    |> maybe_put_config(:registered, application.registered)
    |> maybe_put_config(:mod, if(application.module, do: {application.module, []}))
    |> inspect(pretty: true, limit: :infinity)
  end

  defp maybe_put_config(config, _key, nil), do: config
  defp maybe_put_config(config, _key, []), do: config
  defp maybe_put_config(config, key, value), do: Keyword.put(config, key, value)

  defp generated_application_relative_path(plan) do
    otp_app = to_string(plan.artifact.package.otp_app)
    Path.join(["lib", otp_app, "application.ex"])
  end

  defp application_module_contents(
         %{
           module: module,
           bootstrapped_apps: bootstrapped_apps,
           bootstrapped_sources: bootstrapped_sources,
           children: children
         },
         artifact_otp_app
       ) do
    rendered_children =
      children
      |> Enum.map_join(",\n      ", fn {child_module, args} ->
        """
        %{
          id: #{inspect(child_module)},
          start: {#{inspect(child_module)}, :start, [:normal, #{inspect(args)}]},
          type: :supervisor
        }\
        """
      end)

    bootstrap_helpers =
      if bootstrapped_sources == [] do
        ""
      else
        """

          @boot_env Mix.env()
          @bootstrapped_apps #{inspect(bootstrapped_apps)}
          @bootstrapped_sources #{inspect(bootstrapped_sources, pretty: true, limit: :infinity)}

          defp bootstrap_workspace_app_env! do
            Enum.each(@bootstrapped_sources, fn source ->
              source
              |> bootstrap_source_paths()
              |> Enum.each(&apply_bootstrap_source!/1)
            end)
          end

          defp bootstrap_source_paths(%{
                 config_path: config_path,
                 env_path_fallbacks: env_path_fallbacks,
                 runtime_path: runtime_path
               }) do
            []
            |> maybe_add_bootstrap_path(config_path || Map.get(env_path_fallbacks, @boot_env))
            |> maybe_add_bootstrap_path(runtime_path)
          end

          defp maybe_add_bootstrap_path(paths, nil), do: paths
          defp maybe_add_bootstrap_path(paths, path), do: paths ++ [path]

          defp apply_bootstrap_source!(relative_path) do
            absolute_path = artifact_path(relative_path)

            unless File.regular?(absolute_path) do
              raise "missing projected workspace config source: \#{absolute_path}"
            end

            {config, _imports} = Config.Reader.read_imports!(absolute_path, env: @boot_env)

            config
            |> Enum.filter(fn {app, _value} -> app in @bootstrapped_apps end)
            |> case do
              [] -> :ok
              workspace_config -> Application.put_all_env(workspace_config, persistent: true)
            end
          end

          defp artifact_path(relative_path) do
            Application.app_dir(#{inspect(artifact_otp_app)}, Path.join(["priv", "weld", relative_path]))
          end
        """
      end

    """
    defmodule #{inspect(module)} do
      @moduledoc false

      use Application

      def start(_type, _args) do
        #{if(bootstrapped_sources == [], do: ":ok", else: "bootstrap_workspace_app_env!()")}

        children = [
          #{rendered_children}
        ]

        Supervisor.start_link(children,
          strategy: :one_for_one,
          name: __MODULE__.Supervisor
        )
      end
    #{bootstrap_helpers}
    end
    """
  end

  defp root_ecto_repos_overlay([], _artifact_otp_app), do: nil

  defp root_ecto_repos_overlay(repo_infos, artifact_otp_app) do
    """
    config #{inspect(artifact_otp_app)},
      ecto_repos: #{inspect(Enum.map(repo_infos, & &1.module))}
    """
  end

  defp package_repo_layout(projects) do
    repo_paths =
      projects
      |> Enum.filter(&File.dir?(Path.join(&1.abs_path, "priv/repo")))
      |> Map.new(fn project ->
        {project.id, Path.join(["components", component_dir(project), "priv/repo"])}
      end)

    %{repo_paths: repo_paths}
  end

  defp maybe_add_generated_root_path(paths, nil), do: paths
  defp maybe_add_generated_root_path(paths, path), do: paths ++ [path]

  defp component_dir(%{id: "."}), do: "root"
  defp component_dir(%{id: id}), do: id
end
