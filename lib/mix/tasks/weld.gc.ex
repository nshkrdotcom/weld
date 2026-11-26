defmodule Mix.Tasks.Weld.Gc do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Prune old `.weld/publish/<artifact>/<hash>/run-*` workspaces, keeping the
  most recent `--keep N` runs (default: 2). Pass `--dry-run` to preview.
  """

  @shortdoc "Prune old Weld publish run workspaces"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [keep: :integer, dry_run: :boolean, format: :string])

    TaskSupport.reject_invalid!(invalid)
    keep = max(opts[:keep] || 2, 0)
    dry_run? = opts[:dry_run] || false
    root = List.first(positional) || File.cwd!()

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
    publish_root = Path.join([repo_root, ".weld", "publish"])

    runs =
      publish_root
      |> Path.join("*/*/run-*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.dir?/1)
      |> Enum.sort_by(fn path -> File.stat!(path, time: :posix).mtime end, :desc)

    {kept, removed} = Enum.split(runs, keep)

    unless dry_run? do
      Enum.each(removed, &File.rm_rf!/1)
    end

    %{repo_root: repo_root, dry_run: dry_run?, kept: kept, removed: removed}
  end
end
