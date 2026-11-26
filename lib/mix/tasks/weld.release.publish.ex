defmodule Mix.Tasks.Weld.Release.Publish do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Stage an isolated workspace for a verified release bundle, confirm a local
  Hex rebuild matches the prepared tarball SHA-256, and hand off interactively
  to `mix hex.publish`.
  """

  @shortdoc "Publish a verified Weld release interactively via Hex"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          artifact: :string,
          identity: :string,
          tag: :string,
          allow_stale: :boolean,
          dry_run: :boolean
        ]
      )

    usage =
      "Usage: mix weld.release.publish [manifest_path] [--artifact name] [--identity sha] [--tag tag] [--allow-stale] [--dry-run]"

    TaskSupport.reject_invalid!(invalid)
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.release_publish!(manifest_path, opts)

    Enum.each(result.warnings, fn warning ->
      Mix.shell().error("Warning: #{warning}")
    end)

    unless result.completed? do
      Mix.raise("mix hex.publish exited with status #{result.exit_status}; archive step skipped")
    end

    if opts[:dry_run] do
      Mix.shell().info(
        "Hex dry run passed for #{result.package} #{result.version} (#{result.identity})"
      )
    else
      next =
        TaskSupport.release_command("archive", manifest_path, result.artifact, result.identity)

      Mix.shell().info(
        "Hex publish exited 0 for #{result.package} #{result.version} (#{result.identity})"
      )

      Mix.shell().info("After Hex confirms publication: #{next}")
    end

    Mix.shell().info("Expected archive SHA-256: #{result.archive_sha256}")
  after
    Mix.Task.reenable("weld.release.publish")
  end
end
