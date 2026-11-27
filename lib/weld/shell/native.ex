defmodule Weld.Shell.Native do
  @moduledoc false
  alias Weld.Core.Facts
  alias Weld.Error
  alias Weld.Shell.Runner
  alias Weld.Workspace.Probe
  # Load the staged Mix file in a fresh VM. A process already running inside
  # the source project may have loaded its helpers or its project module.
  def validate!(plan, stage, kind \\ :full) do
    if kind == :live do
      # The live guard resolves from the final view location. Probe the original
      # native definition at staging, while all source links and copied inputs
      # are present, then restore the emitted guard even if validation fails.
      path = Path.join(stage, "mix.exs")
      generated = File.read!(path)
      original = Facts.read!(plan.facts, Path.join(plan.source_root, "mix.exs"))
      File.write!(path, original)

      try do
        probe!(plan, stage)
      after
        File.write!(path, generated)
      end
    else
      probe!(plan, stage)
    end
  end

  defp probe!(plan, stage) do
    compiler_root = stage
    source_root = plan.source_root
    projects = plan.layout.native_projects

    for project <- projects, env <- Probe.environments() do
      relative = Path.relative_to(project.abs_path, source_root)
      expected = {project.app, project.version, project.package_name}
      dependencies = Enum.map(Map.fetch!(project.deps_by_env, env), & &1.original)
      elixirc = if env == :test, do: project.test_elixirc_paths, else: project.elixirc_paths
      erlc = if env == :test, do: project.test_erlc_paths, else: project.erlc_paths

      compiler_metadata =
        Keyword.take(Map.fetch!(project.config_by_env, env), [
          :compilers,
          :elixirc_options,
          :erlc_options,
          :erlc_include_path
        ])

      script = """
      Mix.start()
      Mix.env(#{inspect(env)})
      root = #{inspect(compiler_root)}
      generated_root = #{inspect(stage)}
      expected = #{inspect(expected)}
        Mix.Project.in_project(#{inspect(project.app)}, #{inspect(relative)}, [], fn project ->
          config = Mix.Project.config()
          package = config[:package] || []
          identity = {config[:app], config[:version], to_string(package[:name] || config[:app])}
          unless identity == expected,
            do: raise("staged application identity differs from the source")

          normalize_deps = fn deps ->
            Enum.map(deps, fn
              {app, requirement} when is_binary(requirement) -> {app, requirement, []}
              {app, opts} when is_list(opts) -> {app, nil, Enum.sort(opts)}
              {app, requirement, opts} -> {app, requirement, Enum.sort(opts)}
            end) |> Enum.sort()
          end
          unless normalize_deps.(config[:deps] || []) == normalize_deps.(#{inspect(dependencies, limit: :infinity)}),
            do: raise("staged dependencies differ from source metadata")
          unless Enum.sort(List.wrap(config[:elixirc_paths] || ["lib"])) == #{inspect(Enum.sort(elixirc))} and
            Enum.sort(List.wrap(config[:erlc_paths] || ["src"])) == #{inspect(Enum.sort(erlc))},
            do: raise("staged compiler roots differ from source metadata")
          unless Enum.sort(package) == #{inspect(Enum.sort(project.package_metadata), limit: :infinity)},
            do: raise("staged package metadata differs from source")
          unless Enum.sort(Keyword.take(config, [:compilers, :elixirc_options, :erlc_options, :erlc_include_path])) == #{inspect(Enum.sort(compiler_metadata), limit: :infinity)},
            do: raise("staged compiler metadata differs from source")
          application = if function_exported?(project, :application, 0), do: project.application(), else: []
          actual_application = %{
              mod: application[:mod],
              extra_applications: Enum.sort(application[:extra_applications] || []),
              included_applications: Enum.sort(application[:included_applications] || []),
              registered: Enum.sort(application[:registered] || [])}
          unless actual_application == #{inspect(project.application, limit: :infinity)},
            do: raise("staged application callback differs from source metadata")
          docs = config[:docs] || []
          mutable_paths = [
            config[:build_path] || "_build",
            config[:deps_path] || "deps",
            config[:lockfile] || "mix.lock",
            if(is_list(docs), do: docs[:output] || "doc", else: "doc")
          ]

          for path <- mutable_paths do
            absolute = Path.expand(path)
            unless String.starts_with?(absolute, generated_root <> "/"),
              do: raise("mutable path escapes staged source project: " <> path)

            absolute
            |> Path.relative_to(generated_root)
            |> Path.split()
            |> Enum.reduce(generated_root, fn part, parent ->
              child = Path.join(parent, part)
              if match?({:ok, %{type: :symlink}}, File.lstat(child)),
                do: raise("mutable path overlaps linked source: " <> path)
              child
            end)
          end

          paths =
            List.wrap(config[:elixirc_paths] || ["lib"]) ++
              List.wrap(config[:erlc_paths] || ["src"]) ++
              List.wrap(config[:test_paths] || ["test"]) ++
              List.wrap(config[:erlc_include_path])

          for path <- paths do
            absolute = Path.expand(path)
            unless absolute == root or String.starts_with?(absolute, root <> "/"),
              do: raise("compiler input escapes its declared project: " <> absolute)
          end
        end)
      """

      case Runner.run!("elixir", ["-e", script],
             cd: stage,
             env: [{"MIX_ENV", Atom.to_string(env)}],
             seconds: 30
           ) do
        {_output, 0} -> :ok
        {output, _} -> raise Error, "staged source project failed validation:\n#{output}"
      end
    end

    :ok
  end
end
