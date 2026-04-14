defmodule Mix.Tasks.Weld.Verify do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Generate and verify the welded artifact end to end.
  """

  @shortdoc "Verify the welded artifact"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [artifact: :string])

    usage = "Usage: mix weld.verify [manifest_path] [--artifact name]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.verify!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info("Verified artifact in #{result.build_path}")
  after
    Mix.Task.reenable("weld.verify")
  end
end
