defmodule Weld do
  @moduledoc """
  Deterministic package projection, verification, and release-bundle tooling for
  Elixir workspaces and source-root Mix projects.

  `Weld` resolves a repo-local manifest (`build_support/weld.exs`,
  `build_support/weld_contract.exs`, or `packaging/weld/*.exs`), builds the
  workspace dependency graph, projects standalone Mix candidates under
  `<checkout_root>/.weld/` (`:package_projection`, `:monolith`, or
  `:source_project`), verifies generated packages with standard Mix gates, and
  prepares content-addressed release bundles and optional `projection/*` branch
  snapshots.
  """

  @version Mix.Project.config()[:version]

  alias Weld.Affected
  alias Weld.Graph
  alias Weld.Plan
  alias Weld.Projector
  alias Weld.Release
  alias Weld.Verifier

  @spec version() :: String.t()
  def version, do: @version

  @spec inspect!(Path.t(), keyword()) :: map()
  def inspect!(manifest_path, opts \\ []) do
    plan = Plan.build!(manifest_path, opts)

    %{
      manifest: %{
        path: plan.manifest.manifest_path,
        repo_root: plan.manifest.repo_root,
        artifact: plan.artifact.id
      },
      discovery: plan.workspace.discovery,
      projects:
        plan.workspace
        |> Weld.Workspace.projects()
        |> Enum.map(fn project ->
          %{
            id: project.id,
            app: project.app,
            version: project.version,
            classification: project.classification,
            publication_role: project.publication_role
          }
        end),
      classifications: %{
        runtime: classify(plan, :runtime),
        tooling: classify(plan, :tooling),
        proof: classify(plan, :proof),
        ignored: classify(plan, :ignored)
      },
      artifact: %{
        roots: plan.artifact.roots,
        include: plan.artifact.include,
        selected_projects: plan.selected_ids,
        excluded_projects: plan.excluded_ids,
        dependency_projects: plan.dependency_ids,
        source_members: plan.source_member_ids,
        inventory_members: plan.inventory_member_ids,
        verification_projects: plan.verification_ids,
        external_projects: plan.artifact.external_projects,
        externalized_edges: Enum.map(plan.externalized_edges, &report_edge(plan, &1)),
        structural_inputs: plan.structural_inputs,
        source_inventory: plan.source_inventory,
        output_inventory: plan.output_inventory,
        source_target_basis: source_target_basis(plan),
        external_deps: Enum.map(plan.external_deps, &Atom.to_string(&1.app))
      },
      violations: Enum.map(plan.violations, &serialize_violation/1)
    }
  end

  @spec graph!(Path.t(), keyword()) :: map()
  def graph!(manifest_path, opts \\ []) do
    plan = Plan.build!(manifest_path, opts)

    %{
      nodes:
        plan.workspace
        |> Weld.Workspace.projects()
        |> Enum.map(fn project ->
          %{
            id: project.id,
            classification: project.classification,
            selected: project.id in plan.selected_ids,
            membership: membership(plan, project.id)
          }
        end),
      edges: Enum.map(reported_edges(plan), &report_edge(plan, &1))
    }
  end

  @spec graph_dot!(Path.t(), keyword()) :: String.t()
  def graph_dot!(manifest_path, opts \\ []) do
    {:ok, dot} =
      manifest_path
      |> Plan.build!(opts)
      |> then(fn plan -> Graph.subgraph(plan.graph, :all) end)
      |> Multigraph.to_dot()

    dot
  end

  @spec query_deps!(Path.t(), String.t(), keyword()) :: map()
  def query_deps!(manifest_path, project_id, opts \\ []) do
    plan = Plan.build!(manifest_path, opts)

    %{
      project: project_id,
      outgoing:
        plan
        |> reported_edges()
        |> Enum.filter(&(&1.from == project_id))
        |> Enum.map(fn edge ->
          report_edge(plan, edge) |> Map.delete(:from)
        end),
      external:
        plan.artifact_graph
        |> Graph.external_deps(project_id)
        |> Enum.map(fn dep ->
          %{app: dep.app, kind: dep.kind, requirement: dep.requirement}
        end),
      membership: membership(plan, project_id)
    }
  end

  @spec query_why!(Path.t(), String.t(), String.t(), keyword()) :: map()
  def query_why!(manifest_path, from, to, opts \\ []) do
    plan = Plan.build!(manifest_path, opts)

    %{
      from: from,
      to: to,
      path: dependency_path(plan.graph, from, to),
      artifact_path: dependency_path(plan.artifact_graph, from, to),
      source_membership: from in plan.artifact.roots and to in plan.source_member_ids,
      externalized_edges:
        plan.externalized_edges
        |> Enum.filter(&(&1.from == from and &1.to == to))
        |> Enum.map(&report_edge(plan, &1))
    }
  end

  @spec affected!(Path.t(), keyword()) :: map()
  def affected!(manifest_path, opts) do
    manifest_path
    |> Plan.build!(opts)
    |> Affected.run!(opts)
  end

  @spec project!(Path.t(), keyword()) :: map()
  def project!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Projector.project!(&1, opts))
  end

  @spec verify!(Path.t(), keyword()) :: map()
  def verify!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Verifier.verify!/1)
  end

  @spec release_prepare!(Path.t(), keyword()) :: map()
  def release_prepare!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Release.prepare!(&1, opts))
  end

  @spec release_bundle_path!(Path.t(), keyword()) :: Path.t()
  def release_bundle_path!(manifest_path, opts \\ []) do
    manifest_path
    |> Plan.build!(opts)
    |> Release.bundle_path()
  end

  @spec release_archive!(Path.t(), keyword()) :: map()
  def release_archive!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Release.archive!/1)
  end

  @spec release_track!(Path.t(), keyword()) :: map()
  def release_track!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Release.track!(&1, opts))
  end

  defp with_plan!(manifest_path, opts, fun) do
    root = Weld.Manifest.load!(manifest_path).repo_root

    Weld.Output.with_lock(root, fn ->
      plan = Plan.build!(manifest_path, opts)

      if plan.manifest.repo_root != root,
        do: raise(Weld.Error, "manifest workspace changed while acquiring the lock")

      fun.(plan)
    end)
  end

  defp classify(plan, classification) do
    plan.workspace
    |> Weld.Workspace.projects()
    |> Enum.filter(&(&1.classification == classification))
    |> Enum.map(& &1.id)
  end

  defp dependency_path(graph, from, to) do
    case Graph.path(graph, from, to, :package) do
      {:ok, path} -> path
      :no_path -> []
    end
  end

  defp reported_edges(plan) do
    (Graph.edges(plan.graph) ++ plan.externalized_edges)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.from, &1.to, &1.kind, &1.app})
  end

  defp report_edge(plan, edge) do
    %{
      from: edge.from,
      to: edge.to,
      kind: edge.kind,
      app: edge.app,
      externalized: edge in plan.externalized_edges
    }
  end

  defp membership(plan, id) do
    for {relationship, ids} <- [
          dependency: plan.dependency_ids,
          compiled_source: plan.source_member_ids,
          verification: plan.verification_ids,
          inventory: plan.inventory_member_ids,
          external_package: plan.artifact.external_projects
        ],
        id in ids,
        do: relationship
  end

  defp source_target_basis(%Plan{artifact: %{mode: :monolith}, monolith_plan: nil}),
    do: :unresolved

  defp source_target_basis(_plan), do: :projection

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
