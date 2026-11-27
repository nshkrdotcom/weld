defmodule Weld.Hash do
  @moduledoc "Bounded exact regular-file observations; Core.Identity owns every digest domain."
  alias Weld.Core.Inventory
  alias Weld.Error
  @type digest :: String.t()
  @max_entries 250_000
  @max_bytes 512 * 1024 * 1024

  def sha256_file(path) do
    path
    |> File.stream!(64_000, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  def observation(root) do
    {entries, dirs, _count, _bytes} = walk(root, "", 0, 0)
    %{"entries" => Enum.sort_by(entries, & &1["path"]), "empty_dirs" => Enum.sort(dirs)}
  end

  defp walk(root, relative, count, bytes) do
    if count >= @max_entries, do: raise(Error, "observed tree exceeds entry limit")
    path = if relative == "", do: root, else: safe_path!(root, relative)

    case File.lstat!(path) do
      %{type: :regular, size: size, mode: mode} ->
        if relative == "", do: raise(Error, "observed tree root must be a directory")
        if bytes + size > @max_bytes, do: raise(Error, "observed tree exceeds byte limit")

        {[
           %{
             "path" => relative,
             "sha256" => sha256_file(path),
             "size" => size,
             "executable" => Bitwise.band(mode, 0o111) != 0
           }
         ], [], count + 1, bytes + size}

      %{type: :directory} ->
        names = File.ls!(path) |> Enum.sort()

        Enum.reduce(
          names,
          {[], if(names == [] and relative != "", do: [relative], else: []), count + 1, bytes},
          fn name, {entries, dirs, count, bytes} ->
            child = if relative == "", do: name, else: Path.join(relative, name)
            {next, empty, count, bytes} = walk(root, child, count, bytes)
            {next ++ entries, empty ++ dirs, count, bytes}
          end
        )

      _ ->
        raise Error, "unsafe file tree: #{relative}"
    end
  end

  def safe_path!(root, relative) do
    Inventory.validate_path!(relative)

    Path.split(relative)
    |> Enum.reduce(root, fn part, parent ->
      child = Path.join(parent, part)

      case File.lstat(child) do
        {:ok, %{type: type}} when type in [:regular, :directory] -> :ok
        {:error, :enoent} -> :ok
        _ -> raise Error, "unsafe file path: #{relative}"
      end

      child
    end)
  end

  def list_files(root) do
    case File.lstat(root) do
      {:error, :enoent} -> []
      _ -> for entry <- observation(root)["entries"], do: Path.join(root, entry["path"])
    end
  end

  def entries(root, relative_files) do
    relative_files
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn relative ->
      path = safe_path!(root, relative)

      case File.lstat!(path) do
        %{type: :regular, size: size, mode: mode} ->
          %{
            "path" => relative,
            "sha256" => sha256_file(path),
            "size" => size,
            "executable" => Bitwise.band(mode, 0o111) != 0
          }

        _ ->
          raise Error, "expected regular file: #{relative}"
      end
    end)
  end
end
