defmodule Weld.Receipt do
  @moduledoc "Closed canonical local projection-cache observations; never release proof."
  alias Weld.Core.Identity
  alias Weld.{Error, Hash, Output}
  @keys ~w(schema artifact kind plan_id local_link_locator_digest observed_tree_digest)

  def read(path, plan_id) do
    with {:ok, bytes} <- File.read(path),
         record <- Identity.decode!(bytes),
         true <- Enum.sort(Map.keys(record)) == Enum.sort(@keys),
         "weld.projection_cache/2" <- record["schema"],
         ^plan_id <- record["plan_id"],
         true <- record["kind"] in ~w(full live),
         true <- Identity.valid?(record["observed_tree_digest"]) do
      {:ok, record}
    else
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  def write!(path, record) do
    unless Enum.sort(Map.keys(record)) == Enum.sort(@keys),
      do: raise(Error, "invalid projection cache record")
    Output.write_atomic!(path, Identity.canonical(record))
  end

  def digest(value), do: Identity.digest("projection_cache", value)

  def tree(path, links? \\ false) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode, size: size}} ->
        %{"type" => "file", "executable" => Bitwise.band(mode, 0o111) != 0,
          "size" => size, "sha256" => Hash.sha256_file(path)}
      {:ok, %{type: :directory}} ->
        %{"type" => "directory", "children" => path |> File.ls!() |> Enum.sort()
          |> Enum.map(&%{"name" => &1, "entry" => tree(Path.join(path, &1), links?)})}
      {:ok, %{type: :symlink}} when links? -> %{"type" => "link", "target" => File.read_link!(path)}
      {:error, :enoent} -> %{"type" => "missing"}
      _ -> raise Error, "unsafe cache observation: #{path}"
    end
  end
end
