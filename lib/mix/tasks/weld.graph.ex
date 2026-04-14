defmodule Mix.Tasks.Weld.Graph do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Render the workspace graph for a weld manifest.
  """

  @shortdoc "Render the weld workspace graph"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [artifact: :string, format: :string])

    usage = "Usage: mix weld.graph [manifest_path] [--artifact name] [--format json|dot]"
    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    case opts[:format] do
      "json" ->
        manifest_path
        |> Weld.graph!(artifact: opts[:artifact])
        |> Jason.encode_to_iodata!(pretty: true)
        |> Mix.shell().info()

      "dot" ->
        Mix.shell().info(Weld.graph_dot!(manifest_path, artifact: opts[:artifact]))

      _ ->
        result = Weld.graph!(manifest_path, artifact: opts[:artifact])

        result.edges
        |> Enum.map_join("\n", fn edge ->
          "#{edge.from} --#{edge.kind}/#{edge.app}--> #{edge.to}"
        end)
        |> Mix.shell().info()
    end
  after
    Mix.Task.reenable("weld.graph")
  end
end
