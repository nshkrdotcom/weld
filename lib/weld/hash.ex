defmodule Weld.Hash do
  @moduledoc """
  Deterministic SHA-256 helpers for files, directories, and in-memory values.
  """

  @type digest :: String.t()

  @spec sha256_binary(binary()) :: digest()
  def sha256_binary(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  @spec sha256_file(Path.t()) :: digest()
  def sha256_file(path) do
    path
    |> File.stream!(64_000, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @spec sha256_tree(Path.t()) :: digest()
  def sha256_tree(root) do
    entries =
      root
      |> list_files()
      |> Enum.map_join("\n", fn path ->
        relative = Path.relative_to(path, root)
        "#{relative}:#{sha256_file(path)}"
      end)

    sha256_binary(entries)
  end

  @doc "Hashes relative paths, executable flags and bytes using length-delimited entries."
  @spec content_identity(Path.t()) :: digest()
  def content_identity(root) do
    entries =
      for path <- list_files(root) do
        relative = Path.relative_to(path, root)
        executable = Bitwise.band(File.stat!(path).mode, 0o111)
        :erlang.term_to_binary({relative, executable, sha256_file(path)})
      end

    :crypto.hash(:sha256, entries) |> Base.encode16(case: :lower)
  end

  @spec list_files(Path.t()) :: [Path.t()]
  def list_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end
end
