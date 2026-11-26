defmodule Mix.Tasks.Release.Stage do
  use Mix.Task

  @moduledoc """
  Stage the current verified Weld release using repo-local manifest discovery.
  """

  @shortdoc "Stage a verified Weld release for Hex publication"

  @impl Mix.Task
  def run(args) do
    Mix.Task.rerun("weld.release.stage", args)
  after
    Mix.Task.reenable("release.stage")
  end
end
