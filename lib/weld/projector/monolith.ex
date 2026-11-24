defmodule Weld.Projector.Monolith do
  @moduledoc false

  alias Weld.Config.Generator
  alias Weld.Error
  alias Weld.Hash
  alias Weld.Manifest
  alias Weld.Plan
  alias Weld.Projector
  alias Weld.Projector.Live
  alias Weld.Projector.Monolith.FilePlan
  alias Weld.Projector.Monolith.Migrations
  alias Weld.Projector.Monolith.MixFile
  alias Weld.Projector.Monolith.TestHelper

  @source_dirs ~w(lib src c_src include)

  @spec project!(Plan.t(), Path.t()) :: map()
  def project!(%Plan{} = plan, build_path, opts \\ []) do
    kind = Keyword.get(opts, :kind, :full)
    validate_source_assumptions!(plan)

    if plan.artifact.verify.smoke.enabled or plan.artifact.verify.artifact_tests != [] do
      raise Error, "monolith verification does not support smoke or artifact_tests"
    end

    test_support_projects = resolve_test_support_projects!(plan)
    all_projects = plan.selected_projects ++ test_support_projects

    copied_docs = Enum.flat_map(plan.artifact.output.docs, &copy_relative!(plan, build_path, &1, kind))

    copied_assets =
      Enum.flat_map(plan.artifact.output.assets, &copy_relative!(plan, build_path, &1, kind))

    copied_tooling_files =
      Enum.flat_map(Projector.root_tooling_files(plan), &copy_relative!(plan, build_path, &1, kind))

    source_merge =
      Enum.reduce(plan.selected_projects,
        %{copied_files: [], remaps: [], source_mappings: [], collision_targets: [], collision_sources: []}, fn project, acc ->
        Enum.reduce(@source_dirs, acc, fn dir, inner ->
          source_root = Path.join(project.abs_path, dir)
          target_root = Path.join(build_path, dir)
          project_slug = project_slug(project.id)
          result = FilePlan.merge_tree!(source_root, target_root, project_slug, build_path, kind: kind)

          %{
            copied_files: inner.copied_files ++ result.copied_files,
            remaps: inner.remaps ++ result.remaps,
            source_mappings: inner.source_mappings ++ result.source_mappings,
            collision_targets: inner.collision_targets ++ result.collision_targets,
            collision_sources: inner.collision_sources ++ result.collision_sources
          }
        end)
      end)

    test_merge =
      Enum.reduce(plan.selected_projects, %{copied_files: []}, fn project, acc ->
        result = copy_tests!(project, build_path, kind)
        %{copied_files: acc.copied_files ++ result.copied_files}
      end)

    test_support_merge =
      Enum.reduce(test_support_projects, %{copied_files: []}, fn project, acc ->
        copied_files = copy_test_support_project!(project, build_path, kind)
        %{copied_files: acc.copied_files ++ copied_files}
      end)

    migration_merge = Migrations.merge!(plan.selected_projects, build_path)
    copied_priv = Enum.flat_map(plan.selected_projects, &copy_non_migration_priv!(&1, build_path, kind))
    helper_merge = TestHelper.generate!(plan.selected_projects, build_path)

    repo_infos = Projector.detect_repo_infos(all_projects)

    config_merge =
      Generator.generate!(
        all_projects,
        build_path,
        repo_infos,
        migration_merge.layout,
        shared_test_configs: plan.artifact.monolith_opts[:shared_test_configs] || [],
        root_config_overlays:
          List.wrap(root_ecto_repos_overlay(repo_infos, plan.artifact.package.otp_app))
      )

    forced_test_external_deps =
      forced_external_deps(plan.manifest, plan.artifact.monolith_opts[:extra_test_deps] || [])

    ensure_readme!(plan, build_path)

    Weld.Projector.SourceProject.validate_modules!([Path.join(build_path, "lib")])

    live_guard =
      if kind == :live do
        roots = live_roots(plan, all_projects)
        Live.guard_source(plan,
          directories: Enum.filter(roots, &File.dir?/1),
          topology: roots,
          digests: transformed_inputs(all_projects) ++ collision_inputs(source_merge)
        )
      else
        ""
      end

    generated_files =
      MixFile.render!(plan, build_path,
        bootstrapped_apps: config_merge.bootstrapped_apps,
        bootstrapped_config_sources: config_merge.bootstrapped_sources,
        runtime_external_deps: plan.external_deps,
        test_external_deps: Plan.external_deps_for_view(plan, :test),
        forced_test_external_deps: forced_test_external_deps,
        test_support_projects: test_support_projects,
        live?: kind == :live,
        live_guard: live_guard
      )

    copied_files =
      [
        copied_docs,
        copied_assets,
        copied_tooling_files,
        source_merge.copied_files,
        test_merge.copied_files,
        test_support_merge.copied_files,
        migration_merge.copied_files,
        copied_priv,
        helper_merge.copied_files,
        config_merge.copied_files,
        generated_files
      ]
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    %{
      mode: :monolith,
      copied_files: copied_files,
      linked_files: if(kind == :live, do: linked_files(build_path), else: []),
      package_files: MixFile.package_files(plan, build_path),
      file_remaps: source_merge.remaps,
      source_mappings: source_merge.source_mappings,
      migration_layout: migration_merge.layout,
      migration_remaps: migration_merge.remaps,
      helper_transformations: helper_merge.transformations,
      config_warnings: config_merge.warnings,
      repo_infos: repo_infos,
      test_support_projects: Enum.map(test_support_projects, & &1.id)
    }
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

  defp copy_relative!(plan, build_path, relative_path, kind) do
    source = Path.join(plan.manifest.repo_root, relative_path)
    target = Path.join(build_path, relative_path)

    if File.exists?(target), do: raise(Error, "projection path collision: #{relative_path}")

    cond do
      File.regular?(source) ->
        File.mkdir_p!(Path.dirname(target))
        copy_or_link!(source, target, kind)
        [relative_path]

      File.dir?(source) ->
        File.mkdir_p!(Path.dirname(target))
        files = Hash.list_files(source)
        if kind == :live do
          File.mkdir_p!(target)
          for file <- files do
            destination = Path.join(target, Path.relative_to(file, source))
            File.mkdir_p!(Path.dirname(destination))
            File.ln_s!(file, destination)
          end
        else
          File.cp_r!(source, target)
        end
        Enum.map(files, &Path.join(relative_path, Path.relative_to(&1, source)))

      true ->
        raise Error, "copy target not found: #{relative_path}"
    end
  end

  defp copy_tests!(project, build_path, kind) do
    slug = project_slug(project.id)

    copied_files =
      project.test_paths
      |> Enum.map(&project_test_path!(project, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&Hash.list_files/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(Path.basename(&1) == "test_helper.exs"))
      |> Enum.flat_map(fn source ->
        relative = project_test_relative(project, source)
        target = projected_test_target(build_path, slug, relative)

        File.mkdir_p!(Path.dirname(target))
        copy_or_link!(source, target, kind)
        [Path.relative_to(target, build_path)]
      end)

    %{copied_files: copied_files}
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

  defp projected_test_target(build_path, slug, relative) do
    case String.starts_with?(relative, "support/") do
      true ->
        Path.join([
          build_path,
          "test",
          "support",
          slug,
          String.replace_prefix(relative, "support/", "")
        ])

      false ->
        Path.join([build_path, "test", slug, relative])
    end
  end

  defp copy_test_support_project!(project, build_path, kind) do
    project_root =
      Path.join([build_path, "test", "support", "weld_projects", project_slug(project.id)])

    (@source_dirs ++ ["priv"])
    |> Enum.flat_map(fn dir ->
      source_root = Path.join(project.abs_path, dir)
      target_root = Path.join(project_root, dir)

      if File.dir?(source_root) do
        File.mkdir_p!(Path.dirname(target_root))
        files = Hash.list_files(source_root)
        copy_or_link!(source_root, target_root, kind)
        Enum.map(files, fn path ->
          Path.join(Path.relative_to(target_root, build_path), Path.relative_to(path, source_root))
        end)
      else
        []
      end
    end)
  end

  defp copy_non_migration_priv!(project, build_path, kind) do
    priv_root = Path.join(project.abs_path, "priv")

    if File.dir?(priv_root) do
      priv_root
      |> Hash.list_files()
      |> Enum.sort()
      |> Enum.reject(&String.contains?(Path.relative_to(&1, priv_root), "repo/migrations/"))
      |> Enum.flat_map(fn source ->
        relative = Path.relative_to(source, priv_root)
        target = Path.join([build_path, "priv", relative])

        destination = Path.relative_to(target, build_path)

        copy_private_asset!(source, target, destination, project.id, kind)
        [destination]
      end)
    else
      []
    end
  end

  defp copy_private_asset!(source, target, destination, project_id, kind) do
    if File.exists?(target) do
      raise Error, "priv path collision at #{destination} while copying #{project_id}"
    end

    case File.mkdir_p(Path.dirname(target)) do
      :ok ->
        copy_or_link!(source, target, kind)

      {:error, reason} ->
        raise Error, "cannot create parent of #{destination} for #{project_id}: #{reason}"
    end
  end

  defp ensure_readme!(plan, build_path) do
    readme = Path.join(build_path, "README.md")

    unless File.exists?(readme) do
      File.write!(readme, "# #{plan.artifact.package.name}\n")
    end
  end

  defp validate_source_assumptions!(plan) do
    for project <- Plan.projects_for_view(plan, :test) do
      unless Enum.all?(project.elixirc_paths ++ project.test_elixirc_paths,
               &(&1 in ["lib", "test/support"])) and
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

      for path <- project.test_paths, path != "test" do
        helper = Path.join([project.abs_path, path, "test_helper.exs"])
        if File.regular?(helper) and not canonical_helper_delegate?(project, helper) do
          raise Error, "monolith only transforms test/test_helper.exs (project #{project.id})"
        end
      end
    end
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

  defp canonical_helper_delegate?(project, helper) do
    case helper |> File.read!() |> Code.string_to_quoted!(file: helper) do
      {{:., _, [{:__aliases__, _, [:Code]}, :require_file]}, _,
       [relative, {:__DIR__, _, _}]} when is_binary(relative) ->
        Path.expand(relative, Path.dirname(helper)) ==
          Path.join(project.abs_path, "test/test_helper.exs")

      _ -> false
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

  defp project_slug(project_id) do
    project_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end

  defp copy_or_link!(source, target, :full), do: File.cp_r!(source, target)
  defp copy_or_link!(source, target, :live), do: File.ln_s!(source, target)

  defp live_roots(plan, projects) do
    component_roots = Enum.flat_map(projects, fn project ->
      (@source_dirs ++ ["priv", "config", "test"] ++ project.test_paths)
      |> Enum.uniq()
      |> Enum.map(&Path.expand(&1, project.abs_path))
    end)

    output_roots =
      (plan.artifact.output.docs ++ plan.artifact.output.assets ++ Projector.root_tooling_files(plan))
      |> Enum.map(&Path.join(plan.manifest.repo_root, &1))

    Enum.uniq(component_roots ++ output_roots)
  end

  defp transformed_inputs(projects) do
    Enum.flat_map(projects, fn project ->
      roots = [Path.join(project.abs_path, "config"), Path.join(project.abs_path, "priv/repo/migrations")]
      files = Enum.flat_map(roots, fn path -> if File.dir?(path), do: Hash.list_files(path), else: [] end)
      helpers = ["test" | project.test_paths]
        |> Enum.uniq()
        |> Enum.map(&Path.join([project.abs_path, &1, "test_helper.exs"]))
      helpers ++ files
    end)
  end

  defp collision_inputs(source_merge) do
    prior = for entry <- source_merge.source_mappings,
      entry.target in source_merge.collision_targets, do: entry.source
    Enum.uniq(prior ++ source_merge.collision_sources)
  end

  defp linked_files(root) do
    collect_links(root, root) |> Enum.uniq() |> Enum.sort()
  end

  defp collect_links(path, root) do
    case File.lstat!(path).type do
      :directory ->
        path |> File.ls!() |> Enum.flat_map(&collect_links(Path.join(path, &1), root))

      :symlink ->
        source = path |> File.read_link!() |> Path.expand(Path.dirname(path))
        if File.dir?(source) do
          source |> Hash.list_files() |> Enum.map(fn file ->
            Path.join(Path.relative_to(path, root), Path.relative_to(file, source))
          end)
        else
          [Path.relative_to(path, root)]
        end

      :regular -> []
    end
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
