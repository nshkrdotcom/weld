defmodule Mix.Tasks.Weld.Release.Prepare do
  use Mix.Task

  @moduledoc """
  Prepare a deterministic release bundle for the welded artifact.
  """

  @shortdoc "Prepare a welded release bundle"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [artifact: :string])

    manifest_path =
      case positional do
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.release.prepare <manifest_path> [--artifact name]")
      end

    result = Weld.release_prepare!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info("Prepared release bundle in #{result.bundle_path}")
  after
    Mix.Task.reenable("weld.release.prepare")
  end
end
