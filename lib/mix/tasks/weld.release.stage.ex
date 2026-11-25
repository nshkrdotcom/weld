defmodule Mix.Tasks.Weld.Release.Stage do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Stage a verified release in a writable checkout-local publish workspace.

  Prints the staged workspace summary, expected archive SHA-256, and publish
  command by default. Pass `--path-only` to print only the project directory.
  """

  @shortdoc "Stage a verified release for Hex publication"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [artifact: :string, identity: :string, fresh: :boolean, path_only: :boolean]
      )

    usage =
      "Usage: mix weld.release.stage [manifest_path] [--artifact name] [--identity sha] [--fresh] [--path-only]"

    TaskSupport.reject_invalid!(invalid)
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result =
      Weld.release_stage!(manifest_path,
        artifact: opts[:artifact],
        identity: opts[:identity],
        fresh: opts[:fresh] == true
      )

    if opts[:path_only] do
      Mix.shell().info(result.project_path)
    else
      Mix.shell().info("Staged #{result.package} #{result.version} (#{result.identity})")
      Mix.shell().info("Project #{result.project_path}")
      Mix.shell().info("Expected archive SHA-256 #{result.archive_sha256}")

      Mix.shell().info(
        "Next: cd #{result.project_path} && mix deps.get --check-locked && mix hex.publish"
      )
    end
  after
    Mix.Task.reenable("weld.release.stage")
  end
end
