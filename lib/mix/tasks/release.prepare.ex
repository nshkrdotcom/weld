defmodule Mix.Tasks.Release.Prepare do
  use Mix.Task

  @moduledoc """
  Prepare a welded release bundle using repo-local manifest discovery.
  """

  @shortdoc "Prepare a welded release bundle"

  @impl Mix.Task
  def run(args) do
    Mix.Task.rerun("weld.release.prepare", args)
  after
    Mix.Task.reenable("release.prepare")
  end
end
