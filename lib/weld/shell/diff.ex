defmodule Weld.Shell.Diff do
  @moduledoc false
  @generated_dirs ~w(_build deps .git .weld doc)

  def compare(plan, path, kind) do
    unless File.dir?(path), do: raise(Weld.Error, "projection does not exist: #{path}")

    observed =
      path
      |> list_relative_files()
      |> Enum.reject(&(&1 in ["weld.provenance.json", "projection.lock.json"]))
      |> Map.new(fn relative ->
        file = Path.join(path, relative)
        stat = File.stat!(file)

        {relative,
         %{
           sha256: Weld.Hash.sha256_file(file),
           size: stat.size,
           executable: Bitwise.band(stat.mode, 0o111) != 0
         }}
      end)

    %{
      artifact: plan.artifact.id,
      kind: kind,
      path: path,
      entries: Weld.Core.Inventory.diff(plan.output_inventory, observed)
    }
  end

  defp list_relative_files(base) do
    base |> Path.expand() |> relative_files("", %{}) |> Enum.sort()
  end

  defp relative_files(path, relative, ancestors) do
    if Map.has_key?(ancestors, path),
      do: raise(Weld.Error, "directory link cycle while comparing #{path}")

    ancestors = Map.put(ancestors, path, true)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        path
        |> File.ls!()
        |> Enum.reject(&(&1 in @generated_dirs))
        |> Enum.flat_map(fn name ->
          relative_files(Path.join(path, name), Path.join(relative, name), ancestors)
        end)

      {:ok, %{type: :regular}} ->
        [relative]

      {:ok, %{type: :symlink}} ->
        path
        |> File.read_link!()
        |> Path.expand(Path.dirname(path))
        |> relative_files(relative, ancestors)

      {:ok, _} ->
        []

      {:error, reason} when reason in [:enoent, :enotdir] ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file stats", path: path
    end
  end
end
