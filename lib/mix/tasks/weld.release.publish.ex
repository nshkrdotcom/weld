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
          allow_stale: :boolean
        ]
      )

    usage =
      "Usage: mix weld.release.publish [manifest_path] [--artifact name] [--identity sha] [--tag tag] [--allow-stale]"

    TaskSupport.reject_invalid!(invalid)
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.release_publish!(manifest_path, opts)

    Enum.each(result.warnings, fn warning ->
      Mix.shell().error("Warning: #{warning}")
    end)

    if result.published? do
      artifact_flag = if opts[:artifact], do: " --artifact #{opts[:artifact]}", else: ""

      Mix.shell().info(
        "Hex publish exited 0 for #{result.package} #{result.version} (#{result.identity})"
      )

      Mix.shell().info("Expected archive SHA-256: #{result.archive_sha256}")

      Mix.shell().info("Next: mix release.archive#{artifact_flag} --identity #{result.identity}")
    else
      Mix.raise("mix hex.publish exited with status #{result.exit_status}; archive step skipped")
    end
  after
    Mix.Task.reenable("weld.release.publish")
  end
end
