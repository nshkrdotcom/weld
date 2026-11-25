defmodule Mix.Tasks.Release.Status do
  use Mix.Task

  @moduledoc """
  Show read-only release status using repo-local manifest discovery.
  """

  @shortdoc "Show prepared Weld release status"

  @impl Mix.Task
  def run(args) do
    Mix.Task.rerun("weld.release.status", args)
  after
    Mix.Task.reenable("release.status")
  end
end
