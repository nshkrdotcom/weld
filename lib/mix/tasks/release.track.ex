defmodule Mix.Tasks.Release.Track do
  use Mix.Task

  @moduledoc """
  Track a prepared welded release bundle using repo-local manifest discovery.
  """

  @shortdoc "Track a welded release bundle"

  @impl Mix.Task
  def run(args) do
    Mix.Task.rerun("weld.release.track", args)
  after
    Mix.Task.reenable("release.track")
  end
end
