defmodule Mix.Tasks.Weld.Open do
  use Mix.Task

  alias Weld.{Plan, Projector, TaskSupport}

  @moduledoc """
  Print the path to the projected artifact's `doc/index.html` so humans inspect
  the real projected docs instead of the root checkout's `doc/`.
  """

  @shortdoc "Print projected docs index path for an artifact"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [artifact: :string])
    TaskSupport.reject_invalid!(invalid)
    usage = "Usage: mix weld.open [manifest_path] [--artifact name]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)
    plan = Plan.build!(manifest_path, artifact: opts[:artifact])
    index = Path.join([Projector.build_path(plan, :full), "doc", "index.html"])

    if File.regular?(index) do
      Mix.shell().info(index)
    else
      Mix.raise("Projected docs not found at #{index}; build docs in the projection first")
    end
  after
    Mix.Task.reenable("weld.open")
  end
end
