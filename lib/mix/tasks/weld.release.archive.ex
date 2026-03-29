defmodule Mix.Tasks.Weld.Release.Archive do
  use Mix.Task

  @moduledoc """
  Archive a previously prepared welded release bundle.
  """

  @shortdoc "Archive a welded release bundle"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [artifact: :string])

    manifest_path =
      case positional do
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.release.archive <manifest_path> [--artifact name]")
      end

    result = Weld.release_archive!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info("Archived release bundle in #{result.archive_path}")
  after
    Mix.Task.reenable("weld.release.archive")
  end
end
