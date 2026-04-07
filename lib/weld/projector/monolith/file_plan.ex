defmodule Weld.Projector.Monolith.FilePlan do
  @moduledoc false

  alias Weld.Hash

  @spec merge_tree!(Path.t(), Path.t(), String.t(), Path.t()) :: %{
          copied_files: [String.t()],
          remaps: [map()]
        }
  def merge_tree!(source_root, target_root, project_slug, build_path) do
    if File.dir?(source_root) do
      source_root
      |> Hash.list_files()
      |> Enum.sort()
      |> Enum.reduce(%{copied_files: [], remaps: []}, fn source, acc ->
        relative = Path.relative_to(source, source_root)
        target = unique_target(source, Path.join(target_root, relative), project_slug)

        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)

        remaps =
          if Path.join(target_root, relative) == target do
            acc.remaps
          else
            [
              %{
                source: source,
                original_relative: Path.relative_to(Path.join(target_root, relative), build_path),
                remapped_relative: Path.relative_to(target, build_path)
              }
              | acc.remaps
            ]
          end

        %{
          copied_files: [Path.relative_to(target, build_path) | acc.copied_files],
          remaps: remaps
        }
      end)
      |> finalize()
    else
      %{copied_files: [], remaps: []}
    end
  end

  defp finalize(result) do
    %{
      copied_files: result.copied_files |> Enum.uniq() |> Enum.sort(),
      remaps: Enum.reverse(result.remaps)
    }
  end

  defp unique_target(source, target, project_slug) do
    cond do
      not File.exists?(target) ->
        target

      same_file?(source, target) ->
        target

      true ->
        remap_target(target, project_slug)
    end
  end

  defp remap_target(target, project_slug) do
    dirname = Path.dirname(target)
    ext = Path.extname(target)
    basename = Path.basename(target, ext)

    candidate = Path.join(dirname, "#{project_slug}__#{basename}#{ext}")

    if File.exists?(candidate) do
      remap_target(candidate, project_slug)
    else
      candidate
    end
  end

  defp same_file?(left, right) do
    File.regular?(left) and File.regular?(right) and File.read!(left) == File.read!(right)
  end
end
