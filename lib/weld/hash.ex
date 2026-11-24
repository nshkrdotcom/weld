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
    identity_for_files(root, list_files(root))
  end

  @doc "Hashes portable project content independently of its provenance reports."
  @spec project_identity(Path.t()) :: digest()
  def project_identity(root) do
    files = list_files(root)
      |> Enum.reject(&(Path.relative_to(&1, root) in ["weld.provenance.json", "projection.lock.json"]))
    identity_for_files(root, files)
  end

  @doc "Hashes the exact portable inventory and its resolved standalone Mix lock."
  def portable_project_identity(root, relative_files) do
    lock = if File.regular?(Path.join(root, "mix.lock")), do: ["mix.lock"], else: []

    files =
      (relative_files ++ lock)
      |> Enum.reject(&(&1 in ["weld.provenance.json", "projection.lock.json"]))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn relative ->
        path = Weld.Output.source!(root, relative)
        unless match?({:ok, %{type: :regular}}, File.lstat(path)),
          do: raise(Weld.Error, "portable project input missing or unsafe: #{relative}")
        path
      end)

    identity_for_files(root, files)
  end

  @doc "Hashes verification inputs, allowing only the standalone resolved Mix lock to change."
  def verification_identity(root, relative_files) do
    files =
      relative_files
      |> Enum.reject(&(&1 == "mix.lock"))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn relative ->
        path = Weld.Output.source!(root, relative)

        unless match?({:ok, %{type: :regular}}, File.lstat(path)),
          do: raise(Weld.Error, "verification input missing or unsafe: #{relative}")

        path
      end)

    identity_for_files(root, files)
  end

  @doc "Hashes the current expansion of a publication allowlist, including new files."
  def package_identity(root, patterns) do
    relative_files =
      patterns
      |> Enum.flat_map(fn pattern ->
        root
        |> Path.join(pattern)
        |> Path.wildcard(match_dot: true)
        |> Enum.flat_map(fn path -> if File.dir?(path), do: list_files(path), else: [path] end)
      end)
      |> Enum.map(&Path.relative_to(&1, root))

    verification_identity(root, relative_files)
  end

  defp identity_for_files(root, files) do
    entries =
      for path <- files do
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
