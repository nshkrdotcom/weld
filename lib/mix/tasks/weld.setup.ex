defmodule Mix.Tasks.Weld.Setup do
  use Mix.Task

  alias Weld.{Manifest, Output, TaskSupport}

  @shortdoc "Initialize checkout-root Weld output and its ignore rule"
  @moduledoc """
  Initializes the source checkout's generated output directory and normalizes
  the dedicated ignore rule. Review and commit any change to `.gitignore` before
  preparing a clean release.
  """

  @impl Mix.Task
  def run(args) do
    {_opts, positional, invalid} = OptionParser.parse(args, strict: [])
    TaskSupport.reject_invalid!(invalid)

    manifest =
      TaskSupport.resolve_manifest_path!(positional, "Usage: mix weld.setup [manifest_path]")

    root = Manifest.load!(manifest).repo_root
    Output.with_lock(root, fn -> Mix.shell().info("Initialized #{Output.path(root, [])}") end)
  after
    Mix.Task.reenable("weld.setup")
  end
end
