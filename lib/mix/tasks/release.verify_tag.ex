defmodule Mix.Tasks.Release.VerifyTag do
  use Mix.Task

  @moduledoc """
  Verify a Weld release tag receipt using repo-local manifest discovery.
  """

  @shortdoc "Verify a Weld release tag receipt"

  @impl Mix.Task
  def run(args) do
    Mix.Task.rerun("weld.release.verify_tag", args)
  after
    Mix.Task.reenable("release.verify_tag")
  end
end
