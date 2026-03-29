defmodule Mix.Tasks.Weld.Graph do
  use Mix.Task

  @moduledoc """
  Render the workspace graph for a weld manifest.
  """

  @shortdoc "Render the weld workspace graph"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [artifact: :string, format: :string])

    manifest_path =
      case positional do
        [path] ->
          path

        _ ->
          Mix.raise("Usage: mix weld.graph <manifest_path> [--artifact name] [--format json|dot]")
      end

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
