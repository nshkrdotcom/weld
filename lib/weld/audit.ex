defmodule Weld.Audit do
  @moduledoc """
  Scans selected source files for app-identity-sensitive patterns.
  """

  alias Weld.Manifest
  alias Weld.ProjectGraph

  defmodule Report do
    @moduledoc """
    Structured audit output for a manifest scan.
    """

    @enforce_keys [:manifest, :findings]
    defstruct @enforce_keys

    @type finding :: %{
            pattern: String.t(),
            file: Path.t(),
            line: pos_integer()
          }

    @type t :: %__MODULE__{
            manifest: Weld.Manifest.t(),
            findings: [finding()]
          }
  end

  @patterns [
    "Application.get_env",
    "Application.fetch_env!",
    "Application.compile_env",
    "Application.spec",
    "Application.app_dir",
    "Application.ensure_all_started",
    "mod:"
  ]

  @spec scan!(Manifest.t()) :: Report.t()
  def scan!(%Manifest{} = manifest) do
    graph = ProjectGraph.load!(manifest)

    findings =
      graph.projects
      |> Map.values()
      |> Enum.flat_map(&project_findings/1)
      |> Enum.sort_by(fn finding -> {finding.file, finding.line, finding.pattern} end)

    %Report{manifest: manifest, findings: findings}
  end

  defp project_findings(project) do
    project.copy_dirs
    |> Enum.flat_map(fn dir ->
      project.abs_path
      |> Path.join(dir)
      |> scan_dir()
    end)
  end

  defp scan_dir(path) do
    if File.dir?(path) do
      path
      |> File.ls!()
      |> Enum.sort()
      |> Enum.flat_map(fn child -> scan_dir(Path.join(path, child)) end)
    else
      scan_file(path)
    end
  end

  defp scan_file(path) do
    if Path.extname(path) in [".ex", ".exs", ".erl", ".hrl"] do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_number} -> findings_for_line(path, line, line_number) end)
    else
      []
    end
  end

  defp findings_for_line(path, line, line_number) do
    Enum.reduce(@patterns, [], fn pattern, findings ->
      if String.contains?(line, pattern) do
        [%{pattern: pattern, file: path, line: line_number} | findings]
      else
        findings
      end
    end)
    |> Enum.reverse()
  end
end
