defmodule Weld.EcosystemReport do
  @moduledoc """
  Builds dependency-source reports across a set of repos.
  """

  alias Weld.DependencySources

  def build(repos_path) do
    repos_path
    |> load_repos()
    |> build_from_repos()
  end

  defp load_repos(path) do
    {repos, _binding} = Code.eval_file(path)

    Enum.map(repos, fn repo ->
      repo = Map.new(repo)

      %{
        name: to_string(repo[:name] || repo["name"]),
        path: Path.expand(repo[:path] || repo["path"])
      }
    end)
  end

  defp build_from_repos(repos) do
    repo_names = repos |> Enum.map(& &1.name) |> MapSet.new()

    repo_reports =
      Map.new(repos, fn repo ->
        {repo.name, repo_report(repo, repo_names)}
      end)

    graph = graph(repo_reports)

    report = %{
      ok: true,
      graph: graph,
      publish_order: publish_order(graph.nodes, graph.edges),
      clean_clone: Map.new(repo_reports, fn {name, report} -> {name, report.clean_clone} end),
      publish_readiness:
        Map.new(repo_reports, fn {name, report} -> {name, report.publish_readiness} end)
    }

    {:ok, report}
  end

  defp repo_report(repo, repo_names) do
    dependency_report = DependencySources.report(repo.path, publish?: true)

    deps =
      dependency_report.deps
      |> Enum.filter(fn {dep_name, _dep} ->
        MapSet.member?(repo_names, Atom.to_string(dep_name))
      end)
      |> Map.new()

    %{
      deps: deps,
      clean_clone: %{
        mix_exs?: File.regular?(Path.join(repo.path, "mix.exs")),
        helper?: File.regular?(Path.join(repo.path, "build_support/dependency_sources.exs")),
        config?:
          File.regular?(Path.join(repo.path, "build_support/dependency_sources.config.exs")),
        agents?: File.regular?(Path.join(repo.path, "AGENTS.md"))
      },
      publish_readiness: %{
        ready?: dependency_report.violations == [],
        blockers: dependency_report.violations
      }
    }
  end

  defp graph(repo_reports) do
    nodes = repo_reports |> Map.keys() |> Enum.sort()

    edges =
      repo_reports
      |> Enum.flat_map(fn {name, report} ->
        Enum.map(report.deps, fn {dep_name, dep} ->
          %{from: name, to: Atom.to_string(dep_name), source: edge_source(dep)}
        end)
      end)
      |> Enum.sort_by(&{&1.from, &1.to, &1.source})

    %{nodes: nodes, edges: edges}
  end

  defp edge_source(dep) do
    cond do
      :hex in dep.sources -> :hex
      :github in dep.sources -> :github
      :path in dep.sources -> :path
      true -> :unknown
    end
  end

  defp publish_order(nodes, edges) do
    deps_by_node =
      Map.new(nodes, fn node ->
        deps =
          edges
          |> Enum.filter(&(&1.from == node))
          |> Enum.map(& &1.to)

        {node, deps}
      end)

    {order, _visited} =
      nodes
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, fn node, {order, visited} ->
        visit(node, deps_by_node, order, visited)
      end)

    Enum.reverse(order)
  end

  defp visit(node, deps_by_node, order, visited) do
    if MapSet.member?(visited, node) do
      {order, visited}
    else
      visited = MapSet.put(visited, node)

      {order, visited} =
        deps_by_node
        |> Map.get(node, [])
        |> Enum.sort()
        |> Enum.reduce({order, visited}, fn dep, {dep_order, dep_visited} ->
          visit(dep, deps_by_node, dep_order, dep_visited)
        end)

      {[node | order], visited}
    end
  end
end
