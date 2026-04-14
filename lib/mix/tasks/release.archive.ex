defmodule Mix.Tasks.Release.Archive do
  use Mix.Task

  @moduledoc """
  Archive a prepared welded release bundle using repo-local manifest discovery.
  """

  @shortdoc "Archive a welded release bundle"

  @impl Mix.Task
  def run(args) do
    Mix.Task.rerun("weld.release.archive", args)
  after
    Mix.Task.reenable("release.archive")
  end
end
