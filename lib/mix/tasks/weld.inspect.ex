defmodule Mix.Tasks.Weld.Inspect do
  use Mix.Task

  @moduledoc """
  Inspect a weld manifest, discovered workspace, and selected artifact.
  """

  @shortdoc "Inspect a weld manifest and selected artifact"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [artifact: :string, format: :string])

    manifest_path =
      case positional do
        [path] ->
          path

        _ ->
          Mix.raise("Usage: mix weld.inspect <manifest_path> [--artifact name] [--format json]")
      end

    result = Weld.inspect!(manifest_path, artifact: opts[:artifact])

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(result, pretty: true))

      _ ->
        Mix.shell().info("""
        Artifact: #{result.manifest.artifact}
        Repo root: #{result.manifest.repo_root}
        Discovery: #{result.discovery.source}
        Selected: #{Enum.join(result.artifact.selected_projects, ", ")}
        Excluded: #{Enum.join(result.artifact.excluded_projects, ", ")}
        Violations: #{length(result.violations)}
        """)
    end
  after
    Mix.Task.reenable("weld.inspect")
  end
end
