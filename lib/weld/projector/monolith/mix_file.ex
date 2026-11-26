defmodule Weld.Projector.Monolith.MixFile do
  @moduledoc false

  alias Weld.Git
  alias Weld.Plan
  alias Weld.Projector
  alias Weld.Projector.Live
  alias Weld.Projector.Monolith.FilePlan
  alias Weld.SourceFormatter

  def plan!(%Plan{} = plan, operations, opts) do
    application = generated_application(plan, opts)
    inputs = Keyword.get(opts, :inputs, [])

    app_operations =
      if application.module do
        relative = Path.join(["lib", to_string(plan.artifact.package.otp_app), "application.ex"])

        [
          FilePlan.generated(
            relative,
            application_module_contents(application, plan.artifact.package.otp_app)
            |> SourceFormatter.format!(),
            :compiled,
            inputs
          )
        ]
      else
        []
      end

    paths = Enum.map(operations ++ app_operations, & &1.target)

    mix =
      FilePlan.generated(
        "mix.exs",
        mixfile_contents(plan, paths, application, opts) |> SourceFormatter.format!(),
        :metadata,
        inputs
      )

    %{operations: [mix | app_operations], package_files: package_files(plan, paths)}
  end

  def package_files(%Plan{} = plan, paths, opts \\ []) do
    package_dir_files(paths, Keyword.get(opts, :include_tests?, false))
    |> Kernel.++(plan.artifact.output.docs)
    |> Kernel.++(plan.artifact.output.assets)
    |> Kernel.++(["mix.exs"])
    |> Enum.uniq()
    |> List.delete("projection.lock.json")
    |> collapse_descendant_paths()
    |> Enum.sort()
  end

  defp mixfile_contents(plan, paths, application, opts) do
    package = plan.artifact.package
    module_name = "#{Macro.camelize(to_string(package.otp_app))}.MixProject"
    test_erlc_paths = build_erlc_paths(paths, Keyword.get(opts, :test_support_projects, []))
    runtime_erlc_paths = Enum.filter(test_erlc_paths, &(&1 == "src"))

    test_elixirc_paths =
      if has_path?(paths, "test/support"), do: ["lib", "test/support"], else: ["lib"]

    deps =
      render_deps(
        Keyword.get(opts, :runtime_external_deps, plan.external_deps),
        Keyword.get(opts, :test_external_deps, []),
        Keyword.get(opts, :forced_test_external_deps, [])
      )

    files = package_files(plan, paths) |> Enum.map_join(",\n        ", &inspect/1)
    docs = Projector.render_docs_options(plan)

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

      def elixirc_paths(:test), do: #{render_paths(test_elixirc_paths, opts)}
      def elixirc_paths(_env), do: #{render_paths(["lib"], opts)}
      def erlc_paths(:test), do: #{render_paths(test_erlc_paths, opts)}
      def erlc_paths(_env), do: #{render_paths(runtime_erlc_paths, opts)}

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

  # Mix compiler roots inside the project must remain relative.
  defp render_paths(paths, _opts), do: inspect(paths)

  defp generated_application(%Plan{} = plan, opts) do
    children =
      plan.selected_projects
      |> Enum.map(fn project -> {project.id, project.application.mod} end)
      |> Enum.reject(fn {_id, mod} -> is_nil(mod) end)
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
      |> Enum.map_join(",\n      ", fn {project_id, {child_module, args}} ->
        """
        %{
          id: #{inspect({project_id, child_module})},
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

  defp render_deps(runtime_external_deps, test_external_deps, forced_test_external_deps) do
    runtime_apps = MapSet.new(Enum.map(runtime_external_deps, & &1.app))

    runtime_deps =
      runtime_external_deps
      |> Enum.map(&normalize_dep_tuple(&1.original))

    forced_test_only_deps =
      forced_test_external_deps
      |> Enum.reject(&MapSet.member?(runtime_apps, &1.app))
      |> Enum.map(&force_test_only_dep(&1.original))

    test_only_deps =
      test_external_deps
      |> Enum.reject(&MapSet.member?(runtime_apps, &1.app))
      |> Enum.map(&force_test_only_dep(&1.original))

    deps = runtime_deps ++ forced_test_only_deps ++ test_only_deps

    deps =
      if Enum.any?(deps, &(elem(&1, 0) == :ex_doc)) do
        deps
      else
        deps ++ [{:ex_doc, "~> 0.40", only: :dev, runtime: false}]
      end

    deps
    |> dedupe_deps_by_app()
    |> Enum.map_join(",\n      ", &inspect/1)
  end

  defp dedupe_deps_by_app(deps) do
    {deps, _seen} =
      Enum.reduce(deps, {[], MapSet.new()}, fn dep, {acc, seen} ->
        app = dep_app(dep)

        if MapSet.member?(seen, app) do
          {acc, seen}
        else
          {[dep | acc], MapSet.put(seen, app)}
        end
      end)

    Enum.reverse(deps)
  end

  defp dep_app({app, _requirement}) when is_atom(app), do: app
  defp dep_app({app, _requirement, _opts}) when is_atom(app), do: app

  defp normalize_dep_tuple({app, requirement}) when is_binary(requirement), do: {app, requirement}

  defp normalize_dep_tuple({app, requirement, opts}) do
    {app, requirement, normalize_dep_opts(opts)}
  end

  defp normalize_dep_tuple({app, opts}) do
    {app, normalize_dep_opts(opts)}
  end

  defp force_test_only_dep({app, requirement}) when is_binary(requirement) do
    {app, requirement, [only: :test]}
  end

  defp force_test_only_dep({app, requirement, opts}) do
    {app, requirement, Keyword.put_new(normalize_dep_opts(opts), :only, :test)}
  end

  defp force_test_only_dep({app, opts}) do
    {app, Keyword.put_new(normalize_dep_opts(opts), :only, :test)}
  end

  defp normalize_dep_opts(opts) do
    if Keyword.has_key?(opts, :git) or Keyword.has_key?(opts, :github) do
      opts
    else
      Keyword.delete(opts, :override)
    end
  end

  defp build_erlc_paths(paths, test_support_projects) do
    runtime_paths = if has_path?(paths, "src"), do: ["src"], else: []

    test_paths =
      test_support_projects
      |> Enum.map(fn project ->
        Path.join(["test", "support", "weld_projects", project_slug(project.id), "src"])
      end)
      |> Enum.filter(&has_path?(paths, &1))

    runtime_paths ++ test_paths
  end

  defp fallback_links(links, _repo_root) when map_size(links) > 0, do: links

  defp fallback_links(_links, repo_root) do
    case Git.remote_url(repo_root) do
      nil -> %{"Source" => "https://github.com/nshkrdotcom/weld"}
      remote -> %{"Source" => remote}
    end
  end

  defp package_dir_files(paths, include_tests?) do
    candidates =
      ["README.md", "LICENSE", "lib", "config", "priv", "src", "c_src", "include"]
      |> maybe_add_tests(include_tests?)
      |> Kernel.++(root_docs_dirs(paths))
      |> Kernel.++(root_tooling_files(paths))

    candidates
    |> Enum.filter(fn relative ->
      has_path?(paths, relative)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maybe_add_tests(candidates, true), do: candidates ++ ["test"]
  defp maybe_add_tests(candidates, false), do: candidates

  defp root_docs_dirs(paths) do
    ["guides", "docs", "examples"]
    |> Enum.filter(&has_path?(paths, &1))
  end

  defp root_tooling_files(paths) do
    Projector.root_tooling_candidates()
    |> Enum.filter(&(&1 in paths))
  end

  defp has_path?(paths, relative),
    do: Enum.any?(paths, &(&1 == relative or String.starts_with?(&1, relative <> "/")))

  defp collapse_descendant_paths(paths) do
    Enum.reject(paths, fn path ->
      Enum.any?(paths, fn candidate ->
        candidate != path and String.starts_with?(path, candidate <> "/")
      end)
    end)
  end

  defp project_slug(project_id), do: FilePlan.slug(project_id)
end
