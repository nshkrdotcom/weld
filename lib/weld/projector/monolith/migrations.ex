defmodule Weld.Projector.Monolith.Migrations do
  @moduledoc false

  alias Weld.Hash

  @spec merge!([Weld.Workspace.Project.t()], Path.t()) :: %{
          copied_files: [String.t()],
          remaps: [map()],
          layout: map()
        }
  def merge!(projects, build_path) do
    migrating_projects =
      projects
      |> Enum.filter(&(File.dir?(Path.join(&1.abs_path, "priv/repo/migrations"))))
      |> Enum.sort_by(& &1.id)

    layout =
      case length(migrating_projects) do
        0 -> %{case: :none, repo_count: 0, repo_paths: %{}}
        1 -> %{case: :single, repo_count: 1, repo_paths: %{hd(migrating_projects).id => "priv/repo"}}
        _ -> %{case: :multi, repo_count: length(migrating_projects), repo_paths: multi_repo_paths(migrating_projects)}
      end

    files =
      migrating_projects
      |> Enum.flat_map(fn project ->
        source_root = Path.join(project.abs_path, "priv/repo/migrations")

        source_root
        |> Hash.list_files()
        |> Enum.sort()
        |> Enum.map(fn source ->
          %{
            project_id: project.id,
            source: source,
            filename: Path.basename(source)
          }
        end)
      end)

    groups = Enum.group_by(files, &timestamp_prefix(&1.filename))

    {copied_files, remaps} =
      Enum.flat_map_reduce(groups, [], fn {_timestamp, entries}, acc ->
        copy_group!(entries, layout, build_path, acc)
      end)

    maybe_write_remap!(build_path, remaps, layout)

    %{
      copied_files: copied_files |> Enum.uniq() |> Enum.sort(),
      remaps: remaps,
      layout: layout
    }
  end

  defp multi_repo_paths(projects) do
    Map.new(projects, fn project ->
      slug = project.id |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.trim("_") |> String.downcase()
      {project.id, Path.join("priv/weld_repos", slug)}
    end)
  end

  defp copy_group!(entries, layout, build_path, acc) do
    multiple? = length(entries) > 1

    entries
    |> Enum.sort_by(fn entry -> {entry.project_id, entry.filename} end)
    |> Enum.with_index()
    |> Enum.map_reduce(acc, fn {entry, index}, remaps ->
      filename =
        if multiple? do
          restamp_filename(entry.filename, entry.project_id, index)
        else
          entry.filename
        end

      target =
        Path.join([
          build_path,
          Map.fetch!(layout.repo_paths, entry.project_id),
          "migrations",
          filename
        ])

      File.mkdir_p!(Path.dirname(target))
      File.cp!(entry.source, target)

      remaps =
        if filename == entry.filename do
          remaps
        else
          [
            %{
              project_id: entry.project_id,
              source: Path.basename(entry.source),
              remapped_to: filename
            }
            | remaps
          ]
        end

      {Path.relative_to(target, build_path), remaps}
    end)
  end

  defp restamp_filename(filename, project_id, index) do
    <<timestamp::binary-size(14), "_", rest::binary>> = filename
    base = String.to_integer(timestamp)

    offset =
      :erlang.phash2({project_id, filename, index}, 89_999)
      |> Kernel.+(1)

    "#{base + offset}_#{rest}"
  end

  defp timestamp_prefix(filename) do
    case String.split(filename, "_", parts: 2) do
      [timestamp, _rest] -> timestamp
      [single] -> single
    end
  end

  defp maybe_write_remap!(_build_path, [], _layout), do: :ok

  defp maybe_write_remap!(build_path, remaps, layout) do
    target =
      case layout.case do
        :single -> Path.join([build_path, "priv/repo/migrations", ".weld_remap.json"])
        :multi -> Path.join([build_path, "priv", ".weld_remap.json"])
        :none -> Path.join([build_path, "priv", ".weld_remap.json"])
      end

    File.mkdir_p!(Path.dirname(target))
    File.write!(target, Jason.encode_to_iodata!(remaps, pretty: true))
  end
end
