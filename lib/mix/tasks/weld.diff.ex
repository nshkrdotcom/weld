defmodule Mix.Tasks.Weld.Diff do
  use Mix.Task

  alias Weld.{Plan, Projector, TaskSupport}

  @moduledoc """
  Show a semantic diff between the source checkout root and a projected artifact
  (`full` or `live`): added, dropped, and modified files, plus `mix.exs` status.

  Pass `--format json` for machine-readable output.
  """

  @shortdoc "Diff source checkout against a Weld projection"

  @generated_dirs ~w(_build deps .git .weld doc)

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
        Source-only files (#{length(report.root_only)}): #{Enum.join(Enum.take(report.root_only, 10), ", ")}
        Projection-only files (#{length(report.projection_only)}): #{Enum.join(Enum.take(report.projection_only, 10), ", ")}
        Modified files (#{length(report.modified)}): #{Enum.join(Enum.take(report.modified, 10), ", ")}
        """)
    end
  after
    Mix.Task.reenable("weld.diff")
  end

  @doc false
  def diff_trees(root_path, proj_path, artifact, kind) do
    root_files = list_relative_files(root_path)
    proj_files = list_relative_files(proj_path)
    root_only = root_files -- proj_files

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
      mix_exs_differs:
        "mix.exs" in modified or "mix.exs" in projection_only or "mix.exs" in root_only,
      identical_count: identical,
      root_only: root_only,
      projection_only: Enum.sort(projection_only),
      modified: Enum.sort(modified)
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
