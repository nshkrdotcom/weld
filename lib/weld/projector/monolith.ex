defmodule Weld.Projector.Monolith do
  @moduledoc false

  alias Weld.Config.Generator
  alias Weld.Error
  alias Weld.Hash
  alias Weld.Manifest
  alias Weld.Plan
  alias Weld.Projector.Monolith.FilePlan
  alias Weld.Projector.Monolith.Migrations
  alias Weld.Projector.Monolith.MixFile
  alias Weld.Projector.Monolith.TestHelper

  @source_dirs ~w(lib src c_src include)

  @spec project!(Plan.t(), Path.t()) :: map()
  def project!(%Plan{} = plan, build_path) do
    validate_source_assumptions!(plan)
    test_support_projects = resolve_test_support_projects!(plan)
    all_projects = plan.selected_projects ++ test_support_projects

    copied_docs = Enum.flat_map(plan.artifact.output.docs, &copy_relative!(plan, build_path, &1))

    copied_assets =
      Enum.flat_map(plan.artifact.output.assets, &copy_relative!(plan, build_path, &1))

    source_merge =
      Enum.reduce(plan.selected_projects, %{copied_files: [], remaps: []}, fn project, acc ->
        Enum.reduce(@source_dirs, acc, fn dir, inner ->
          source_root = Path.join(project.abs_path, dir)
          target_root = Path.join(build_path, dir)
          project_slug = project_slug(project.id)
          result = FilePlan.merge_tree!(source_root, target_root, project_slug, build_path)

          %{
            copied_files: inner.copied_files ++ result.copied_files,
            remaps: inner.remaps ++ result.remaps
          }
        end)
      end)

    test_merge =
      Enum.reduce(plan.selected_projects, %{copied_files: []}, fn project, acc ->
        result = copy_tests!(project, build_path)
        %{copied_files: acc.copied_files ++ result.copied_files}
      end)

    test_support_merge =
      Enum.reduce(test_support_projects, %{copied_files: []}, fn project, acc ->
        copied_files = copy_test_support_project!(project, build_path)
        %{copied_files: acc.copied_files ++ copied_files}
      end)

    migration_merge = Migrations.merge!(plan.selected_projects, build_path)
    copied_priv = Enum.flat_map(plan.selected_projects, &copy_non_migration_priv!(&1, build_path))
    helper_merge = TestHelper.generate!(plan.selected_projects, build_path)

    repo_infos = detect_repo_infos(all_projects)

    config_merge =
      Generator.generate!(
        all_projects,
        build_path,
        repo_infos,
        migration_merge.layout,
        shared_test_configs: plan.artifact.monolith_opts[:shared_test_configs] || []
      )

    forced_test_external_deps =
      forced_external_deps(plan.manifest, plan.artifact.monolith_opts[:extra_test_deps] || [])

    ensure_readme!(plan, build_path)

    generated_files =
      MixFile.render!(plan, build_path,
        bootstrapped_apps: config_merge.bootstrapped_apps,
        bootstrapped_config_sources: config_merge.bootstrapped_sources,
        runtime_external_deps: plan.external_deps,
        test_external_deps: Plan.external_deps_for_view(plan, :test),
        forced_test_external_deps: forced_test_external_deps,
        test_support_projects: test_support_projects
      )

    copied_files =
      [
        copied_docs,
        copied_assets,
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
      package_files: MixFile.package_files(build_path),
      file_remaps: source_merge.remaps,
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

  defp copy_tests!(project, build_path) do
    test_root = Path.join(project.abs_path, "test")
    slug = project_slug(project.id)

    if File.dir?(test_root) do
      copied_files =
        test_root
        |> Hash.list_files()
        |> Enum.sort()
        |> Enum.reject(&(Path.basename(&1) == "test_helper.exs"))
        |> Enum.flat_map(fn source ->
          relative = Path.relative_to(source, test_root)
          target = projected_test_target(build_path, slug, relative)

          File.mkdir_p!(Path.dirname(target))
          File.cp!(source, target)
          [Path.relative_to(target, build_path)]
        end)

      %{copied_files: copied_files}
    else
      %{copied_files: []}
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

  defp copy_test_support_project!(project, build_path) do
    project_root =
      Path.join([build_path, "test", "support", "weld_projects", project_slug(project.id)])

    (@source_dirs ++ ["priv"])
    |> Enum.flat_map(fn dir ->
      source_root = Path.join(project.abs_path, dir)
      target_root = Path.join(project_root, dir)

      if File.dir?(source_root) do
        File.mkdir_p!(Path.dirname(target_root))
        File.cp_r!(source_root, target_root)

        target_root
        |> list_copied_paths()
        |> Enum.map(&Path.relative_to(&1, build_path))
      else
        []
      end
    end)
  end

  defp copy_non_migration_priv!(project, build_path) do
    priv_root = Path.join(project.abs_path, "priv")

    if File.dir?(priv_root) do
      priv_root
      |> Hash.list_files()
      |> Enum.sort()
      |> Enum.reject(&String.contains?(Path.relative_to(&1, priv_root), "repo/migrations/"))
      |> Enum.flat_map(fn source ->
        relative = Path.relative_to(source, priv_root)
        target = Path.join([build_path, "priv", relative])

        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)
        [Path.relative_to(target, build_path)]
      end)
    else
      []
    end
  end

  defp ensure_readme!(plan, build_path) do
    readme = Path.join(build_path, "README.md")

    unless File.exists?(readme) do
      File.write!(readme, "# #{plan.artifact.package.name}\n")
    end
  end

  defp validate_source_assumptions!(plan) do
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

  defp detect_repo_infos(projects) do
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

  defp project_slug(project_id) do
    project_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end

  defp list_copied_paths(path) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> Weld.Hash.list_files(path)
      true -> []
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
