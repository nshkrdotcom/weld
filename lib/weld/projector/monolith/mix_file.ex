defmodule Weld.Projector.Monolith.MixFile do
  @moduledoc false

  alias Weld.Git
  alias Weld.Plan

  @spec render!(Plan.t(), Path.t(), keyword()) :: [String.t()]
  def render!(%Plan{} = plan, build_path, opts) do
    application = generated_application(plan)
    mixfile_path = Path.join(build_path, "mix.exs")
    File.write!(mixfile_path, mixfile_contents(plan, build_path, application, opts))

    generated = ["mix.exs"]
    write_application_module!(generated, application, plan, build_path)
  end

  @spec package_files(Path.t(), keyword()) :: [String.t()]
  def package_files(build_path, opts \\ []) do
    package_dir_files(build_path, Keyword.get(opts, :include_tests?, false))
    |> Kernel.++(["mix.exs", "projection.lock.json"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp write_application_module!(generated, %{module: nil}, _plan, _build_path), do: generated

  defp write_application_module!(generated, application, plan, build_path) do
    relative = Path.join(["lib", to_string(plan.artifact.package.otp_app), "application.ex"])
    target = Path.join(build_path, relative)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, application_module_contents(application, plan.artifact.package.otp_app))
    [relative | generated]
  end

  defp mixfile_contents(plan, build_path, application, opts) do
    package = plan.artifact.package
    module_name = "#{Macro.camelize(to_string(package.otp_app))}.MixProject"
    erlc_paths = build_erlc_paths(build_path, Keyword.get(opts, :test_support_projects, []))

    deps =
      render_deps(
        Keyword.get(opts, :runtime_external_deps, plan.external_deps),
        Keyword.get(opts, :test_external_deps, []),
        Keyword.get(opts, :forced_test_external_deps, [])
      )

    files = package_files(build_path) |> Enum.map_join(",\n        ", &inspect/1)
    extras = plan.artifact.output.docs |> Enum.uniq() |> Enum.sort() |> Enum.map_join(",\n        ", &inspect/1)
    links = package.links |> fallback_links(plan.manifest.repo_root) |> inspect(pretty: true)
    application_config = application_config_literal(application)

    """
    defmodule #{module_name} do
      use Mix.Project

      def project do
        [
          app: #{inspect(package.otp_app)},
          version: #{inspect(package.version)},
          elixir: #{inspect(package.elixir)},
          start_permanent: Mix.env() == :prod,
          elixirc_paths: elixirc_paths(Mix.env()),
          erlc_paths: #{inspect(erlc_paths)},
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
        if File.dir?("test/support") do
          ["lib", "test/support"]
        else
          ["lib"]
        end
      end

      def elixirc_paths(_env), do: ["lib"]

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
        [
          main: #{inspect(package.docs_main)},
          extras: [
            #{extras}
          ]
        ]
      end
    end
    """
  end

  defp generated_application(%Plan{} = plan) do
    children =
      plan.selected_projects
      |> Enum.map(fn project -> {project.id, project.application.mod} end)
      |> Enum.reject(fn {_id, mod} -> is_nil(mod) end)
      |> Enum.uniq()

    %{
      module:
        if(children == [],
          do: nil,
          else:
            Module.concat([
              Macro.camelize(to_string(plan.artifact.package.otp_app)),
              "Application"
            ])
        ),
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

  defp application_module_contents(%{module: module, children: children}, _artifact_otp_app) do
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

    """
    defmodule #{inspect(module)} do
      use Application

      def start(_type, _args) do
        children = [
          #{rendered_children}
        ]

        Supervisor.start_link(children,
          strategy: :one_for_one,
          name: __MODULE__.Supervisor
        )
      end
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

  defp normalize_dep_opts(opts), do: opts

  defp build_erlc_paths(build_path, test_support_projects) do
    runtime_paths = if File.dir?(Path.join(build_path, "src")), do: ["src"], else: []

    test_paths =
      test_support_projects
      |> Enum.map(fn project ->
        Path.join(["test", "support", "weld_projects", project_slug(project.id), "src"])
      end)
      |> Enum.filter(&(File.dir?(Path.join(build_path, &1))))

    runtime_paths ++ test_paths
  end

  defp fallback_links(links, _repo_root) when map_size(links) > 0, do: links

  defp fallback_links(_links, repo_root) do
    case Git.remote_url(repo_root) do
      nil -> %{"Source" => "https://github.com/nshkrdotcom/weld"}
      remote -> %{"Source" => remote}
    end
  end

  defp package_dir_files(build_path, include_tests?) do
    candidates =
      ["README.md", "LICENSE", "lib", "config", "priv", "src", "c_src", "include"]
      |> maybe_add_tests(include_tests?)
      |> Kernel.++(root_docs_dirs(build_path))

    candidates
    |> Enum.filter(fn relative ->
      File.exists?(Path.join(build_path, relative))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp maybe_add_tests(candidates, true), do: candidates ++ ["test"]
  defp maybe_add_tests(candidates, false), do: candidates

  defp root_docs_dirs(build_path) do
    ["guides", "docs", "examples"]
    |> Enum.filter(&(File.exists?(Path.join(build_path, &1))))
  end

  defp project_slug(project_id) do
    project_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end
end
