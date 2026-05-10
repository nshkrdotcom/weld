defmodule Mix.Tasks.Weld.DependencySources.Verify do
  use Mix.Task

  @moduledoc """
  Verify repo-local dependency source helper and manifest files.
  """

  @shortdoc "Verify dependency source bootstrap files"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [format: :string, repo_root: :string, publish: :boolean],
        aliases: [r: :repo_root]
      )

    repo_root = Path.expand(opts[:repo_root] || File.cwd!())
    result = Weld.DependencySources.verify(repo_root, publish?: opts[:publish] == true)

    case {result, opts[:format]} do
      {{:ok, report}, "json"} ->
        Mix.shell().info(Jason.encode_to_iodata!(Map.put(report, :ok, true), pretty: true))

      {{:ok, _report}, _format} ->
        Mix.shell().info("Dependency source verification passed")

      {{:error, report}, "json"} ->
        Mix.shell().info(Jason.encode_to_iodata!(Map.put(report, :ok, false), pretty: true))
        Mix.raise("dependency source verification failed")

      {{:error, report}, _format} ->
        report.violations
        |> Enum.map_join("\n", &"#{&1.code}: #{&1.message}")
        |> Mix.raise()
    end
  after
    Mix.Task.reenable("weld.dependency_sources.verify")
  end
end
