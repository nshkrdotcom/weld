defmodule Mix.Tasks.Release.Publish do
  use Mix.Task

  @moduledoc """
  Publish a verified Weld release interactively via Hex using repo-local
  manifest discovery.
  """

  @shortdoc "Publish a verified Weld release via Hex"

  @impl Mix.Task
  def run(args) do
    Mix.Task.rerun("weld.release.publish", args)
  after
    Mix.Task.reenable("release.publish")
  end
end
