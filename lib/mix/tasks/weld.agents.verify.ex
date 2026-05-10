defmodule Mix.Tasks.Weld.Agents.Verify do
  use Mix.Task

  @moduledoc """
  Verify AGENTS.md dependency-source and runtime-env guidance.
  """

  @shortdoc "Verify AGENTS.md guidance"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [format: :string, repo_root: :string],
        aliases: [r: :repo_root]
      )

    repo_root = Path.expand(opts[:repo_root] || File.cwd!())

    case {Weld.AgentsVerifier.verify(repo_root), opts[:format]} do
      {{:ok, report}, "json"} ->
        Mix.shell().info(Jason.encode_to_iodata!(Map.put(report, :ok, true), pretty: true))

      {{:ok, _report}, _format} ->
        Mix.shell().info("AGENTS.md verification passed")

      {{:error, report}, "json"} ->
        Mix.shell().info(Jason.encode_to_iodata!(Map.put(report, :ok, false), pretty: true))
        Mix.raise("AGENTS.md verification failed")

      {{:error, report}, _format} ->
        report.violations
        |> Enum.map_join("\n", &"#{&1.code}: #{&1.message}")
        |> Mix.raise()
    end
  after
    Mix.Task.reenable("weld.agents.verify")
  end
end
