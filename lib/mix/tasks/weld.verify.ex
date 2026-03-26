defmodule Mix.Tasks.Weld.Verify do
  use Mix.Task

  @moduledoc """
  Audit, build, and verify a generated package projection end to end.
  """

  @shortdoc "Audit, build, and verify a generated package projection"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [dist_root: :string])

    manifest_path =
      case positional do
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.verify <manifest_path> [--dist-root path]")
      end

    %{build_path: build_path} = Weld.verify!(manifest_path, dist_root: opts[:dist_root])
    Mix.shell().info("Verified projection in #{build_path}")
  after
    Mix.Task.reenable("weld.verify")
  end
end
