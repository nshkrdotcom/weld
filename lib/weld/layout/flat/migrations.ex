defmodule Weld.Layout.Flat.Migrations do
  @moduledoc false

  alias Weld.{Error, Hash}
  alias Weld.Layout.FilePlan

  @spec merge!([Weld.Workspace.Project.t()], Path.t()) :: %{
          operations: [map()],
          copied_files: [String.t()],
          remaps: [map()],
          layout: map()
        }
  def merge!(projects, build_path) do
    result = plan!(projects)
    FilePlan.materialize!(result.operations, build_path, :full)
    result
  end

  def plan!(projects) do
    migrating_projects =
      projects
      |> Enum.filter(&File.dir?(Path.join(&1.abs_path, "priv/repo/migrations")))
      |> Enum.sort_by(& &1.id)

    layout =
      case length(migrating_projects) do
        0 ->
          %{case: :none, repo_count: 0, repo_paths: %{}}

        1 ->
          %{case: :single, repo_count: 1, repo_paths: %{hd(migrating_projects).id => "priv/repo"}}

        _ ->
          %{
            case: :multi,
            repo_count: length(migrating_projects),
            repo_paths: multi_repo_paths(migrating_projects)
          }
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

    # Reserve every original timestamp first. Offset collisions (including
    # offsets hitting another original group) advance deterministically.
    reserved = MapSet.new(Map.keys(groups))

    {operations, {remaps, _used}} =
      groups
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map_reduce({[], reserved}, fn {_timestamp, entries}, acc ->
        plan_group!(entries, layout, acc)
      end)

    remaps = Enum.reverse(remaps)
    operations = operations ++ remap_operations(remaps, layout, Enum.map(files, & &1.source))

    %{
      operations: operations,
      copied_files: Enum.map(operations, & &1.target) |> Enum.sort(),
      remaps: remaps,
      layout: layout
    }
  end

  defp multi_repo_paths(projects) do
    Map.new(projects, fn project ->
      slug = FilePlan.slug(project.id)

      {project.id, Path.join("priv/weld_repos", slug)}
    end)
  end

  defp plan_group!(entries, layout, acc) do
    multiple? = length(entries) > 1

    entries
    |> Enum.sort_by(fn entry -> {entry.project_id, entry.filename} end)
    |> Enum.with_index()
    |> Enum.map_reduce(acc, fn {entry, index}, {remaps, used} ->
      {filename, used} =
        if multiple? do
          restamp_filename(entry.filename, entry.project_id, index, used)
        else
          {entry.filename, used}
        end

      target =
        Path.join([
          Map.fetch!(layout.repo_paths, entry.project_id),
          "migrations",
          filename
        ])

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

      {FilePlan.copy(entry.source, target, :runtime, :copy), {remaps, used}}
    end)
  end

  defp restamp_filename(filename, project_id, index, used) do
    unless Regex.match?(~r/^[0-9]{14}_/, filename),
      do: raise(Error, "invalid colliding migration filename: #{filename}")

    <<timestamp::binary-size(14), "_", rest::binary>> = filename
    base = String.to_integer(timestamp)

    offset =
      :erlang.phash2({project_id, filename, index}, 89_999)
      |> Kernel.+(1)

    stamp = unused_timestamp(base + offset, used)
    {"#{stamp}_#{rest}", MapSet.put(used, stamp)}
  end

  defp unused_timestamp(value, used) do
    stamp = Integer.to_string(value) |> String.pad_leading(14, "0")
    if byte_size(stamp) != 14, do: raise(Error, "migration restamp exceeds 14 digits")
    if MapSet.member?(used, stamp), do: unused_timestamp(value + 1, used), else: stamp
  end

  defp timestamp_prefix(filename) do
    case String.split(filename, "_", parts: 2) do
      [timestamp, _rest] -> timestamp
      [single] -> single
    end
  end

  defp remap_operations([], _layout, _sources), do: []

  defp remap_operations(remaps, layout, sources) do
    target =
      if layout.case == :single,
        do: "priv/repo/migrations/.weld_remap.json",
        else: "priv/.weld_remap.json"

    [FilePlan.generated(target, Jason.encode!(remaps, pretty: true), :runtime, sources)]
  end
end
