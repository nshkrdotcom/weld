defmodule Weld.Lockfile do
  @moduledoc """
  Stable JSON lock/report artifact for projected builds.
  """

  alias Weld.Graph
  alias Weld.Hash
  alias Weld.Plan

  @spec build(Plan.t(), map(), [map()]) :: map()
  def build(%Plan{} = plan, projection, verification_results) do
    %{
      manifest: %{
        path: plan.manifest.manifest_path,
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
        root: plan.manifest.repo_root,
        project_count: map_size(plan.workspace.projects),
        discovery: plan.workspace.discovery
      },
      graph: %{
        digest: graph_digest(plan.graph),
        selected_projects: plan.selected_ids,
        excluded_projects: plan.excluded_ids,
        edges: Enum.map(Graph.edges(plan.graph), &serialize_edge/1),
        violations: Enum.map(plan.violations, &serialize_violation/1)
      },
      projection: projection,
      verification: verification_results
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
