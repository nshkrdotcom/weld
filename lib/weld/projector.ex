defmodule Weld.Projector do
  @moduledoc """
  Generates the welded Mix project and its initial lockfile.
  """

  @root_tooling_files [".formatter.exs", ".credo.exs", ".dialyzer_ignore.exs"]

  alias Weld.Config.Generator
  alias Weld.Error
  alias Weld.Git
  alias Weld.Hash
  alias Weld.Lockfile
  alias Weld.Plan
  alias Weld.Projector.Monolith
  alias Weld.SourceFormatter

  @spec project!(Plan.t()) :: map()
  def project!(%Plan{} = plan) do
    plan = Plan.ensure_valid!(plan)
    build_path = build_path(plan)

    clear_stale_build_paths!(plan)
    File.rm_rf!(build_path)
    File.mkdir_p!(build_path)

    projection =
      plan
      |> project_by_mode!(build_path)
      |> Map.put(:build_path, build_path)
      |> Map.put(:git_revision, Git.revision(plan.manifest.repo_root))
      |> Map.put(:tree_digest, Hash.sha256_tree(build_path))

    lockfile = Lockfile.build(plan, projection, [])
    lockfile_path = Path.join(build_path, "projection.lock.json")
    File.write!(lockfile_path, Lockfile.encode!(lockfile))

    Map.put(projection, :lockfile_path, lockfile_path)
  end

  @spec build_path(Plan.t()) :: Path.t()
  def build_path(%Plan{} = plan) do
    dist_root = Path.expand(plan.artifact.output.dist_root, plan.manifest.repo_root)

    case plan.artifact.mode do
      :monolith -> Path.join([dist_root, "monolith", plan.artifact.package.name])
      _ -> Path.join([dist_root, "hex", plan.artifact.package.name])
    end
  end

  @spec package_files(Plan.t(), keyword()) :: [String.t()]
  def package_files(%Plan{} = plan, opts \\ []) do
    component_roots =
      plan.selected_projects
      |> Enum.map(&component_dir/1)
      |> Enum.map(&Path.join("components", &1))

    ["mix.exs", "projection.lock.json"]
    |> Kernel.++(generated_root_paths(plan, opts))
    |> Kernel.++(component_roots)
    |> Kernel.++(root_tooling_files(plan))
    |> Kernel.++(plan.artifact.output.docs)
    |> Kernel.++(plan.artifact.output.assets)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec root_tooling_candidates() :: [String.t()]
  def root_tooling_candidates, do: @root_tooling_files

  @spec root_tooling_files(Plan.t()) :: [String.t()]
  def root_tooling_files(%Plan{} = plan) do
    @root_tooling_files
    |> Enum.filter(&File.regular?(Path.join(plan.manifest.repo_root, &1)))
  end

  defp copy_project!(build_path, project) do
    base = Path.join([build_path, "components", component_dir(project)])

    project.copy_dirs
    |> Enum.flat_map(fn dir ->
      source = Path.join(project.abs_path, dir)
      target = Path.join(base, dir)

      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(source, target)

      target
      |> list_copied_paths()
    end)
  end

  defp copy_relative!(plan, build_path, relative_path) do
    source = Path.join(plan.manifest.repo_root, relative_path)
    target = Path.join(build_path, relative_path)

    cond do
      File.regular?(source) ->
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)
        [relative_path]

      File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))
        File.cp_r!(source, target)

        target
        |> list_copied_paths()
        |> Enum.map(&Path.relative_to(&1, build_path))

      true ->
        raise Error, "copy target not found: #{relative_path}"
    end
  end

  defp copy_artifact_tests!(plan, build_path, relative_path) do
    source = Path.join(plan.manifest.repo_root, relative_path)

    unless File.dir?(source) do
      raise Error, "artifact test path not found: #{relative_path}"
    end

    target = Path.join(build_path, "test")
    File.mkdir_p!(target)

    source
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn child ->
      child_source = Path.join(source, child)
      child_target = Path.join(target, child)

      if File.dir?(child_source) do
        File.cp_r!(child_source, child_target)
      else
        File.cp!(child_source, child_target)
      end

      child_target
      |> list_copied_paths()
      |> Enum.map(&Path.relative_to(&1, build_path))
    end)
  end

  defp project_by_mode!(%Plan{artifact: %{mode: :monolith}} = plan, build_path) do
    Monolith.project!(plan, build_path)
  end

  defp project_by_mode!(%Plan{} = plan, build_path) do
    repo_infos = detect_repo_infos(plan.selected_projects)

    config_merge =
      Generator.generate!(
        plan.selected_projects,
        build_path,
        repo_infos,
        package_repo_layout(plan.selected_projects),
        shared_test_configs: Enum.map(plan.selected_projects, & &1.id),
        root_config_overlays:
          List.wrap(root_ecto_repos_overlay(repo_infos, plan.artifact.package.otp_app))
      )

    copied_components = Enum.flat_map(plan.selected_projects, &copy_project!(build_path, &1))
    copied_docs = Enum.flat_map(plan.artifact.output.docs, &copy_relative!(plan, build_path, &1))

    copied_assets =
      Enum.flat_map(plan.artifact.output.assets, &copy_relative!(plan, build_path, &1))

    copied_tooling_files =
      Enum.flat_map(root_tooling_files(plan), &copy_relative!(plan, build_path, &1))

    copied_tests =
      Enum.flat_map(
        plan.artifact.verify.artifact_tests,
        &copy_artifact_tests!(plan, build_path, &1)
      )

    ensure_readme!(plan, build_path)

    generated_files =
      render_generated_files!(plan, build_path,
        bootstrapped_apps: config_merge.bootstrapped_apps,
        bootstrapped_config_sources: config_merge.bootstrapped_sources,
        generate_config?: true
      )

    render_mixfile!(plan, build_path,
      bootstrapped_apps: config_merge.bootstrapped_apps,
      bootstrapped_config_sources: config_merge.bootstrapped_sources,
      generate_config?: true
    )

    %{
      copied_files:
        (copied_components ++
           copied_docs ++
           copied_assets ++
           copied_tooling_files ++
           copied_tests ++
           config_merge.copied_files ++ generated_files)
        |> Enum.uniq()
        |> Enum.sort(),
      package_files:
        package_files(plan,
          bootstrapped_apps: config_merge.bootstrapped_apps,
          bootstrapped_config_sources: config_merge.bootstrapped_sources,
          generate_config?: true
        )
    }
  end

  defp render_mixfile!(plan, build_path, opts) do
    File.write!(
      Path.join(build_path, "mix.exs"),
      mixfile_contents(plan, opts) |> SourceFormatter.format!()
    )
  end

  defp render_generated_files!(plan, build_path, opts) do
    case generated_application(plan, opts) do
      %{module: nil} ->
        []

      application ->
        relative_path = generated_application_relative_path(plan)
        target = Path.join(build_path, relative_path)
        File.mkdir_p!(Path.dirname(target))

        File.write!(
          target,
          application_module_contents(application, plan.artifact.package.otp_app)
          |> SourceFormatter.format!()
        )

        [relative_path]
    end
  end

  defp ensure_readme!(plan, build_path) do
    readme = Path.join(build_path, "README.md")

    unless File.exists?(readme) do
      File.write!(readme, "# #{plan.artifact.package.name}\n")
    end
  end

  defp mixfile_contents(plan, opts) do
    package = plan.artifact.package
    module_name = "#{Macro.camelize(to_string(package.otp_app))}.MixProject"
    application = generated_application(plan, opts)
    elixirc_paths = component_paths(plan.selected_projects, & &1.elixirc_paths, plan, opts)
    erlc_paths = component_paths(plan.selected_projects, & &1.erlc_paths)
    deps = render_deps(plan.external_deps)
    files = package_files(plan, opts) |> Enum.map_join(",\n        ", &inspect/1)
    extras = plan.artifact.output.docs |> Enum.map_join(",\n        ", &inspect/1)
    links = package.links |> fallback_links(plan.manifest.repo_root) |> inspect(pretty: true)
    application_config = application_config_literal(application)

    """
    defmodule #{module_name} do
      use Mix.Project

      def project do
        [
          app: #{inspect(package.otp_app)},
          version: #{inspect(package.version)},
          build_path: "_build",
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
        base = #{inspect(elixirc_paths)}

        if File.dir?("test/support") do
          base ++ ["test/support"]
        else
          base
        end
      end

      def elixirc_paths(_env), do: #{inspect(elixirc_paths)}

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
         |> path_fun.()
         |> Enum.map(fn relative ->
           Path.join(["components", component_dir(project), relative])
         end)
       end)
       |> Enum.uniq()
       |> Enum.sort())
  end

  defp render_deps(external_deps) do
    external_deps
    |> Enum.map(fn dep -> dep.original end)
    |> Kernel.++([{:ex_doc, "~> 0.40", only: :dev, runtime: false}])
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
         _artifact_otp_app
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
            Path.expand(Path.join(["..", "..", relative_path]), __DIR__)
          end
        """
      end

    """
    defmodule #{inspect(module)} do
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

  def detect_repo_infos(projects) do
    projects
    |> Enum.flat_map(fn project ->
      lib_root = Path.join(project.abs_path, "lib")

      if File.dir?(lib_root) do
        lib_root
        |> Hash.list_files()
        |> Enum.filter(&(Path.extname(&1) == ".ex"))
        |> Enum.flat_map(&repo_info_from_file(&1, project))
      else
        []
      end
    end)
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

  defp clear_stale_build_paths!(%Plan{} = plan) do
    dist_root = Path.expand(plan.artifact.output.dist_root, plan.manifest.repo_root)

    stale_paths =
      case plan.artifact.mode do
        :monolith -> [Path.join([dist_root, "hex", plan.artifact.package.name])]
        _other -> [Path.join([dist_root, "monolith", plan.artifact.package.name])]
      end

    Enum.each(stale_paths, &File.rm_rf!/1)
  end

  defp repo_info_from_file(path, project) do
    contents = File.read!(path)

    if String.contains?(contents, "use Ecto.Repo") do
      module =
        case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)\s+do/, contents, capture: :all_but_first) do
          [module] -> Module.concat([module])
          _ -> raise Error, "unable to parse Ecto repo module from #{path}"
        end

      otp_app =
        case Regex.run(~r/otp_app:\s*:(\w+)/, contents, capture: :all_but_first) do
          [otp_app] -> String.to_atom(otp_app)
          _ -> raise Error, "unable to parse Ecto repo otp_app from #{path}"
        end

      [
        %{
          project_id: project.id,
          module: module,
          otp_app: otp_app
        }
      ]
    else
      []
    end
  end

  defp component_dir(%{id: "."}), do: "root"
  defp component_dir(%{id: id}), do: id

  defp list_copied_paths(path) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> Weld.Hash.list_files(path)
      true -> []
    end
  end
end
