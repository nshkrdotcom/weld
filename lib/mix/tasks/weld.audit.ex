defmodule Mix.Tasks.Weld.Audit do
  use Mix.Task

  @moduledoc """
  Audit a projection manifest for strict bundle compatibility risks.
  """

  @shortdoc "Audit a projection manifest for bundle compatibility"

  @impl Mix.Task
  def run(args) do
    manifest_path =
      case args do
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.audit <manifest_path>")
      end

    report = Weld.audit!(manifest_path)
    Mix.shell().info("Audit completed with #{length(report.findings)} finding(s)")
  after
    Mix.Task.reenable("weld.audit")
  end
end
