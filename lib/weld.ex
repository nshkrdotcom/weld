defmodule Weld do
  @moduledoc """
  Graph-native package publication tooling for Elixir monorepos.
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
            selected: project.id in plan.selected_ids
          }
        end),
      edges:
        plan.graph
        |> Graph.edges()
        |> Enum.map(fn edge ->
          %{from: edge.from, to: edge.to, kind: edge.kind, app: edge.app}
        end)
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
        plan.graph
        |> Graph.edges()
        |> Enum.filter(&(&1.from == project_id))
        |> Enum.map(fn edge ->
          %{to: edge.to, kind: edge.kind, app: edge.app}
        end),
      external:
        plan.graph
        |> Graph.external_deps(project_id)
        |> Enum.map(fn dep ->
          %{app: dep.app, kind: dep.kind, requirement: dep.requirement}
        end)
    }
  end

  @spec query_why!(Path.t(), String.t(), String.t(), keyword()) :: map()
  def query_why!(manifest_path, from, to, opts \\ []) do
    plan = Plan.build!(manifest_path, opts)

    %{
      from: from,
      to: to,
      path:
        case Graph.path(plan.graph, from, to, :package) do
          {:ok, path} -> path
          :no_path -> []
        end
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
    manifest_path
    |> Plan.build!(opts)
    |> Projector.project!()
  end

  @spec verify!(Path.t(), keyword()) :: map()
  def verify!(manifest_path, opts \\ []) do
    manifest_path
    |> Plan.build!(opts)
    |> Verifier.verify!()
  end

  @spec release_prepare!(Path.t(), keyword()) :: map()
  def release_prepare!(manifest_path, opts \\ []) do
    manifest_path
    |> Plan.build!(opts)
    |> Release.prepare!()
  end

  @spec release_bundle_path!(Path.t(), keyword()) :: Path.t()
  def release_bundle_path!(manifest_path, opts \\ []) do
    manifest_path
    |> Plan.build!(opts)
    |> Release.bundle_path()
  end

  @spec release_archive!(Path.t(), keyword()) :: map()
  def release_archive!(manifest_path, opts \\ []) do
    manifest_path
    |> Plan.build!(opts)
    |> Release.archive!()
  end

  @spec release_track!(Path.t(), keyword()) :: map()
  def release_track!(manifest_path, opts \\ []) do
    manifest_path
    |> Plan.build!(opts)
    |> Release.track!(opts)
  end

  defp classify(plan, classification) do
    plan.workspace
    |> Weld.Workspace.projects()
    |> Enum.filter(&(&1.classification == classification))
    |> Enum.map(& &1.id)
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
