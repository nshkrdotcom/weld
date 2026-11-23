defmodule Mix.Tasks.Weld.Release.Prepare do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Prepare a deterministic release bundle for the welded artifact.
  """

  @shortdoc "Prepare a welded release bundle"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [artifact: :string])

    usage = "Usage: mix weld.release.prepare [manifest_path] [--artifact name]"
    TaskSupport.reject_invalid!(invalid)
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.release_prepare!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info("Prepared release bundle in #{result.bundle_path}")
    Mix.shell().info("Project #{result.project_path}")
    Mix.shell().info("Docs #{Path.join(result.docs_path, "index.html")}")
    if result.tarball_path, do: Mix.shell().info("Archive #{result.tarball_path}")
  after
    Mix.Task.reenable("weld.release.prepare")
  end
end
