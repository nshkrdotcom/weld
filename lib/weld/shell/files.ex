defmodule Weld.Shell.Files do
  @moduledoc false

  alias Weld.{Error, Hash, Output}
  alias Weld.Core.Inventory

  @doc "Observe a regular file without following a symlink at its leaf."
  def observe!(root, relative) do
    Inventory.validate_path!(relative)
    path = Output.source!(root, relative)

    case File.lstat(path) do
      {:ok, %{type: :regular, size: size, mode: mode}} ->
        %{
          target: relative,
          sha256: Hash.sha256_file(path),
          size: size,
          executable: Bitwise.band(mode, 0o111) != 0
        }

      {:error, :enoent} ->
        nil

      _ ->
        raise Error, "expected regular file: #{relative}"
    end
  end

  def observe_many!(root, relatives) do
    relatives
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn relative ->
      observe!(root, relative) || raise(Error, "missing inventory file: #{relative}")
    end)
  end

  def tree!(root) do
    Output.reject_tree_links!(root)
    {files, dirs} = walk(root, "")
    {Enum.sort_by(files, & &1.target), Enum.sort(dirs)}
  end

  defp walk(root, relative) do
    path = if relative == "", do: root, else: Output.source!(root, relative)

    case File.lstat!(path).type do
      :regular -> {[observe!(root, relative)], []}
      :directory -> walk_directory(root, relative, Enum.sort(File.ls!(path)))
      _ -> raise Error, "unsafe inventory node: #{relative}"
    end
  end

  defp walk_directory(_root, relative, []), do: {[], if(relative == "", do: [], else: [relative])}

  defp walk_directory(root, relative, names) do
    Enum.reduce(names, {[], []}, fn name, {files, dirs} ->
      child = if relative == "", do: name, else: Path.join(relative, name)
      {next_files, next_dirs} = walk(root, child)
      {next_files ++ files, next_dirs ++ dirs}
    end)
  end
end
