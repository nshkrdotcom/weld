defmodule Weld.Commands do
  @moduledoc false

  alias Weld.Affected
  alias Weld.Graph
  alias Weld.Manifest
  alias Weld.Plan
  alias Weld.Projector
  alias Weld.Release
  alias Weld.ReleaseStatus
  alias Weld.Verifier

  @spec inspect!(Path.t(), keyword()) :: map()
  def inspect!(manifest_path, opts \\ []) do
    inspect_plan(Plan.build!(manifest_path, opts))
  end

  @doc false
  def inspect_plan(plan) do
    inventory = Weld.Plan.Inventory.portable(plan)
    %{
      artifact_id: plan.artifact.id,
      layout: %{package_projection: :components, monolith: :flat, source_project: :preserve}[plan.artifact.mode],
      plan_id: inventory["plan_id"],
      input_id: inventory["input_id"],
      compiler_id: inventory["compiler_id"],
      source_revision: Weld.Git.revision(plan.manifest.repo_root),
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

  @spec graph!(Path.t() | Manifest.t(), keyword()) :: map()
  def graph!(source, opts \\ []) do
    {workspace, plan} = graph_subject!(source, opts)
    graph_report(workspace, plan, opts[:view] || :all)
  end

  defp graph_report(workspace, plan, view) do
    %{
      view: view,
      nodes: Enum.map(Weld.Workspace.projects(workspace), fn project ->
        %{id: project.id, app: project.app, classification: project.classification,
          selected: not is_nil(plan) and project.id in plan.selected_ids,
          membership: if(plan, do: membership(plan, project.id), else: [])}
      end),
      edges: if(plan, do: Enum.map(reported_edges(plan, view), &report_edge(plan, &1)),
        else: Enum.map(Graph.scoped_edges(workspace.graph, view), &plain_edge/1)),
      external: for(project <- Weld.Workspace.projects(workspace),
        dep <- Graph.external_deps(if(plan, do: plan.artifact_graph, else: workspace.graph), project.id),
        Weld.Graph.View.allowed?(dep.kind, view),
        do: %{from: project.id, app: dep.app, kind: dep.kind, requirement: dep.requirement, opts: dep.opts}),
      violations: Enum.map(if(plan, do: plan.violations, else: Graph.violations(workspace.graph)), &serialize_violation/1)
    }
  end

  @spec graph_dot!(Path.t() | Manifest.t(), keyword()) :: String.t()
  def graph_dot!(source, opts \\ []) do
    report = graph!(source, opts)
    nodes = for node <- report.nodes, do: "  #{Jason.encode!(node.id)};\n"
    edges = for edge <- report.edges, do:
      "  #{Jason.encode!(edge.from)} -> #{Jason.encode!(edge.to)} [label=#{Jason.encode!(edge.kind |> List.wrap() |> Enum.map_join(",", &to_string/1))},style=#{if(edge.externalized, do: "dashed", else: "solid")}];\n"
    IO.iodata_to_binary(["digraph weld {\n", nodes, edges, "}\n"])
  end

  def query_deps!(source, project_id, opts \\ []) do
    {workspace, plan} = graph_subject!(source, opts)
    require_project!(workspace.graph, project_id)
    view = opts[:view] || :all
    report = graph_report(workspace, plan, view)
    graph = if plan, do: plan.artifact_graph, else: workspace.graph
    reachable = Graph.reachable_from(graph, project_id, view) -- [project_id]
    %{
      project: project_id, view: view,
      outgoing: report.edges |> Enum.filter(&(&1.from == project_id)) |> Enum.map(&Map.delete(&1, :from)),
      transitive: Enum.map(reachable, fn target -> %{project: target, path: dependency_path(graph, project_id, target, view)} end),
      external: report.external |> Enum.filter(&(&1.from == project_id)) |> Enum.map(&Map.delete(&1, :from)),
      membership: if(plan, do: membership(plan, project_id), else: [])
    }
  end

  def query_why!(source, from, to, opts \\ []) do
    {workspace, plan} = graph_subject!(source, opts)
    Enum.each([from, to], &require_project!(workspace.graph, &1))
    view = opts[:view] || :all
    actual_path = dependency_path(workspace.graph, from, to, view)
    artifact_path = dependency_path(if(plan, do: plan.artifact_graph, else: workspace.graph), from, to, view)
    path_pairs = actual_path |> Enum.chunk_every(2, 1, :discard) |> MapSet.new(&List.to_tuple/1)
    boundary_edges = if plan do
      plan.externalized_edges |> Enum.filter(&((MapSet.member?(path_pairs, {&1.from, &1.to}) or (actual_path == [] and &1.from == from and &1.to == to)) and Weld.Graph.View.allowed?(&1.kind, view)))
      |> Enum.map(&report_edge(plan, &1))
    else
      []
    end
    %{
      from: from, to: to, view: view, path: actual_path, artifact_path: artifact_path,
      reason: cond do
        artifact_path == [] and boundary_edges != [] -> :external_boundary
        actual_path == [] -> :no_dependency_path
        true -> :reachable
      end,
      source_membership: not is_nil(plan) and from in plan.artifact.roots and to in plan.source_member_ids,
      externalized_edges: boundary_edges
    }
  end

  defp graph_subject!(source, opts) do
    manifest = load_manifest(source)
    if opts[:artifact], do: Manifest.artifact!(manifest, opts[:artifact])
    workspace = Weld.Workspace.load!(manifest, opts)
    plan = if opts[:artifact], do: Plan.build_from_workspace!(manifest, workspace, opts)
    {workspace, plan}
  end

  defp require_project!(graph, id) do
    unless Map.has_key?(graph.projects, id), do: raise(Weld.Error, code: :unknown_project,
      phase: :plan, message: "unknown project #{id}")
  end

  defp plain_edge(edge), do: %{from: edge.from, to: edge.to, app: edge.app, kind: edge.kind,
    requirement: edge.requirement, opts: edge.opts, externalized: false}

  def affected!(manifest_path, opts) do
    Affected.compare!(manifest_path, opts)
  end

  @spec project!(Path.t(), keyword()) :: map()
  def project!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Projector.project!(&1, opts))
  end

  @spec verify!(Path.t(), keyword()) :: map()
  def verify!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Verifier.verify!(&1, opts))
  end

  @spec release_prepare!(Path.t(), keyword()) :: map()
  def release_prepare!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Release.prepare!(&1, opts))
  end

  @spec artifact_ids!(Path.t()) :: [String.t()]
  def artifact_ids!(manifest_path) do
    manifest_path
    |> Manifest.load!()
    |> Map.fetch!(:artifacts)
    |> Map.keys()
    |> Enum.sort()
  end

  @spec release_bundle_path!(Path.t(), keyword()) :: Path.t()
  def release_bundle_path!(manifest_path, opts \\ []) do
    manifest_path
    |> Plan.build!(opts)
    |> Release.bundle_path(opts[:identity])
  end

  @doc "Stages the verified current or pinned release for publication without changing its bundle."
  @spec release_stage!(Path.t(), keyword()) :: map()
  def release_stage!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Release.stage!(&1, opts))
  end

  @doc "Submits the frozen package and documentation archives."
  @spec release_publish!(Path.t(), keyword()) :: map()
  def release_publish!(manifest_path, opts \\ []) do
    manifest_path
    |> Plan.build!(opts)
    |> Release.publish!(opts)
  end

  @doc "Returns read-only release status for one or all artifacts."
  @spec release_status!(Path.t(), keyword()) :: map() | [map()]
  def release_status!(manifest_path, opts \\ []) do
    manifest = load_manifest(manifest_path)

    if opts[:artifact] do
      if opts[:all], do: raise(Weld.Error, "pass either --artifact or --all, not both")

      manifest
      |> Plan.build!(opts)
      |> ReleaseStatus.status(opts)
    else
      workspace = Weld.Workspace.load!(manifest)

      manifest.artifacts
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn id ->
        plan = Plan.build_from_workspace!(manifest, workspace, Keyword.put(opts, :artifact, id))
        ReleaseStatus.status(plan, opts)
      end)
    end
  end

  @doc "Verifies a Git tag's Weld receipt against its target commit and optional local evidence."
  @spec release_verify_tag!(Path.t(), String.t(), keyword()) :: ReleaseStatus.tag_result()
  def release_verify_tag!(manifest_path, tag, opts \\ []) do
    manifest = load_manifest(manifest_path)
    ReleaseStatus.verify_tag(manifest.repo_root, tag, opts)
  end

  @spec release_archive!(Path.t(), keyword()) :: map()
  def release_archive!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Release.archive!(&1, opts))
  end

  @spec release_track!(Path.t(), keyword()) :: map()
  def release_track!(manifest_path, opts \\ []) do
    with_plan!(manifest_path, opts, &Release.track!(&1, opts))
  end

  defp with_plan!(source, opts, fun), do: source |> Plan.build!(opts) |> fun.()
  defp load_manifest(%Manifest{} = manifest), do: manifest
  defp load_manifest(path), do: Manifest.load!(path)

  defp classify(plan, classification) do
    plan.workspace
    |> Weld.Workspace.projects()
    |> Enum.filter(&(&1.classification == classification))
    |> Enum.map(& &1.id)
  end

  defp dependency_path(graph, from, to, view) do
    case Graph.path(graph, from, to, view) do
      {:ok, path} -> path
      :no_path -> []
    end
  end

  defp reported_edges(plan, view) do
    (Graph.edges(plan.graph) ++ plan.externalized_edges)
    |> Enum.uniq()
    |> Enum.filter(&Graph.View.allowed?(&1.kind, view))
    |> Enum.sort_by(&{&1.from, &1.to, &1.kind, &1.app})
  end

  defp report_edge(plan, edge) do
    %{
      from: edge.from,
      to: edge.to,
      kind: edge.kind,
      app: edge.app,
      requirement: edge.requirement,
      opts: edge.opts,
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

  defp source_target_basis(%Plan{artifact: %{mode: :monolith}, layout: nil}),
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
