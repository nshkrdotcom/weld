defmodule Mix.Tasks.Weld.Project do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Generate the welded artifact for a manifest and selected artifact.
  """

  @shortdoc "Project the welded Mix artifact"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [artifact: :string])

    usage = "Usage: mix weld.project [manifest_path] [--artifact name]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.project!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info("Projected artifact in #{result.build_path}")
  after
    Mix.Task.reenable("weld.project")
  end
end
