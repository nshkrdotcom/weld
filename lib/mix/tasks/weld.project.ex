defmodule Mix.Tasks.Weld.Project do
  use Mix.Task

  @moduledoc """
  Generate the welded artifact for a manifest and selected artifact.
  """

  @shortdoc "Project the welded Mix artifact"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [artifact: :string])

    manifest_path =
      case positional do
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.project <manifest_path> [--artifact name]")
      end

    result = Weld.project!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info("Projected artifact in #{result.build_path}")
  after
    Mix.Task.reenable("weld.project")
  end
end
