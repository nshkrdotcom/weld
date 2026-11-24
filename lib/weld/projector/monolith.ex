defmodule Weld.Projector.Monolith do
  @moduledoc false

  alias Weld.Config.Generator
  alias Weld.Error
  alias Weld.Hash
  alias Weld.Manifest
  alias Weld.Output
  alias Weld.Plan
  alias Weld.Projector
  alias Weld.Projector.Live
  alias Weld.Projector.Monolith.FilePlan
  alias Weld.Projector.Monolith.Migrations
  alias Weld.Projector.Monolith.MixFile
  alias Weld.Projector.Monolith.TestHelper
  alias Weld.Projector.SourceProject

  @source_dirs ~w(lib src c_src include)

  # All layout decisions are made before the output directory exists. The
  # materializer consumes this value, including the already-rendered Mix files.
  def plan!(%Plan{} = plan) do
    validate_planning_inputs!(plan)
    support = resolve_test_support_projects!(plan)
    projects = plan.selected_projects ++ support
    ensure_unique_slugs!(projects)
    root = plan.manifest.repo_root
    roots = live_roots(plan, projects)

    metadata = [
      plan.manifest.manifest_path | Enum.map(plan.structural_inputs, &Path.join(root, &1))
    ]

    # Include missing roots and metadata: additions must invalidate the plan too.
    for path <- roots ++ metadata do
      Output.source!(root, Path.relative_to(path, root))
    end

    snapshot = snapshot(roots, metadata)

    {operations, remaps, collisions, mappings} = merge_source_operations(plan, root)

    tests = Enum.flat_map(plan.selected_projects, &test_operations/1)
    support_ops = Enum.flat_map(support, &support_operations/1)
    migrations = Migrations.plan!(plan.selected_projects)
    private = Enum.flat_map(plan.selected_projects, &private_operations/1)
    helpers = TestHelper.plan!(plan.selected_projects)
    repos = Projector.detect_repo_infos(projects)

    config =
      Generator.plan!(projects, repos, migrations.layout,
        shared_test_configs: plan.artifact.monolith_opts[:shared_test_configs] || [],
        planning_inputs:
          Enum.map(repos, & &1.source) ++ Enum.flat_map(migrations.operations, & &1.sources),
        root_config_overlays:
          List.wrap(root_ecto_repos_overlay(repos, plan.artifact.package.otp_app))
      )

    operations =
      operations ++
        tests ++
        support_ops ++
        migrations.operations ++
        private ++
        helpers.operations ++ config.operations

    operations = ensure_readme(operations, plan.artifact.package.name)

    # A migration or configuration input affects generated configuration and the
    # Mix application even when it is not itself copied to those destinations.
    structural = Enum.filter(metadata, &File.regular?/1)

    generated_inputs =
      Enum.uniq(
        structural ++ Enum.flat_map(config.operations ++ migrations.operations, & &1.sources)
      )

    opts = [
      bootstrapped_apps: config.bootstrapped_apps,
      bootstrapped_config_sources: config.bootstrapped_sources,
      runtime_external_deps: plan.external_deps,
      test_external_deps: Plan.external_deps_for_view(plan, :test),
      forced_test_external_deps:
        forced_external_deps(plan.manifest, plan.artifact.monolith_opts[:extra_test_deps] || []),
      test_support_projects: support,
      inputs: generated_inputs
    ]

    mix = MixFile.plan!(plan, operations, opts)
    full = FilePlan.validate!(operations ++ mix.operations)
    # Guard all topology and transformed/deduplicated inputs; do not hash ordinary
    # single-source links after activation, so incremental edits still work.
    transformed =
      full |> Enum.reject(&(&1.operation == :link_or_copy)) |> Enum.flat_map(& &1.sources)

    guard =
      Live.guard_source(plan,
        directories: Enum.filter(roots, &File.dir?/1),
        topology: roots,
        digests: Enum.uniq(transformed ++ collisions)
      )

    live_mix = MixFile.plan!(plan, operations, opts ++ [live?: true, live_guard: guard])
    live = FilePlan.validate!(operations ++ live_mix.operations)

    ensure_equal_layouts!(full, live)

    validate_modules!(full)
    assert_snapshot!(snapshot, roots, metadata)

    %{
      full: full,
      live: live,
      roots: roots,
      metadata: metadata,
      snapshot: snapshot,
      package_files: mix.package_files,
      file_remaps: remaps,
      source_mappings: mappings,
      migration_layout: migrations.layout,
      migration_remaps: migrations.remaps,
      helper_transformations: helpers.transformations,
      config_warnings: config.warnings,
      repo_infos: repos,
      test_support_projects: Enum.map(support, & &1.id)
    }
  end

  defp validate_planning_inputs!(plan) do
    Projector.validate_inputs!(plan)
    validate_source_assumptions!(plan)

    if plan.artifact.verify.smoke.enabled or plan.artifact.verify.artifact_tests != [] do
      raise Error, "monolith verification does not support smoke or artifact_tests"
    end
  end

  defp ensure_unique_slugs!(projects) do
    slugs = Enum.map(projects, &project_slug(&1.id))
    unless Enum.uniq(slugs) == slugs, do: raise(Error, "monolith project slug collision")
  end

  defp merge_source_operations(plan, root) do
    initial =
      (Enum.map(plan.artifact.output.docs, &{&1, :docs}) ++
         Enum.map(plan.artifact.output.assets, &{&1, :runtime}) ++
         Enum.map(Projector.root_tooling_files(plan), &{&1, :metadata}))
      |> Enum.flat_map(fn {path, kind} -> tree_operations(Path.join(root, path), path, kind) end)

    Enum.reduce(plan.selected_projects, {initial, [], [], []}, &merge_project_sources/2)
  end

  defp merge_project_sources(project, state) do
    slug = project_slug(project.id)
    Enum.reduce(@source_dirs, state, &merge_source_directory(project, slug, &1, &2))
  end

  defp merge_source_directory(project, slug, dir, state) do
    source_root = Path.join(project.abs_path, dir)

    tree_operations(source_root, dir, source_kind(dir))
    |> Enum.reduce(state, &merge_source_operation(&1, &2, slug))
  end

  defp merge_source_operation(op, {acc, remaps, collisions, mappings}, slug) do
    source = hd(op.sources)
    {acc, target, participants} = FilePlan.merge!(acc, source, op.target, slug, op.kind)

    remaps =
      if target == op.target,
        do: remaps,
        else:
          remaps ++
            [
              %{source: source, original_relative: op.target, remapped_relative: target}
            ]

    {acc, remaps, collisions ++ participants, mappings ++ [%{source: source, target: target}]}
  end

  defp ensure_readme(operations, name) do
    if Enum.any?(operations, &(&1.target == "README.md")),
      do: operations,
      else: operations ++ [FilePlan.generated("README.md", "# #{name}\n", :docs)]
  end

  defp ensure_equal_layouts!(full, live) do
    unless Enum.map(full, & &1.target) == Enum.map(live, & &1.target),
      do: raise(Error, "live and full monolith layouts diverge")
  end

  @spec project!(Plan.t(), Path.t(), keyword()) :: map()
  def project!(%Plan{monolith_plan: layout}, build_path, opts \\ []) do
    kind = Keyword.get(opts, :kind, :full)
    assert_snapshot!(layout.snapshot, layout.roots, layout.metadata)
    operations = Map.fetch!(layout, kind)
    files = FilePlan.materialize!(operations, build_path, kind)
    assert_snapshot!(layout.snapshot, layout.roots, layout.metadata)
    {_entries, fingerprints} = layout.snapshot
    FilePlan.validate_materialized!(operations, build_path, kind, Map.new(fingerprints))

    layout
    |> Map.take([
      :package_files,
      :file_remaps,
      :source_mappings,
      :migration_layout,
      :migration_remaps,
      :helper_transformations,
      :config_warnings,
      :repo_infos,
      :test_support_projects
    ])
    |> Map.merge(%{
      mode: :monolith,
      copied_files: files,
      linked_files:
        if(kind == :live,
          do: for(op <- operations, op.operation == :link_or_copy, do: op.target),
          else: []
        )
    })
  end

  defp snapshot(roots, metadata) do
    entries = roots |> Enum.flat_map(&FilePlan.topology/1) |> Enum.uniq() |> Enum.sort()
    files = for {path, :regular} <- entries, do: path

    fingerprints =
      (files ++ metadata)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{&1, FilePlan.fingerprint(&1)})

    {entries, fingerprints}
  end

  defp assert_snapshot!(expected, roots, metadata) do
    unless snapshot(roots, metadata) == expected,
      do: raise(Error, "monolith inputs changed after planning; rebuild the artifact plan")
  end

  defp validate_modules!(operations) do
    operations
    |> Enum.filter(&(String.starts_with?(&1.target, "lib/") and Path.extname(&1.target) == ".ex"))
    |> Enum.map(fn op -> {op.target, op.content || File.read!(hd(op.sources))} end)
    |> SourceProject.validate_module_sources!()
  end

  defp source_kind(dir) when dir in ["lib", "src"], do: :compiled
  defp source_kind(_dir), do: :runtime

  defp tree_operations(source, target, kind) do
    case File.lstat(source) do
      {:ok, %{type: :directory}} ->
        for {path, :regular} <- FilePlan.topology(source),
            do: FilePlan.copy(path, Path.join(target, Path.relative_to(path, source)), kind)

      {:ok, %{type: :regular}} ->
        [FilePlan.copy(source, target, kind)]

      {:error, :enoent} ->
        []

      _ ->
        raise Error, "invalid monolith source: #{source}"
    end
  end

  defp resolve_test_support_projects!(plan) do
    discovered =
      plan
      |> Plan.projects_for_view(:test)
      |> Enum.reject(&Plan.selected?(plan, &1.id))
      |> Enum.sort_by(& &1.id)

    declared =
      plan.artifact.monolith_opts
      |> Keyword.get(:test_support_projects, [])
      |> Enum.sort()

    case declared do
      [] ->
        discovered

      _declared ->
        discovered_ids = Enum.map(discovered, & &1.id)
        missing = discovered_ids -- declared
        unused = declared -- discovered_ids

        if missing != [] or unused != [] do
          raise Error,
                "monolith_opts[:test_support_projects] does not match discovered non-selected test support projects:\n" <>
                  "discovered: #{Enum.join(discovered_ids, ", ")}\n" <>
                  "declared: #{Enum.join(declared, ", ")}\n" <>
                  "missing declarations: #{Enum.join(missing, ", ")}\n" <>
                  "unused declarations: #{Enum.join(unused, ", ")}"
        end

        discovered
    end
  end

  defp test_operations(project) do
    slug = project_slug(project.id)

    (project.test_paths ++ Enum.filter(project.test_elixirc_paths, &(&1 == "test/support")))
    |> Enum.uniq()
    |> Enum.map(&project_test_path!(project, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&Hash.list_files/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&(Path.basename(&1) == "test_helper.exs"))
    |> Enum.map(fn source ->
      target = projected_test_target(slug, project_test_relative(project, source))
      FilePlan.copy(source, target, :test)
    end)
  end

  defp project_test_path!(project, test_path) do
    expanded = Path.expand(test_path, project.abs_path)
    project_root = Path.expand(project.abs_path)

    if expanded == project_root or String.starts_with?(expanded, project_root <> "/") do
      expanded
    else
      raise Error,
            "project #{project.id} test path escapes its project root: #{inspect(test_path)}"
    end
  end

  defp project_test_relative(project, source) do
    test_root = Path.join(project.abs_path, "test")
    relative_to_test = Path.relative_to(source, test_root)

    if relative_to_test == ".." or String.starts_with?(relative_to_test, "../") do
      Path.relative_to(source, project.abs_path)
    else
      relative_to_test
    end
  end

  defp projected_test_target(slug, relative) do
    case String.starts_with?(relative, "support/") do
      true ->
        Path.join([
          "test",
          "support",
          slug,
          String.replace_prefix(relative, "support/", "")
        ])

      false ->
        Path.join(["test", slug, relative])
    end
  end

  defp support_operations(project) do
    root = Path.join(["test", "support", "weld_projects", project_slug(project.id)])

    Enum.flat_map(@source_dirs ++ ["priv"], fn dir ->
      tree_operations(Path.join(project.abs_path, dir), Path.join(root, dir), :test)
    end)
  end

  defp private_operations(project) do
    tree_operations(Path.join(project.abs_path, "priv"), "priv", :runtime)
    |> Enum.reject(&String.starts_with?(&1.target, "priv/repo/migrations/"))
  end

  defp validate_source_assumptions!(plan) do
    Enum.each(Plan.projects_for_view(plan, :test), &validate_project_roots!/1)
    selected_apps = MapSet.new(Enum.map(plan.selected_projects, &Atom.to_string(&1.app)))

    issues =
      plan.selected_projects
      |> Enum.flat_map(fn project ->
        project
        |> source_files_for_scan()
        |> Enum.flat_map(
          &scan_file_for_selected_app_assumptions(&1, project, plan, selected_apps)
        )
      end)

    if issues != [] do
      raise Error,
            "unsupported selected-package OTP app assumptions detected for monolith mode:\n" <>
              Enum.map_join(issues, "\n", &"- #{&1}")
    end
  end

  defp validate_project_roots!(project) do
    unless Enum.all?(
             project.elixirc_paths ++ project.test_elixirc_paths,
             &(&1 in ["lib", "test/support"])
           ) and
             Enum.all?(project.erlc_paths ++ project.test_erlc_paths, &(&1 == "src")) and
             project.erlc_include_path == "include" do
      raise Error,
            "monolith compiler roots must use lib/src/include (project #{project.id}); " <>
              "use package_projection for custom compiler roots"
    end

    unless Enum.all?(project.test_paths, &(&1 == "test" or String.starts_with?(&1, "test/"))) do
      raise Error,
            "monolith test roots must be within test (project #{project.id}); " <>
              "use package_projection for independent test helpers"
    end

    project.test_paths
    |> Enum.reject(&(&1 == "test"))
    |> Enum.each(&validate_helper_delegate!(project, &1))
  end

  defp validate_helper_delegate!(project, path) do
    helper = Path.join([project.abs_path, path, "test_helper.exs"])

    if File.regular?(helper) and not canonical_helper_delegate?(project, helper) do
      raise Error, "monolith only transforms test/test_helper.exs (project #{project.id})"
    end
  end

  defp canonical_helper_delegate?(project, helper) do
    case helper |> File.read!() |> Code.string_to_quoted!(file: helper) do
      {{:., _, [{:__aliases__, _, [:Code]}, :require_file]}, _, [relative, {:__DIR__, _, _}]}
      when is_binary(relative) ->
        Path.expand(relative, Path.dirname(helper)) ==
          Path.join(project.abs_path, "test/test_helper.exs")

      _ ->
        false
    end
  end

  defp source_files_for_scan(project) do
    ["lib", "test"]
    |> Enum.flat_map(fn dir ->
      path = Path.join(project.abs_path, dir)

      if File.dir?(path) do
        path
        |> Hash.list_files()
        |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"]))
      else
        []
      end
    end)
  end

  defp scan_file_for_selected_app_assumptions(path, project, plan, selected_apps) do
    contents = File.read!(path)
    relative = Path.relative_to(path, plan.manifest.repo_root)

    [
      {"Application.ensure_all_started",
       ~r/Application\.ensure_all_started\(\s*:(?<app>[a-zA-Z0-9_]+)/},
      {"Application.app_dir", ~r/Application\.app_dir\(\s*:(?<app>[a-zA-Z0-9_]+)/}
    ]
    |> Enum.flat_map(fn {label, regex} ->
      Regex.scan(regex, contents, capture: :all_names)
      |> Enum.map(&List.first/1)
      |> Enum.filter(&MapSet.member?(selected_apps, &1))
      |> Enum.map(fn app ->
        "#{relative} uses #{label}(:#{app}) and still assumes standalone package app identity for #{project.id}"
      end)
    end)
  end

  defp root_ecto_repos_overlay([], _artifact_otp_app), do: nil

  defp root_ecto_repos_overlay(repo_infos, artifact_otp_app) do
    """
    config #{inspect(artifact_otp_app)},
      ecto_repos: #{inspect(Enum.map(repo_infos, & &1.module))}
    """
  end

  defp project_slug(project_id), do: FilePlan.slug(project_id)

  defp live_roots(plan, projects) do
    component_roots =
      Enum.flat_map(projects, fn project ->
        (@source_dirs ++ ["priv", "config", "test"] ++ project.test_paths)
        |> Enum.uniq()
        |> Enum.map(&Path.expand(&1, project.abs_path))
      end)

    output_roots =
      (plan.artifact.output.docs ++
         plan.artifact.output.assets ++ Projector.root_tooling_candidates())
      |> Enum.map(&Path.join(plan.manifest.repo_root, &1))

    Enum.uniq(component_roots ++ output_roots)
  end

  defp forced_external_deps(_manifest, []), do: []

  defp forced_external_deps(%Manifest{} = manifest, apps) do
    apps
    |> Enum.map(&normalize_forced_dep!(manifest, &1))
  end

  defp normalize_forced_dep!(%Manifest{} = manifest, app) when is_atom(app) do
    case Map.fetch(manifest.dependencies, app) do
      {:ok, %{requirement: requirement, opts: opts}} ->
        original =
          cond do
            is_binary(requirement) and requirement != "" and opts == [] -> {app, requirement}
            is_binary(requirement) and requirement != "" -> {app, requirement, opts}
            true -> {app, opts}
          end

        %{
          app: app,
          requirement: requirement,
          opts: opts,
          original: original,
          kind: :test
        }

      :error ->
        raise Error,
              "monolith extra_test_deps references #{inspect(app)} but no canonical dependency exists in the manifest"
    end
  end

  defp normalize_forced_dep!(_manifest, app) do
    raise Error, "monolith extra_test_deps entries must be atoms, got: #{inspect(app)}"
  end
end
