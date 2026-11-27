defmodule Weld.Shell.GC do
  @moduledoc "Read-only-by-default collection of completed managed runs; immutable evidence is retained."
  alias Weld.{Error, Output}

  def prune(root, opts \\ []) do
    keep = Keyword.get(opts, :keep, 2)
    dry? = Keyword.get(opts, :dry_run, true)
    unless is_integer(keep) and keep >= 0, do: raise(Error, "--keep must be a non-negative integer")
    root = Output.checkout(root)
    if dry? do
      collect(root, keep, true)
    else
      Output.with_lock(root, fn -> collect(root, keep, false) end)
    end
  end

  defp collect(root, keep, dry?) do
    base = Output.path(root, [])
    unknown = directories(Path.join(base, "runs")) |> Enum.reject(&(Path.basename(&1) in ~w(verify prepare publish stage)))
      |> Enum.map(&%{path: &1, record: nil})
    runs = for operation <- ~w(verify prepare publish stage),
      artifact <- directories(Path.join([base, "runs", operation])),
      run <- directories(artifact), do: inspect_run(run)
    # Invalid leases make all liveness unknown, hence nothing is removable.
    leases = safe_leases(root)
    {held, finished} = Enum.split_with(runs ++ unknown, &held?(&1, leases))
    {kept, candidates} = finished |> Enum.group_by(&Path.dirname(&1.path)) |> Enum.sort()
      |> Enum.reduce({[], []}, fn {_group, entries}, {kept, removed} ->
        {recent, old} = entries |> Enum.sort_by(&{&1.record["finished_at"], &1.path}, :desc) |> Enum.split(keep)
        {kept ++ recent, removed ++ old}
      end)
    removed = if dry? do
      Enum.map(candidates, & &1.path)
    else
      for candidate <- candidates do
        # The metadata lock excludes a concurrent reservation; compare exact run
        # bytes again before removal and never follow a replaced path.
        unless Output.read_run!(candidate.path) == candidate.record, do: raise(Error, "run changed during garbage collection")
        Output.safe_remove!(base, candidate.path)
        candidate.path
      end
    end
    %{repo_root: root, dry_run: dry?, kept: Enum.map(held ++ kept, & &1.path) |> Enum.sort(),
      removed: Enum.sort(removed), active: Enum.map(held, & &1.path) |> Enum.sort(),
      immutable: :retained, unknown_ownership: leases == :unknown}
  end

  defp held?(%{record: nil}, _), do: true
  defp held?(_, :unknown), do: true
  defp held?(%{record: record}, leases) do
    record["phase"] not in ["completed", "failed"] or is_nil(record["finished_at"]) or
      Enum.any?(leases, fn {_path, lease} -> lease["id"] == record["lease_id"] end)
  end

  defp safe_leases(root) do
    Output.leases(root)
  rescue
    _ -> :unknown
  end

  defp inspect_run(path) do
    %{path: path, record: Output.read_run!(path)}
  rescue
    _ -> %{path: path, record: nil}
  end

  defp directories(parent) do
    Output.reject_link!(parent)
    case File.ls(parent) do
      {:ok, entries} -> entries |> Enum.sort() |> Enum.map(&Path.join(parent, &1)) |> Enum.filter(fn path ->
        Output.reject_link!(path)
        File.dir?(path)
      end)
      {:error, :enoent} -> []
      {:error, reason} -> raise Error, "cannot inspect managed runs: #{reason}"
    end
  end
end
