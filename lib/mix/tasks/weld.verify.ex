defmodule Mix.Tasks.Weld.Verify do
  use Mix.Task

  @moduledoc """
  Generate and verify the welded artifact end to end.
  """

  @shortdoc "Verify the welded artifact"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [artifact: :string])

    manifest_path =
      case positional do
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.verify <manifest_path> [--artifact name]")
      end

    result = Weld.verify!(manifest_path, artifact: opts[:artifact])
    Mix.shell().info("Verified artifact in #{result.build_path}")
  after
    Mix.Task.reenable("weld.verify")
  end
end
