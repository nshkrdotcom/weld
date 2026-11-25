defmodule Mix.Tasks.Weld.Release.Archive do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Archive a previously prepared welded release bundle.
  """

  @shortdoc "Archive a welded release bundle"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [artifact: :string, all: :boolean, identity: :string])

    usage =
      "Usage: mix weld.release.archive [manifest_path] [--artifact name | --all] [--identity sha]"

    TaskSupport.reject_invalid!(invalid)
    if opts[:artifact] && opts[:all], do: Mix.raise("Pass either --artifact or --all, not both")
    if opts[:all] && opts[:identity], do: Mix.raise("--identity cannot be combined with --all")
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    if opts[:all] do
      TaskSupport.each_release_artifact!(manifest_path, fn id ->
        result = Weld.release_archive!(manifest_path, artifact: id)
        Mix.shell().info("Archived #{id} (#{result.identity}) in #{result.archive_path}")
      end)
    else
      result =
        Weld.release_archive!(manifest_path,
          artifact: opts[:artifact],
          identity: opts[:identity]
        )

      Mix.shell().info("Archived release bundle in #{result.archive_path}")
    end
  after
    Mix.Task.reenable("weld.release.archive")
  end
end
