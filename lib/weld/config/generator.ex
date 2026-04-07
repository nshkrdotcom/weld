defmodule Weld.Config.Generator do
  @moduledoc false

  alias Weld.Error

  @spec generate!([Weld.Workspace.Project.t()], Path.t(), [map()], map(), keyword()) :: %{
          copied_files: [String.t()],
          warnings: [map()],
          staged: [map()]
        }
  def generate!(projects, build_path, repo_infos, migration_layout, opts \\ []) do
    config_root = Path.join(build_path, "config")
    File.mkdir_p!(config_root)

    shared_test_configs = build_shared_test_config_set(Keyword.get(opts, :shared_test_configs, []))

    staged =
      projects
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&stage_project_config!(&1, config_root, build_path))

    warnings = skipped_test_config_warnings(staged, shared_test_configs)

    root_files =
      [
        write_root_config!(config_root, staged),
        write_env_file!(config_root, "dev.exs", staged, shared_test_configs, repo_infos, migration_layout),
        write_env_file!(config_root, "test.exs", staged, shared_test_configs, repo_infos, migration_layout),
        write_env_file!(config_root, "prod.exs", staged, shared_test_configs, repo_infos, migration_layout)
      ]
      |> Enum.filter(& &1)

    runtime_file = write_runtime_file!(config_root, staged)

    %{
      copied_files:
        (Enum.flat_map(staged, & &1.copied_files) ++ root_files ++ List.wrap(runtime_file))
        |> Enum.uniq()
        |> Enum.sort(),
      warnings: warnings,
      staged: staged
    }
  end

  defp stage_project_config!(project, config_root, build_path) do
    slug = project_slug(project.id)
    source_root = Path.join(project.abs_path, "config")

    if File.dir?(source_root) do
      target_root = Path.join([config_root, "sources", slug])
      files = source_root |> File.ls!() |> Enum.sort()

      copied_files =
        files
        |> Enum.flat_map(fn child ->
          source = Path.join(source_root, child)
          target = Path.join(target_root, child)
          File.mkdir_p!(Path.dirname(target))

          cond do
            File.dir?(source) ->
              File.cp_r!(source, target)

            child == "config.exs" ->
              source
              |> File.read!()
              |> sanitize_root_config_source!(source)
              |> then(&File.write!(target, &1))

            true ->
              File.cp!(source, target)
          end

          if File.dir?(target) do
            Weld.Hash.list_files(target)
            |> Enum.map(&Path.relative_to(&1, build_path))
          else
            [Path.relative_to(target, build_path)]
          end
        end)

      %{
        project_id: project.id,
        slug: slug,
        files: files,
        copied_files: copied_files
      }
    else
      %{project_id: project.id, slug: slug, files: [], copied_files: []}
    end
  end

  defp sanitize_root_config_source!(contents, source_path) do
    case Code.string_to_quoted(contents, file: source_path) do
      {:ok, ast} ->
        ast
        |> Macro.prewalk(fn
          {:import_config, _meta, _args} -> :ok
          other -> other
        end)
        |> Macro.to_string()
        |> Code.format_string!()
        |> IO.iodata_to_binary()
        |> Kernel.<>("\n")

      {:error, error} ->
        raise Error, "unable to parse #{source_path}: #{Exception.message(error)}"
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

  defp write_env_file!(config_root, env_file, staged, shared_test_configs, repo_infos, migration_layout) do
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
    |> Enum.filter(&("test.exs" in &1.files))
    |> Enum.filter(&shared_test_config?(shared_test_configs, &1))
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

  defp project_slug(project_id) do
    project_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end
end
