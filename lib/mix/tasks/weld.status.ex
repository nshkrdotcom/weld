defmodule Mix.Tasks.Weld.Status do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Single entry point for agents and humans: shows artifact release status,
  projection freshness, and suggested next command. Delegates to
  `Weld.release_status!/2` and supports `--format json`.
  """

  @shortdoc "Show unified Weld status for one or all artifacts"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [artifact: :string, all: :boolean, format: :string])

    TaskSupport.reject_invalid!(invalid)
    usage = "Usage: mix weld.status [manifest_path] [--artifact name | --all] [--format json]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)
    entries = manifest_path |> Weld.release_status!(opts) |> List.wrap()

    enriched =
      Enum.map(entries, fn e ->
        Map.put(e, :next_command, next_command(e))
      end)

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(enriched, pretty: true))

      _ ->
        for e <- enriched do
          Mix.shell().info("""
          Artifact: #{e.artifact} (#{e.package} #{e.version})
          State: #{e.state}
          Next: #{e.next_command}
          """)
        end
    end
  after
    Mix.Task.reenable("weld.status")
  end

  defp next_command(%{state: :ready} = entry) do
    task = if entry.has_tarball, do: "publish", else: "track"
    TaskSupport.release_command(task, entry.manifest_path, entry.artifact, entry.identity)
  end

  defp next_command(entry) do
    "mix release.prepare #{TaskSupport.shell_arg(entry.manifest_path)} " <>
      "--artifact #{TaskSupport.shell_arg(entry.artifact)}"
  end
end
