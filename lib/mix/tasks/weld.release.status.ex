defmodule Mix.Tasks.Weld.Release.Status do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Show read-only release status for one or all artifacts in a Weld manifest.
  """

  @shortdoc "Show prepared release status for Weld artifacts"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [artifact: :string, all: :boolean, identity: :string, format: :string]
      )

    usage =
      "Usage: mix weld.release.status [manifest_path] [--artifact name | --all] [--identity sha] [--format json]"

    TaskSupport.reject_invalid!(invalid)
    if opts[:artifact] && opts[:all], do: Mix.raise("Pass either --artifact or --all, not both")
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.release_status!(manifest_path, opts)

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(result, pretty: true))

      _ ->
        result
        |> List.wrap()
        |> Enum.each(&print_status/1)
    end
  after
    Mix.Task.reenable("weld.release.status")
  end

  defp print_status(entry) do
    reasons =
      case entry.reasons do
        [] -> ""
        list -> " (#{Enum.map_join(list, ", ", &Atom.to_string/1)})"
      end

    projection =
      if entry.projection.exists do
        sync = if entry.projection.matches_identity, do: "matches", else: "differs"
        "#{entry.projection.branch} [local, #{sync}]"
      else
        "#{entry.projection.branch} [local, absent]"
      end

    Mix.shell().info("""
    Artifact: #{entry.artifact} (#{entry.package} #{entry.version})
    State: #{entry.state}#{reasons}
    Identity: #{entry.identity || "none"}
    Archive SHA-256: #{entry.archive_sha256 || "none"}
    Publish workspace: #{entry.publish_workspace}
    Archived: #{entry.archived}
    Projection: #{projection}
    """)

    Enum.each(entry.warnings, fn warning ->
      Mix.shell().error("Warning: #{warning}")
    end)
  end
end
