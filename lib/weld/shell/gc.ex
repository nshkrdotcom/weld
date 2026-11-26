defmodule Weld.Shell.GC do
  @moduledoc false
  alias Weld.Output

  @doc false
  def prune(repo_root, opts \\ []) do
    keep = Keyword.get(opts, :keep, 2)
    dry_run? = Keyword.get(opts, :dry_run, true)

    unless is_integer(keep) and keep >= 0,
      do: raise(Weld.Error, "--keep must be a non-negative integer")

    repo_root = Output.checkout(repo_root)
    publish_root = Output.path(repo_root, ["publish"])

    cond do
      not File.dir?(publish_root) ->
        report(repo_root, dry_run?, [], [], [])

      dry_run? ->
        prune_runs(repo_root, publish_root, keep, true)

      true ->
        Output.with_lock(repo_root, fn -> prune_runs(repo_root, publish_root, keep, false) end)
    end
  end

  defp prune_runs(repo_root, publish_root, keep, dry_run?) do
    runs =
      for artifact <- directories(publish_root),
          identity <- directories(artifact),
          run <- directories(identity),
          String.starts_with?(Path.basename(run), "run-"),
          do: run

    {active, completed} =
      Enum.split_with(runs, &match?({:ok, _}, File.lstat(Path.join(&1, "ACTIVE"))))

    {kept, removed} =
      completed
      |> Enum.group_by(fn path -> path |> Path.dirname() |> Path.dirname() end)
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn {_artifact, paths}, {kept, removed} ->
        {recent, old} =
          paths
          |> Enum.sort_by(fn path -> {File.stat!(path, time: :posix).mtime, path} end, :desc)
          |> Enum.split(keep)

        {kept ++ recent, removed ++ old}
      end)

    unless dry_run? do
      Enum.each(removed, &File.rm_rf!/1)
    end

    report(repo_root, dry_run?, active ++ kept, removed, active)
  end

  defp directories(parent) do
    parent
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&Path.join(parent, &1))
    |> Enum.filter(fn path ->
      Output.reject_link!(path)
      File.dir?(path)
    end)
  end

  defp report(root, dry_run?, kept, removed, active) do
    %{repo_root: root, dry_run: dry_run?, kept: kept, removed: removed, active: active}
  end
end
