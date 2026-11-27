defmodule Weld.Config.Generator do
  @moduledoc false

  alias Weld.Error
  alias Weld.Core.Facts
  alias Weld.Layout.FilePlan
  alias Weld.SourceFormatter

  def plan!(projects, repo_infos, migration_layout, opts \\ []) do
    config_root = "config"

    shared_test_configs =
      build_shared_test_config_set(Keyword.get(opts, :shared_test_configs, []))

    root_config_overlays =
      opts
      |> Keyword.get(:root_config_overlays, [])
      |> Enum.reject(&(&1 in [nil, ""]))

    staged =
      projects
      |> Enum.map(&stage_project_config!(&1, config_root))

    warnings = skipped_test_config_warnings(staged, shared_test_configs)

    root_files =
      [
        write_root_config!(config_root, staged, root_config_overlays),
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

    planning_inputs = Keyword.get(opts, :planning_inputs, [])

    root_files =
      Enum.map(root_files, fn op ->
        %{op | sources: Enum.sort(Enum.uniq(op.sources ++ planning_inputs))}
      end)

    runtime_file = write_runtime_file!(config_root, staged)
    operations = Enum.flat_map(staged, & &1.operations) ++ root_files ++ List.wrap(runtime_file)

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
      operations: operations,
      copied_files: Enum.map(operations, & &1.target) |> Enum.uniq() |> Enum.sort(),
      warnings: warnings,
      staged: staged
    }
  end

  defp stage_project_config!(project, config_root) do
    slug = project_slug(project.id)
    source_root = Path.join(project.abs_path, "config")

    if Facts.dir?(project.facts, source_root) do
      files = project.facts |> Facts.ls!(source_root) |> Enum.sort()
      static_root = Path.join([config_root, "sources", slug])
      runtime_root = Path.join([config_root, "runtime_sources", slug])
      bootstrap = bootstrap_source(slug, files)
      private_root = if bootstrap, do: Path.join(["priv", "weld", runtime_root])

      operations =
        project.facts
        |> Facts.list_files(source_root)
        |> Enum.sort()
        |> Enum.flat_map(fn source ->
          stage_project_config_file!(
            project.facts,
            source,
            source_root,
            static_root,
            runtime_root,
            private_root
          )
        end)

      %{
        app: project.app,
        bootstrap: bootstrap,
        project_id: project.id,
        slug: slug,
        files: files,
        operations: operations,
        copied_files: Enum.map(operations, & &1.target)
      }
    else
      %{
        app: project.app,
        bootstrap: nil,
        project_id: project.id,
        slug: slug,
        files: [],
        operations: [],
        copied_files: []
      }
    end
  end

  defp sanitize_config_source!(facts, contents, source_path, source_root, opts) do
    strip_imports? = Keyword.get(opts, :strip_imports?, false)

    case Code.string_to_quoted(contents, file: source_path) do
      {:ok, ast} ->
        ast
        |> sanitize_config_ast(strip_imports?, facts, source_path, source_root)
        |> sanitized_config_source()

      {:error, error} ->
        raise Error, "unable to parse #{source_path}: #{format_parse_error(error)}"
    end
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

  defp write_root_config!(config_root, staged, root_config_overlays) do
    path = Path.join(config_root, "config.exs")

    imports = render_imports(staged, "config.exs")
    overlays = Enum.join(root_config_overlays, "\n\n")

    source =
      [
        "import Config\n\n",
        imports,
        if(imports != "" and overlays != "", do: "\n\n", else: ""),
        overlays
      ]
      |> IO.iodata_to_binary()

    FilePlan.generated(path, SourceFormatter.format!(source), :metadata, config_inputs(staged))
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

    FilePlan.generated(path, SourceFormatter.format!(source), :metadata, config_inputs(staged))
  end

  defp write_runtime_file!(config_root, staged) do
    runtime_entries = Enum.filter(staged, &("runtime.exs" in &1.files))

    if runtime_entries != [] do
      path = Path.join(config_root, "runtime.exs")

      evals =
        Enum.map_join(runtime_entries, "\n", fn entry ->
          "Code.eval_file(Path.expand(\"runtime_sources/#{entry.slug}/runtime.exs\", __DIR__))"
        end)

      FilePlan.generated(
        path,
        SourceFormatter.format!("import Config\n\n" <> evals),
        :metadata,
        config_inputs(staged)
      )
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

  defp config_inputs(staged) do
    staged |> Enum.flat_map(& &1.operations) |> Enum.flat_map(& &1.sources) |> Enum.uniq()
  end

  defp stage_project_config_file!(facts, source, source_root, static_root, runtime_root, private_root) do
    relative = Path.relative_to(source, source_root)
    static_target = Path.join(static_root, relative)
    runtime_target = Path.join(runtime_root, relative)

    static =
      case Path.extname(source) do
        ".exs" ->
          content =
            sanitize_config_source!(facts, Facts.read!(facts, source), source, source_root,
              strip_imports?: relative == "config.exs"
            )

          FilePlan.generated(static_target, content, :metadata, [source], :transform)

        _ ->
          FilePlan.copy(source, static_target, :metadata, :copy)
      end

    private =
      if private_root,
        do: [FilePlan.copy(source, Path.join(private_root, relative), :runtime, :copy)],
        else: []

    [static, FilePlan.copy(source, runtime_target, :metadata, :copy)] ++ private
  end

  defp sanitize_config_ast(ast, strip_imports?, facts, source, source_root) do
    Macro.prewalk(ast, fn
      {:import_config, _, [relative]} = node when is_binary(relative) ->
        Weld.Core.Inventory.validate_path!(relative)
        absolute = Path.expand(relative, Path.dirname(source))
        unless String.starts_with?(absolute, source_root <> "/") and Facts.regular?(facts, absolute),
          do: raise(Error, "missing or escaping config import: #{relative}")
        node
      {:import_config, _, [expression]} = node ->
        supported = Macro.to_string(expression) in [~S("#{config_env()}.exs"), ~S("#{Mix.env()}.exs")]
        unless supported and strip_imports?, do: raise(Error, "unsupported dynamic config import: #{source}")
        if strip_imports?, do: :ok, else: node
      {:import_config, _, _} -> raise Error, "unsupported config import: #{source}"
      node -> node
    end)
  end

  defp sanitized_config_source(ast), do: ast |> Macro.to_string() |> SourceFormatter.format!()

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

  defp project_slug(project_id), do: FilePlan.slug(project_id)
end
