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
        digest: graph_digest(plan),
        selected_projects: plan.selected_ids,
        excluded_projects: plan.excluded_ids,
        dependency_projects: plan.dependency_ids,
        source_members: plan.source_member_ids,
        inventory_members: plan.inventory_member_ids,
        verification_projects: plan.verification_ids,
        external_projects: plan.artifact.external_projects,
        edges: graph_edges(plan),
        violations: Enum.map(plan.violations, &serialize_violation/1)
      },
      source: %{
        inventory: plan.source_inventory,
        structural_inputs: plan.structural_inputs,
        target_basis:
          if(plan.artifact.mode == :monolith and is_nil(plan.monolith_plan),
            do: :unresolved,
            else: :projection
          ),
        output_inventory: plan.output_inventory
      },
      projection: portable_projection(projection, root),
      verification: portable_value(verification_results, root)
    }
  end

  @spec encode!(map()) :: String.t()
  def encode!(lockfile) do
    lockfile
    |> ordered_json()
    |> Jason.encode_to_iodata!(pretty: true)
    |> IO.iodata_to_binary()
  end

  defp ordered_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), ordered_json(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered_json(value) when is_list(value), do: Enum.map(value, &ordered_json/1)
  defp ordered_json(value), do: value

  defp graph_digest(plan) do
    dependencies =
      Enum.map(plan.external_deps, fn dep ->
        {dep.app, dep.requirement, Enum.sort(dep.opts), dep.kind}
      end)

    input = {
      graph_edges(plan),
      plan.dependency_ids,
      plan.source_member_ids,
      plan.inventory_member_ids,
      plan.verification_ids,
      plan.artifact.external_projects,
      dependencies,
      plan.source_inventory,
      plan.output_inventory,
      plan.structural_inputs
    }

    input |> :erlang.term_to_binary() |> Hash.sha256_binary()
  end

  defp graph_edges(plan) do
    (Graph.edges(plan.graph) ++ plan.externalized_edges)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.from, &1.to, &1.kind, &1.app})
    |> Enum.map(&serialize_edge(&1, plan.externalized_edges))
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

  defp serialize_edge(edge, externalized_edges) do
    %{
      from: edge.from,
      to: edge.to,
      app: edge.app,
      kind: edge.kind,
      requirement: edge.requirement,
      externalized: edge in externalized_edges
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
