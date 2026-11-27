defmodule Weld.Layout.Components do
  @moduledoc false

  alias Weld.Config.Generator
  alias Weld.{Error, SourceFormatter}
  alias Weld.Core.{Facts, Modules, Selection}
  alias Weld.Layout.{FilePlan, Render, Support}
  alias Weld.Plan.Inventory
  alias Weld.Layout.Live
  alias Weld.Core.Inputs

  # The component layout produces the same operations as flat layout before
  # the materializer creates the output. Generation is never rerun in the stage.
  def plan!(%{} = plan) do
    Support.validate_inputs!(plan)
    validate_component_test_paths!(plan)
    validate_include_paths!(Selection.projects_for_view(plan, :test), plan.facts)

    compiler_roots =
      Enum.flat_map(plan.selected_projects, fn project ->
        Enum.map(project.elixirc_paths, &Path.expand(&1, project.abs_path))
      end)

    compiler_roots |> Enum.flat_map(&Facts.list_files(plan.facts, &1))
    |> Enum.filter(&(Path.extname(&1) == ".ex"))
    |> Enum.map(&{&1, Facts.read!(plan.facts, &1)})
    |> Modules.validate_module_sources!()
    root = plan.manifest.repo_root
    repos = Support.detect_repo_infos(plan.selected_projects)

    structural = [
      plan.manifest.manifest_path | Enum.map(plan.structural_inputs, &Path.join(root, &1))
    ]

    inputs = Enum.filter(structural, &Facts.regular?(plan.facts, &1))

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

    operations = source_operations!(plan, root, config.operations)

    opts = [
      bootstrapped_apps: config.bootstrapped_apps,
      bootstrapped_config_sources: config.bootstrapped_sources,
      generate_config?: true
    ]

    app = Render.application(plan, opts)

    targets =
      Enum.map(operations, & &1.target) ++
        ["mix.exs"] ++ if(app.module, do: [generated_application_relative_path(plan)], else: [])

    opts =
      Keyword.put(
        opts,
        :package_files,
        Inputs.publication_files(plan, targets, package_files(plan, opts))
      )

    generated_inputs = Enum.uniq(inputs ++ Enum.flat_map(config.operations, & &1.sources))
    full = FilePlan.validate!(operations ++ generated_operations(plan, opts, generated_inputs))

    roots = Enum.filter(roots, fn entry ->
      children = Enum.filter(full, &Inventory.covered?(&1.target, entry.target))
      children != [] and Enum.all?(children, &(&1.operation == :link_or_copy and is_nil(&1.content)))
    end)
    links = Enum.map(roots, &{&1.target, &1.source}) ++
      (for op <- full, op.operation == :link_or_copy,
        not Enum.any?(roots, &Inventory.covered?(op.target, &1.target)),
        do: {op.target, Path.relative_to(hd(op.sources), root)})
    guard =
      Live.guard_source(plan,
        links: links,
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

  defp source_operations!(plan, root, config_operations) do
    source_ops =
      for entry <- plan.source_inventory do
        operation =
          if (entry.kind == :artifact_test and not plan.artifact.verify.component_tests) or
               entry.kind in [:native, :metadata] or entry.source in plan.structural_inputs or
               Enum.any?(Path.split(entry.target), &(&1 in ["c_src", "priv", "config"])),
            do: :copy,
            else: :link_or_copy

        FilePlan.copy(Path.join(root, entry.source), entry.target, entry.kind, operation)
      end

    operations = Inputs.add_operations!(plan, source_ops ++ config_operations)

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

    operations
  end

  defp generated_operations(plan, opts, inputs) do
    app = Render.application(plan, opts)

    app_ops =
      if app.module do
        content =
          Render.application_source(app, plan.artifact.package.otp_app)
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

  @spec package_files(map(), keyword()) :: [String.t()]
  def package_files(%{} = plan, opts \\ []) do
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
    |> Enum.filter(&Facts.dir?(project.facts, Path.expand(&1, project.abs_path)))
    |> then(fn roots ->
      Enum.reject(roots, fn path ->
        Enum.any?(roots, &(&1 != path and String.starts_with?(path, &1 <> "/")))
      end)
    end)
    |> Enum.sort()
  end

  defp projected_test_paths(%{artifact: %{verify: %{component_tests: false}}} = plan) do
    if plan.artifact.verify.artifact_tests == [], do: [], else: ["test"]
  end

  defp projected_test_paths(plan) do
    components =
      plan.selected_projects
      |> Enum.flat_map(fn project ->
        Inventory.normalize_paths(project, project.test_paths)
        |> Enum.filter(&Facts.dir?(project.facts, Path.expand(&1, project.abs_path)))
        |> Enum.map(&Path.join(["components", component_dir(project), &1]))
      end)

    artifacts =
      plan.artifact.verify.artifact_tests
      |> Enum.with_index(1)
      |> Enum.map(fn {_path, index} -> "test/artifact_#{index}" end)

    Enum.uniq(components ++ artifacts)
  end

  defp component_test_compile_paths(%{artifact: %{verify: %{component_tests: false}}}), do: []

  defp component_test_compile_paths(plan) do
    Selection.projects_for_view(plan, :test)
    |> Enum.flat_map(fn project ->
      paths =
        if Selection.selected?(plan, project.id),
          do: project.test_elixirc_paths,
          else: project.elixirc_paths

      project
      |> Inventory.normalize_paths(paths)
      |> Enum.filter(&Facts.dir?(project.facts, Path.expand(&1, project.abs_path)))
      |> Enum.map(&Path.join(["components", component_dir(project), &1]))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp component_test_erlc_paths(%{artifact: %{verify: %{component_tests: false}}}, runtime),
    do: runtime

  defp component_test_erlc_paths(plan, _runtime) do
    Selection.projects_for_view(plan, :test)
    |> Enum.flat_map(fn project ->
      paths =
        if Selection.selected?(plan, project.id), do: project.test_erlc_paths, else: project.erlc_paths

      project
      |> Inventory.normalize_paths(paths)
      |> Enum.map(&Path.join(["components", component_dir(project), &1]))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp package_external_deps(%{artifact: %{verify: %{component_tests: false}}} = plan),
    do: plan.external_deps

  defp package_external_deps(plan) do
    runtime_apps = Enum.map(plan.external_deps, & &1.app)

    test_deps =
      plan
      |> Selection.external_deps_for_view(:test)
      |> Enum.reject(&(&1.app in runtime_apps))
      |> Enum.map(fn dep ->
        opts = Keyword.put_new(dep.opts, :only, :test)
        original = if dep.requirement, do: {dep.app, dep.requirement, opts}, else: {dep.app, opts}
        %{dep | opts: opts, original: original}
      end)

    plan.external_deps ++ test_deps
  end

  defp validate_component_test_paths!(%{artifact: %{verify: %{component_tests: false}}}),
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

  defp mixfile_contents(plan, opts) do
    app = Render.application(plan, opts)
    elixirc = component_paths(plan.selected_projects, & &1.elixirc_paths, plan, opts)
    erlc = component_paths(plan.selected_projects, & &1.erlc_paths)
    include = component_include_paths(plan.selected_projects)
    spec = %{
      elixirc_paths: elixirc,
      test_elixirc_paths: if(plan.artifact.verify.component_tests,
        do: Enum.uniq(generated_root_paths(plan, opts) ++ component_test_compile_paths(plan)),
        else: elixirc),
      erlc_paths: erlc, test_erlc_paths: component_test_erlc_paths(plan, erlc),
      include_paths: include,
      test_include_paths: if(plan.artifact.verify.component_tests,
        do: component_include_paths(Selection.projects_for_view(plan, :test)), else: include),
      test_paths: projected_test_paths(plan),
      deps: Render.dependencies(package_external_deps(plan), [], plan.artifact.package.development_dependencies)
    }
    Render.mix(plan, app, spec, opts)
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
        Facts.dir?(project.facts, Path.expand(relative, project.abs_path)),
        do: Path.join(["components", component_dir(project), relative])
  end

  defp validate_include_paths!(projects, facts) do
    headers =
      for project <- projects,
          root = Path.expand(project.erlc_include_path, project.abs_path),
          Facts.dir?(project.facts, root),
          path <- Facts.list_files(project.facts, root),
          do: {Path.relative_to(path, root), path}

    for {relative, files} <- Enum.group_by(headers, &elem(&1, 0), &elem(&1, 1)) do
      if length(Enum.uniq_by(files, &Facts.digest!(facts, &1))) > 1,
        do: raise(Error, "conflicting Erlang include #{relative} across selected projects")
    end
  end

  defp generated_root_paths(nil, _opts), do: []

  defp generated_root_paths(plan, opts) do
    []
    |> maybe_add_generated_root_path(
      case Render.application(plan, opts) do
        %{module: nil} -> nil
        _application -> "lib"
      end
    )
    |> maybe_add_generated_root_path(
      if(Keyword.get(opts, :generate_config?, false), do: "config")
    )
  end

  defp generated_application_relative_path(plan),
    do: Path.join(["lib", to_string(plan.artifact.package.otp_app), "application.ex"])

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
      |> Enum.filter(&Facts.dir?(&1.facts, Path.join(&1.abs_path, "priv/repo")))
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
