defmodule Weld.Config.Generator do
  @moduledoc false

  alias Weld.Error

  @spec generate!([Weld.Workspace.Project.t()], Path.t(), [map()], map(), keyword()) :: %{
          bootstrapped_apps: [atom()],
          bootstrapped_sources: [map()],
          copied_files: [String.t()],
          warnings: [map()],
          staged: [map()]
        }
  def generate!(projects, build_path, repo_infos, migration_layout, opts \\ []) do
    config_root = Path.join(build_path, "config")
    File.mkdir_p!(config_root)
    workspace_apps = projects |> Enum.map(& &1.app) |> Enum.uniq() |> Enum.sort() |> MapSet.new()

    shared_test_configs =
      build_shared_test_config_set(Keyword.get(opts, :shared_test_configs, []))

    staged =
      projects
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&stage_project_config!(&1, config_root, build_path, workspace_apps))

    warnings = skipped_test_config_warnings(staged, shared_test_configs)

    root_files =
      [
        write_root_config!(config_root, staged),
        write_env_file!(
          config_root,
          "dev.exs",
          staged,
          shared_test_configs,
          repo_infos,
          migration_layout
        ),
        write_env_file!(
          config_root,
          "test.exs",
          staged,
          shared_test_configs,
          repo_infos,
          migration_layout
        ),
        write_env_file!(
          config_root,
          "prod.exs",
          staged,
          shared_test_configs,
          repo_infos,
          migration_layout
        )
      ]
      |> Enum.filter(& &1)

    runtime_file = write_runtime_file!(config_root, staged)

    bootstrapped_apps =
      staged
      |> Enum.filter(&(not is_nil(&1.bootstrap)))
      |> Enum.map(& &1.app)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      bootstrapped_apps: bootstrapped_apps,
      bootstrapped_sources:
        staged
        |> Enum.map(& &1.bootstrap)
        |> Enum.reject(&is_nil/1),
      copied_files:
        (Enum.flat_map(staged, & &1.copied_files) ++ root_files ++ List.wrap(runtime_file))
        |> Enum.uniq()
        |> Enum.sort(),
      warnings: warnings,
      staged: staged
    }
  end

  defp stage_project_config!(project, config_root, build_path, workspace_apps) do
    slug = project_slug(project.id)
    source_root = Path.join(project.abs_path, "config")

    if File.dir?(source_root) do
      files = source_root |> File.ls!() |> Enum.sort()
      static_root = Path.join([config_root, "sources", slug])
      runtime_root = Path.join([config_root, "runtime_sources", slug])

      copied_files =
        source_root
        |> Weld.Hash.list_files()
        |> Enum.sort()
        |> Enum.flat_map(fn source ->
          stage_project_config_file!(
            source,
            source_root,
            static_root,
            runtime_root,
            build_path,
            workspace_apps
          )
        end)

      %{
        app: project.app,
        bootstrap: bootstrap_source(slug, files),
        project_id: project.id,
        slug: slug,
        files: files,
        copied_files: copied_files
      }
    else
      %{
        app: project.app,
        bootstrap: nil,
        project_id: project.id,
        slug: slug,
        files: [],
        copied_files: []
      }
    end
  end

  defp sanitize_config_source!(contents, source_path, workspace_apps, opts) do
    strip_imports? = Keyword.get(opts, :strip_imports?, false)

    case Code.string_to_quoted(contents, file: source_path) do
      {:ok, ast} ->
        ast
        |> sanitize_config_ast(workspace_apps, strip_imports?)
        |> sanitized_config_source()

      {:error, error} ->
        raise Error, "unable to parse #{source_path}: #{format_parse_error(error)}"
    end
  end

  defp config_directives?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:config, _meta, _args} = node, _found? -> {node, true}
        {:import_config, _meta, _args} = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp bootstrap_source(slug, files) do
    config_path = bootstrap_path(slug, "config.exs", files)
    runtime_path = bootstrap_path(slug, "runtime.exs", files)

    env_path_fallbacks = %{
      dev: bootstrap_path(slug, "dev.exs", files),
      test: bootstrap_path(slug, "test.exs", files),
      prod: bootstrap_path(slug, "prod.exs", files)
    }

    if Enum.any?([config_path, runtime_path] ++ Map.values(env_path_fallbacks), & &1) do
      %{
        config_path: config_path,
        env_path_fallbacks: env_path_fallbacks,
        runtime_path: runtime_path
      }
    end
  end

  defp bootstrap_path(slug, file_name, files) do
    if file_name in files do
      Path.join(["config", "runtime_sources", slug, file_name])
    end
  end

  defp write_root_config!(config_root, staged) do
    path = Path.join(config_root, "config.exs")

    source =
      [
        "import Config\n\n",
        render_imports(staged, "config.exs")
      ]
      |> IO.iodata_to_binary()

    File.write!(path, source)
    Path.relative_to(path, Path.dirname(config_root))
  end

  defp write_env_file!(
         config_root,
         env_file,
         staged,
         shared_test_configs,
         repo_infos,
         migration_layout
       ) do
    path = Path.join(config_root, env_file)
    env_name = Path.rootname(env_file)

    imports =
      case env_name do
        "test" -> render_test_imports(staged, shared_test_configs)
        _other -> render_imports(staged, env_file)
      end

    overlays = render_repo_priv_overlays(repo_infos, migration_layout)

    source =
      [
        "import Config\n\n",
        imports,
        if(imports != "" and overlays != "", do: "\n", else: ""),
        overlays
      ]
      |> IO.iodata_to_binary()

    File.write!(path, source)
    Path.relative_to(path, Path.dirname(config_root))
  end

  defp write_runtime_file!(config_root, staged) do
    if Enum.any?(staged, &("runtime.exs" in &1.files)) do
      path = Path.join(config_root, "runtime.exs")
      File.write!(path, "import Config\n\n" <> render_imports(staged, "runtime.exs"))
      Path.relative_to(path, Path.dirname(config_root))
    end
  end

  defp render_imports(staged, file_name) do
    staged
    |> Enum.filter(&(file_name in &1.files))
    |> Enum.map_join("\n", fn entry ->
      "import_config \"sources/#{entry.slug}/#{file_name}\""
    end)
  end

  defp render_test_imports(staged, shared_test_configs) do
    staged
    |> Enum.filter(&shared_test_import?(&1, shared_test_configs))
    |> Enum.map_join("\n", fn entry ->
      "import_config \"sources/#{entry.slug}/test.exs\""
    end)
  end

  defp render_repo_priv_overlays(repo_infos, migration_layout) do
    repo_infos
    |> Enum.flat_map(fn repo ->
      case Map.get(migration_layout.repo_paths || %{}, repo.project_id) do
        nil ->
          []

        "priv/repo" ->
          []

        repo_priv ->
          [
            """
            config #{inspect(repo.otp_app)}, #{inspect(repo.module)},
              priv: Path.expand("../#{repo_priv}", __DIR__)
            """
          ]
      end
    end)
    |> Enum.join("\n\n")
  end

  defp skipped_test_config_warnings(staged, shared_test_configs) do
    staged
    |> Enum.filter(&("test.exs" in &1.files))
    |> Enum.reject(&shared_test_config?(shared_test_configs, &1))
    |> Enum.map(fn entry ->
      %{
        type: :skipped_package_test_config,
        project_id: entry.project_id,
        slug: entry.slug,
        file: "config/test.exs",
        reason: "package test config is not implicitly globalized in monolith mode"
      }
    end)
  end

  defp build_shared_test_config_set(entries) do
    entries
    |> Enum.map(fn
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      other -> to_string(other)
    end)
    |> MapSet.new()
  end

  defp shared_test_config?(shared_test_configs, entry) do
    MapSet.member?(shared_test_configs, entry.project_id) or
      MapSet.member?(shared_test_configs, entry.slug)
  end

  defp stage_project_config_file!(
         source,
         source_root,
         static_root,
         runtime_root,
         build_path,
         workspace_apps
       ) do
    relative = Path.relative_to(source, source_root)
    static_target = Path.join(static_root, relative)
    runtime_target = Path.join(runtime_root, relative)

    File.mkdir_p!(Path.dirname(static_target))
    File.mkdir_p!(Path.dirname(runtime_target))

    copy_static_config!(source, static_target, relative, workspace_apps)
    File.cp!(source, runtime_target)

    [
      Path.relative_to(static_target, build_path),
      Path.relative_to(runtime_target, build_path)
    ]
  end

  defp copy_static_config!(source, static_target, relative, workspace_apps) do
    case Path.extname(source) do
      ".exs" ->
        source
        |> File.read!()
        |> sanitize_config_source!(source, workspace_apps,
          strip_imports?: relative == "config.exs"
        )
        |> then(&File.write!(static_target, &1))

      _other ->
        File.cp!(source, static_target)
    end
  end

  defp sanitize_config_ast(ast, workspace_apps, strip_imports?) do
    Macro.prewalk(ast, fn
      {:import_config, _meta, _args} when strip_imports? ->
        :ok

      {:config, _meta, [app | _rest]} = config_call when is_atom(app) ->
        maybe_keep_config_call(config_call, app, workspace_apps)

      other ->
        other
    end)
  end

  defp maybe_keep_config_call(config_call, app, workspace_apps) do
    if MapSet.member?(workspace_apps, app), do: :ok, else: config_call
  end

  defp sanitized_config_source(ast) do
    if config_directives?(ast) do
      ast
      |> Macro.to_string()
      |> Code.format_string!()
      |> IO.iodata_to_binary()
      |> Kernel.<>("\n")
    else
      "import Config\n"
    end
  end

  defp shared_test_import?(entry, shared_test_configs) do
    "test.exs" in entry.files and shared_test_config?(shared_test_configs, entry)
  end

  defp format_parse_error({metadata, message, token}) when is_list(metadata) do
    location =
      metadata
      |> parse_error_location()
      |> case do
        "" -> ""
        value -> value <> ": "
      end

    detail =
      case token do
        "" -> message
        _other -> "#{message} #{inspect(token)}"
      end

    location <> detail
  end

  defp parse_error_location(metadata) do
    line = metadata[:line]
    column = metadata[:column]

    cond do
      is_integer(line) and is_integer(column) -> "line #{line}, column #{column}"
      is_integer(line) -> "line #{line}"
      true -> ""
    end
  end

  defp project_slug(project_id) do
    project_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end
end
