defmodule Weld.Plan.Boundary do
  @moduledoc false

  alias Weld.{Graph, Violation}
  alias Weld.Graph.Edge

  @transport_opts [:path, :git, :github, :branch, :tag, :ref, :subdir, :submodules, :sparse]

  def build(workspace, artifact, seed_ids) do
    targets = artifact.external_projects
    graph = cut_edges(workspace.graph, targets)
    reachable = Graph.reachable_from(graph, seed_ids, :all)

    edges =
      (Graph.edges(workspace.graph) ++ scm_edges(workspace, targets))
      |> Enum.filter(&(&1.from in reachable and &1.to in targets))
      |> Enum.sort_by(&{&1.from, &1.to, &1.kind, &1.app})

    violations = declaration_violations(workspace, targets, seed_ids, edges)

    {graph, violations} =
      Enum.reduce(edges, {graph, violations}, &add_dependency(&1, &2, workspace, artifact))

    {graph, edges, violations}
  end

  defp cut_edges(graph, []), do: graph
  defp cut_edges(graph, targets), do: Graph.filter_edges(graph, &(&1.to not in targets))

  defp scm_edges(workspace, targets) do
    targets_by_app =
      workspace.projects
      |> Map.take(targets)
      |> Map.new(fn {id, project} -> {project.app, id} end)

    for project <- workspace.projects |> Map.values() |> Enum.sort_by(& &1.id),
        dep <- project.deps,
        dep.opts[:git] || dep.opts[:github],
        target = targets_by_app[dep.app] do
      dependency = Graph.external_dependency(dep)

      %Edge{
        from: project.id,
        to: target,
        app: dep.app,
        kind: dependency.kind,
        opts: dep.opts,
        requirement: dep.requirement
      }
    end
  end

  defp declaration_violations(workspace, targets, seed_ids, edges) do
    Enum.flat_map(targets, fn id ->
      cond do
        not Map.has_key?(workspace.projects, id) ->
          [
            violation(
              :unknown_external_project,
              id,
              "external_projects project was not discovered"
            )
          ]

        id in seed_ids ->
          [
            violation(
              :external_project_selected,
              id,
              "external_projects overlaps roots, include or optional features"
            )
          ]

        Enum.any?(edges, &(&1.to == id)) ->
          []

        true ->
          [
            violation(
              :unused_external_project,
              id,
              "external_projects has no applicable dependency edge"
            )
          ]
      end
    end)
  end

  defp add_dependency(edge, {graph, violations}, workspace, artifact) do
    project = Map.fetch!(workspace.projects, edge.to)
    policy = workspace.manifest.dependencies[edge.app]

    with {:ok, requirement, opts} <- boundary_dependency(edge, policy, artifact),
         :ok <- validate_package(edge, project, requirement, opts, policy) do
      dep = dependency(edge, requirement, opts)
      {Graph.add_external_dep(graph, edge.from, Graph.external_dependency(dep)), violations}
    else
      {:error, message} ->
        error =
          Violation.new(:incompatible_external_project, message,
            project: edge.from,
            dependency: edge.app,
            details: %{target: edge.to}
          )

        {graph, [error | violations]}
    end
  end

  defp boundary_dependency(edge, _policy, %{mode: :source_project}) do
    if transport?(edge.opts) or not is_binary(edge.requirement) do
      {:error, "a source_project external boundary requires its native versioned Hex dependency"}
    else
      {:ok, edge.requirement, edge.opts}
    end
  end

  defp boundary_dependency(edge, nil, _artifact) do
    if transport?(edge.opts) or not is_binary(edge.requirement) do
      {:error, "a local/Git package boundary needs a canonical dependency declaration"}
    else
      {:ok, edge.requirement, edge.opts}
    end
  end

  defp boundary_dependency(edge, policy, artifact) do
    source_opts = Keyword.drop(edge.opts, @transport_opts ++ [:override])
    opts = Keyword.merge(source_opts, policy.opts)
    scope = [:runtime, :only, :optional, :targets]

    cond do
      Enum.any?(scope, &scope_changed?(&1, source_opts, opts)) ->
        {:error, "canonical dependency options conflict with the native dependency scope"}

      is_binary(policy.requirement) and not transport?(opts) ->
        {:ok, policy.requirement, opts}

      not artifact.verify.hex_build and scm?(opts) ->
        {:ok, policy.requirement, opts}

      true ->
        {:error, "a package boundary needs a canonical versioned Hex dependency for hex_build"}
    end
  end

  defp scope_changed?(:runtime, source, canonical),
    do: Keyword.get(source, :runtime, true) != Keyword.get(canonical, :runtime, true)

  defp scope_changed?(:optional, source, canonical),
    do: Keyword.get(source, :optional, false) != Keyword.get(canonical, :optional, false)

  defp scope_changed?(key, source, canonical) when key in [:only, :targets],
    do: Enum.sort(List.wrap(source[key])) != Enum.sort(List.wrap(canonical[key]))

  defp validate_package(edge, project, requirement, opts, policy) do
    cond do
      not external_identity_matches?(edge, project, opts) ->
        {:error, "external dependency identity does not match the discovered package"}

      not native_identity_matches?(edge, project) ->
        {:error, "native dependency identity does not match the discovered package"}

      not canonical_identity_matches?(project, policy) ->
        {:error, "canonical dependency identity does not match the discovered package"}

      not requirements_match?(edge, project, requirement, policy) ->
        {:error, "external dependency requirement conflicts with the discovered package version"}

      true ->
        :ok
    end
  end

  defp external_identity_matches?(edge, project, opts) do
    edge.app == project.app and to_string(opts[:hex] || edge.app) == project.package_name
  end

  defp native_identity_matches?(edge, project) do
    transport?(edge.opts) or to_string(edge.opts[:hex] || edge.app) == project.package_name
  end

  defp canonical_identity_matches?(project, policy) do
    policy_package = if policy, do: policy.opts[:hex]
    if policy_package, do: to_string(policy_package) == project.package_name, else: true
  end

  defp requirements_match?(edge, project, requirement, policy) do
    policy_requirement = if policy, do: policy.requirement

    Enum.all?(
      [edge.requirement, requirement, policy_requirement],
      &version_matches?(project.version, &1)
    )
  end

  defp dependency(edge, requirement, opts) do
    original =
      case {requirement, opts} do
        {nil, _opts} -> {edge.app, opts}
        {requirement, []} -> {edge.app, requirement}
        {requirement, _opts} -> {edge.app, requirement, opts}
      end

    %{app: edge.app, requirement: requirement, opts: opts, original: original}
  end

  defp version_matches?(_version, nil), do: true

  defp version_matches?(version, requirement)
       when is_binary(version) and is_binary(requirement) do
    with {:ok, version} <- Version.parse(version),
         {:ok, requirement} <- Version.parse_requirement(requirement) do
      Version.match?(version, requirement)
    else
      :error -> false
    end
  end

  defp version_matches?(_version, _requirement), do: false

  defp transport?(opts), do: is_binary(opts[:path]) or scm?(opts)
  defp scm?(opts), do: is_binary(opts[:git]) or is_binary(opts[:github])

  defp violation(code, id, message), do: Violation.new(code, message, project: id)
end
