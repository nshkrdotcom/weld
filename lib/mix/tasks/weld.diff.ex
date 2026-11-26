defmodule Mix.Tasks.Weld.Diff do
  use Mix.Task

  alias Weld.{Plan, Projector, TaskSupport}

  @moduledoc """
  Show a semantic diff between the source checkout root and a projected artifact
  (`full` or `live`): added, dropped, and modified files, plus `mix.exs` status.

  Pass `--format json` for machine-readable output.
  """

  @shortdoc "Diff source checkout against a Weld projection"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [artifact: :string, kind: :string, format: :string])

    TaskSupport.reject_invalid!(invalid)

    usage =
      "Usage: mix weld.diff [manifest_path] [--artifact name] [--kind full|live] [--format json]"

    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)
    plan = Plan.build!(manifest_path, artifact: opts[:artifact])

    kind =
      case opts[:kind] || "full" do
        "live" -> :live
        "full" -> :full
        other -> Mix.raise("Unsupported --kind #{inspect(other)}; expected full or live")
      end

    proj_path = Projector.build_path(plan, kind)

    unless File.dir?(proj_path) do
      Mix.raise("Projection not found at #{proj_path}; run `mix weld.project` first")
    end

    report = diff_trees(plan.manifest.repo_root, proj_path, plan.artifact.id, kind)

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(report, pretty: true))

      _ ->
        Mix.shell().info("""
        Artifact: #{report.artifact} (#{report.kind})
        Root: #{report.root_path}
        Projection: #{report.projection_path}
        mix.exs differs: #{report.mix_exs_differs}
        Projection-only files (#{length(report.projection_only)}): #{Enum.join(Enum.take(report.projection_only, 10), ", ")}
        Modified files (#{length(report.modified)}): #{Enum.join(Enum.take(report.modified, 10), ", ")}
        """)
    end
  after
    Mix.Task.reenable("weld.diff")
  end

  @doc false
  def diff_trees(root_path, proj_path, artifact, kind) do
    proj_files = list_relative_files(proj_path)

    {projection_only, modified, identical} =
      Enum.reduce(proj_files, {[], [], 0}, fn rel, {only, mod, same} ->
        root_file = Path.join(root_path, rel)
        proj_file = Path.join(proj_path, rel)

        cond do
          not File.regular?(root_file) -> {[rel | only], mod, same}
          File.read!(root_file) != File.read!(proj_file) -> {only, [rel | mod], same}
          true -> {only, mod, same + 1}
        end
      end)

    %{
      artifact: artifact,
      kind: Atom.to_string(kind),
      root_path: root_path,
      projection_path: proj_path,
      mix_exs_differs: "mix.exs" in modified or "mix.exs" in projection_only,
      identical_count: identical,
      projection_only: Enum.sort(projection_only),
      modified: Enum.sort(modified)
    }
  end

  defp list_relative_files(base) do
    base
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, base))
    |> Enum.reject(&String.starts_with?(&1, ["_build/", "deps/", ".git/"]))
    |> Enum.sort()
  end
end
