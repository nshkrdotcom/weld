defmodule Mix.Tasks.Weld.Ecosystem.Report do
  use Mix.Task

  @moduledoc """
  Build dependency-source ecosystem reports for a repo list.
  """

  @shortdoc "Build ecosystem dependency-source reports"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [format: :string])

    repos_path =
      case positional do
        [path] -> path
        _ -> Mix.raise("Usage: mix weld.ecosystem.report repos.exs [--format json]")
      end

    {:ok, report} = Weld.EcosystemReport.build(repos_path)

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(Map.put(report, :ok, true), pretty: true))

      _format ->
        Mix.shell().info("Repos: #{length(report.graph.nodes)}")
    end
  after
    Mix.Task.reenable("weld.ecosystem.report")
  end
end
