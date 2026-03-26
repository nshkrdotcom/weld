defmodule Mix.Tasks.Weld.Build do
  use Mix.Task

  @moduledoc """
  Build a standalone Hex package projection from a manifest file.
  """

  @shortdoc "Build a standalone Hex package projection from a manifest"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [dist_root: :string])

    manifest_path =
      case positional do
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.build <manifest_path> [--dist-root path]")
      end

    build_path = Weld.build!(manifest_path, dist_root: opts[:dist_root])
    Mix.shell().info("Built projection in #{build_path}")
  after
    Mix.Task.reenable("weld.build")
  end
end
