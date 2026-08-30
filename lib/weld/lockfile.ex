defmodule Weld.Lockfile do
  @moduledoc """
  Stable JSON lock/report artifact for projected builds.
  """

  alias Weld.Graph
  alias Weld.Hash
  alias Weld.Plan

  @spec build(Plan.t(), map(), [map()]) :: map()
  def build(%Plan{} = plan, projection, verification_results) do
    root = plan.manifest.repo_root

    %{
      manifest: %{
        path: Path.relative_to(plan.manifest.manifest_path, root),
        digest: Hash.sha256_file(plan.manifest.manifest_path)
      },
      artifact: %{
        id: plan.artifact.id,
        package: %{
          name: plan.artifact.package.name,
          otp_app: plan.artifact.package.otp_app,
          version: plan.artifact.package.version
        }
      },
      workspace: %{
        root: ".",
        project_count: map_size(plan.workspace.projects),
        discovery: portable_value(plan.workspace.discovery, root)
      },
      graph: %{
        digest: graph_digest(plan.graph),
        selected_projects: plan.selected_ids,
        excluded_projects: plan.excluded_ids,
        edges: Enum.map(Graph.edges(plan.graph), &serialize_edge/1),
        violations: Enum.map(plan.violations, &serialize_violation/1)
      },
      projection: portable_projection(projection, root),
      verification: portable_value(verification_results, root)
    }
  end

  @spec encode!(map()) :: String.t()
  def encode!(lockfile) do
    lockfile
    |> Jason.encode_to_iodata!(pretty: true)
    |> IO.iodata_to_binary()
  end

  defp graph_digest(graph) do
    graph
    |> Graph.edges()
    |> Enum.map_join("\n", fn edge ->
      "#{edge.from}:#{edge.to}:#{edge.kind}:#{edge.app}"
    end)
    |> Hash.sha256_binary()
  end

  defp portable_projection(projection, root) do
    build_path = Map.get(projection, :build_path)

    projection
    |> Map.update(:copied_files, [], fn files ->
      Enum.map(files, &portable_copied_file(&1, build_path))
    end)
    |> portable_value(root)
  end

  defp portable_copied_file(path, build_path)
       when is_binary(path) and is_binary(build_path) do
    portable_path(path, build_path)
  end

  defp portable_copied_file(path, _build_path), do: path

  defp portable_value(value, root) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, portable_value(nested, root)} end)
  end

  defp portable_value(value, root) when is_list(value) do
    Enum.map(value, &portable_value(&1, root))
  end

  defp portable_value(value, root) when is_binary(value), do: portable_path(value, root)
  defp portable_value(value, _root), do: value

  defp portable_path(path, root) do
    if Path.type(path) == :absolute do
      relative = Path.relative_to(path, root)

      if relative == ".." or String.starts_with?(relative, "../"), do: path, else: relative
    else
      path
    end
  end

  defp serialize_edge(edge) do
    %{
      from: edge.from,
      to: edge.to,
      app: edge.app,
      kind: edge.kind,
      requirement: edge.requirement
    }
  end

  defp serialize_violation(violation) do
    %{
      code: violation.code,
      message: violation.message,
      project: violation.project,
      dependency: violation.dependency,
      details: violation.details
    }
  end
end
