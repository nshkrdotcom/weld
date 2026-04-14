defmodule Mix.Tasks.Weld.Query do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Query direct dependencies or explanatory dependency paths.
  """

  @shortdoc "Query weld graph relationships"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [artifact: :string])

    case positional do
      ["deps", manifest_path, project_id] ->
        manifest_path
        |> Weld.query_deps!(project_id, artifact: opts[:artifact])
        |> Jason.encode_to_iodata!(pretty: true)
        |> Mix.shell().info()

      ["deps", project_id] ->
        TaskSupport.discover_manifest!(
          "Usage: mix weld.query deps [manifest_path] <project_id> [--artifact name]"
        )
        |> Weld.query_deps!(project_id, artifact: opts[:artifact])
        |> Jason.encode_to_iodata!(pretty: true)
        |> Mix.shell().info()

      ["why", manifest_path, from, to] ->
        manifest_path
        |> Weld.query_why!(from, to, artifact: opts[:artifact])
        |> Jason.encode_to_iodata!(pretty: true)
        |> Mix.shell().info()

      ["why", from, to] ->
        TaskSupport.discover_manifest!(
          "Usage: mix weld.query why [manifest_path] <from_project> <to_project> [--artifact name]"
        )
        |> Weld.query_why!(from, to, artifact: opts[:artifact])
        |> Jason.encode_to_iodata!(pretty: true)
        |> Mix.shell().info()

      _ ->
        Mix.raise("""
        Usage:
          mix weld.query deps [manifest_path] <project_id> [--artifact name]
          mix weld.query why [manifest_path] <from_project> <to_project> [--artifact name]
        """)
    end
  after
    Mix.Task.reenable("weld.query")
  end
end
