defmodule Mix.Tasks.Weld.Gc do
  use Mix.Task

  alias Weld.{Output, TaskSupport}

  @moduledoc """
  Prune old `.weld/publish/<artifact>/<hash>/run-*` workspaces, keeping the
  most recent `--keep N` completed runs (default: 2). Runs with an `ACTIVE`
  marker are always retained. Pass `--dry-run` to preview without mutation.
  """

  @shortdoc "Prune old Weld publish run workspaces"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [keep: :integer, dry_run: :boolean, format: :string])

    TaskSupport.reject_invalid!(invalid)
    keep = opts[:keep] || 2
    dry_run? = opts[:dry_run] || false

    root =
      case positional do
        [] -> File.cwd!()
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.gc [repo_root] [--keep N] [--dry-run] [--format json]")
      end

    report = prune(root, keep: keep, dry_run: dry_run?)

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(report, pretty: true))

      _ ->
        verb = if dry_run?, do: "Would remove", else: "Removed"

        Mix.shell().info(
          "#{verb} #{length(report.removed)} old publish run(s); kept #{length(report.kept)}."
        )
    end
  after
    Mix.Task.reenable("weld.gc")
  end

  @doc false
  def prune(repo_root, opts \\ []) do
    keep = Keyword.get(opts, :keep, 2)
    dry_run? = Keyword.get(opts, :dry_run, false)

    unless is_integer(keep) and keep >= 0,
      do: Mix.raise("--keep must be a non-negative integer")

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
      |> Enum.sort_by(fn path -> {File.stat!(path, time: :posix).mtime, path} end, :desc)
      |> Enum.split(keep)

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
