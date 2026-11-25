defmodule Mix.Tasks.Weld.Release.Stage do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Stage the current verified release in a writable checkout-local publish workspace.

  Prints the path of the staged Mix project.
  """

  @shortdoc "Stage a verified release for Hex publication"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [artifact: :string])
    usage = "Usage: mix weld.release.stage [manifest_path] [--artifact name]"
    TaskSupport.reject_invalid!(invalid)
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.release_stage!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info(result.project_path)
  after
    Mix.Task.reenable("weld.release.stage")
  end
end
