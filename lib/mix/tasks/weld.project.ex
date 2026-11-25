defmodule Mix.Tasks.Weld.Project do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Generate the selected artifact as a portable Mix project or a live view.

  Use `--live` to link the artifact's source files into a local development
  view. Generate a full project for verification and Hex packaging.
  """

  @shortdoc "Project the welded Mix artifact"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [artifact: :string, live: :boolean, cache: :boolean])

    usage = "Usage: mix weld.project [manifest_path] [--artifact name] [--live] [--no-cache]"
    TaskSupport.reject_invalid!(invalid)
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result = Weld.project!(manifest_path, Keyword.put(opts, :no_cache, opts[:cache] == false))
    action = if result.reused?, do: "Reused projection in", else: "Projected artifact in"
    Mix.shell().info("#{action} #{result.build_path}")
  after
    Mix.Task.reenable("weld.project")
  end
end
