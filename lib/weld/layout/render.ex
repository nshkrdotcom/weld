defmodule Weld.Layout.Render do
  @moduledoc "One renderer for generated Mix, OTP bootstrap and docs metadata."
  alias Weld.Error
  alias Weld.Layout.{Live, Support}

  def mix(plan, application, spec, opts) do
    package = plan.artifact.package

    """
    defmodule #{Macro.camelize(to_string(package.otp_app))}.MixProject do
      use Mix.Project
      def project do
        #{opts[:live_guard] || ""}
        [app: #{inspect(package.otp_app)}, version: #{inspect(package.version)},
         elixir: #{inspect(package.elixir)}, start_permanent: Mix.env() == :prod,
         elixirc_paths: elixirc_paths(Mix.env()), erlc_paths: erlc_paths(Mix.env()),
         erlc_options: erlc_options(Mix.env()), test_paths: #{inspect(spec.test_paths)},
         test_ignore_filters: #{inspect(Map.get(spec, :test_ignore_filters, []))},
         #{if(opts[:live?], do: "aliases: #{Live.aliases_source()},", else: "build_path: \"_build\",")}
         deps: deps(), description: #{inspect(package.description)}, package: package(), docs: docs()]
      end
      def application, do: #{application_config(application)}
      def elixirc_paths(:test), do: #{inspect(spec.test_elixirc_paths)}
      def elixirc_paths(_), do: #{inspect(spec.elixirc_paths)}
      def erlc_paths(:test), do: #{inspect(spec.test_erlc_paths)}
      def erlc_paths(_), do: #{inspect(spec.erlc_paths)}
      defp erlc_options(env) do
        paths = if env == :test, do: #{inspect(spec.test_include_paths)}, else: #{inspect(spec.include_paths)}
        Enum.map(paths, &{:i, &1 |> Path.expand(__DIR__) |> String.to_charlist()})
      end
      defp deps, do: #{inspect(spec.deps, pretty: true, limit: :infinity)}
      defp package do
        [name: #{inspect(package.name)}, licenses: #{inspect(package.licenses)},
         links: #{inspect(package.links)},
         files: #{inspect(opts[:package_files], pretty: true, limit: :infinity)}]
      end
      defp docs, do: #{Support.render_docs_options(plan)}
    end
    """
  end

  def dependencies(runtime, test, development) do
    apps = MapSet.new(Enum.map(runtime, & &1.app))

    tests =
      for dep <- test, not MapSet.member?(apps, dep.app) do
        opts = Keyword.put_new(dep.opts, :only, :test)
        if dep.requirement, do: {dep.app, dep.requirement, opts}, else: {dep.app, opts}
      end

    deps = Enum.map(runtime, & &1.original) ++ tests ++ development

    deps =
      if Enum.any?(deps, &(elem(&1, 0) == :ex_doc)),
        do: deps,
        else: deps ++ [{:ex_doc, "~> 0.40", only: :dev, runtime: false}]

    deps
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {app, declarations} ->
      unique = Enum.uniq(declarations)
      if length(unique) != 1, do: raise(Error, "conflicting generated dependency: #{app}")
      hd(unique)
    end)
  end

  def application(%{} = plan, opts) do
    selected_apps = Enum.map(plan.selected_projects, & &1.app)

    children =
      plan.selected_projects
      |> Enum.map(& &1.application.mod)
      |> Enum.reject(&is_nil/1)

    duplicate_children =
      children
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.filter(fn {_module, count} -> count > 1 end)

    if duplicate_children != [],
      do: raise(Error, "conflicting application child modules: #{inspect(duplicate_children)}")

    registered = Enum.flat_map(plan.selected_projects, & &1.application.registered)

    duplicates =
      registered |> Enum.frequencies() |> Enum.filter(fn {_name, count} -> count > 1 end)

    if duplicates != [],
      do: raise(Error, "conflicting registered application names: #{inspect(duplicates)}")

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
        |> Enum.reject(&(&1 in selected_apps))
        |> Enum.uniq()
        |> Enum.sort(),
      included_applications:
        plan.selected_projects
        |> Enum.flat_map(& &1.application.included_applications)
        |> Enum.reject(&(&1 in selected_apps))
        |> Enum.uniq()
        |> Enum.sort(),
      registered: Enum.sort(registered)
    }
  end

  def application_config(application) do
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

  def application_source(
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
end
