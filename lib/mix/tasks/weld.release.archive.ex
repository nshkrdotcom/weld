defmodule Mix.Tasks.Weld.Release.Archive do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Archive a previously prepared welded release bundle.
  """

  @shortdoc "Archive a welded release bundle"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [artifact: :string])

    usage = "Usage: mix weld.release.archive [manifest_path] [--artifact name]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.release_archive!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info("Archived release bundle in #{result.archive_path}")
  after
    Mix.Task.reenable("weld.release.archive")
  end
end
