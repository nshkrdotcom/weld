defmodule Weld.Projector.Monolith.FilePlan do
  @moduledoc false

  alias Weld.Hash

  @spec merge_tree!(Path.t(), Path.t(), String.t(), Path.t()) :: %{
          copied_files: [String.t()],
          remaps: [map()]
        }
  def merge_tree!(source_root, target_root, project_slug, build_path, opts \\ []) do
    if File.dir?(source_root) do
      source_root
      |> Hash.list_files()
      |> Enum.sort()
      |> Enum.reduce(empty(), fn source, acc ->
        merge_file!(acc, source, source_root, target_root, project_slug, build_path, opts)
      end)
      |> finalize()
    else
      empty()
    end
  end

  defp merge_file!(acc, source, source_root, target_root, project_slug, build_path, opts) do
    relative = Path.relative_to(source, source_root)
    original_target = Path.join(target_root, relative)
    {target, collisions} = unique_target(source, original_target, project_slug)

    File.mkdir_p!(Path.dirname(target))
    if opts[:kind] == :live do
      # Identical collision inputs deliberately share the first link. The live
      # guard hashes every collision participant so equivalence cannot go stale.
      unless File.exists?(target), do: File.ln_s!(source, target)
    else
      File.cp!(source, target)
    end

    %{
      copied_files: [Path.relative_to(target, build_path) | acc.copied_files],
      remaps: remap_entries(acc.remaps, source, original_target, target, build_path),
      source_mappings: [%{source: source, target: Path.relative_to(target, build_path)} | acc.source_mappings],
      collision_targets: Enum.map(collisions, &Path.relative_to(&1, build_path)) ++ acc.collision_targets,
      collision_sources: (if collisions == [], do: [], else: [source]) ++ acc.collision_sources
    }
  end

  defp remap_entries(remaps, _source, original_target, original_target, _build_path), do: remaps

  defp remap_entries(remaps, source, original_target, target, build_path) do
    [
      %{
        source: source,
        original_relative: Path.relative_to(original_target, build_path),
        remapped_relative: Path.relative_to(target, build_path)
      }
      | remaps
    ]
  end

  defp finalize(result) do
    %{result |
      copied_files: result.copied_files |> Enum.uniq() |> Enum.sort(),
      remaps: Enum.reverse(result.remaps)
    }
  end

  defp unique_target(source, target, project_slug) do
    cond do
      not File.exists?(target) ->
        {target, []}

      same_file?(source, target) ->
        {target, [target]}

      true ->
        remap_target(target, project_slug, [target])
    end
  end

  defp remap_target(target, project_slug, collisions) do
    dirname = Path.dirname(target)
    ext = Path.extname(target)
    basename = Path.basename(target, ext)

    candidate = Path.join(dirname, "#{project_slug}__#{basename}#{ext}")

    if File.exists?(candidate) do
      remap_target(candidate, project_slug, [candidate | collisions])
    else
      {candidate, collisions}
    end
  end

  defp same_file?(left, right) do
    File.regular?(left) and File.regular?(right) and File.read!(left) == File.read!(right)
  end

  defp empty do
    %{copied_files: [], remaps: [], source_mappings: [], collision_targets: [], collision_sources: []}
  end
end
