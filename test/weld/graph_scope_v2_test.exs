defmodule Weld.GraphScopeV2Test do
  use ExUnit.Case, async: true
  alias Weld.{Graph, Graph.Edge}
  alias Weld.Core.Selection

  test "compatible environment scopes union without entering the package view" do
    deps = [dependency(:dev, "~> 1.0"), dependency(:test, "~> 1.0")]
    assert [merged] = Graph.normalize_dependencies(deps)
    assert merged.opts[:only] == [:dev, :test]
    graph = Enum.reduce(deps, Graph.new(), &Graph.add_external_dep(&2, "owner", Graph.external_dependency(&1)))
    assert %{external_deps: [combined], violations: []} = Selection.merge_external_deps(graph, ["owner"], :test)
    assert combined.opts[:only] == [:dev, :test]
    assert %{external_deps: [], violations: []} = Selection.merge_external_deps(graph, ["owner"], :package)
  end

  test "mixed docs and test scopes preserve both views without publication" do
    for scopes <- [[:docs, :test], [:dev, :docs, :test]] do
      dep = dependency(scopes, "~> 1.0")
      external = Graph.external_dependency(dep)
      assert is_list(external.kind)
      graph = Graph.new() |> Graph.add_external_dep("owner", external)
      assert %{external_deps: [], violations: []} = Selection.merge_external_deps(graph, ["owner"], :package)
      assert %{external_deps: [docs], violations: []} = Selection.merge_external_deps(graph, ["owner"], :docs)
      assert %{external_deps: [test], violations: []} = Selection.merge_external_deps(graph, ["owner"], :test)
      assert docs.opts[:only] == scopes
      assert test.opts[:only] == scopes
      internal = %{Graph.new() | projects: %{"owner" => nil, "helper" => nil}}
        |> Graph.add_edge(%Edge{from: "owner", to: "helper", app: :helper, kind: external.kind, opts: dep.opts})
      assert Graph.reachable_from(internal, "owner", :package) == ["owner"]
      assert Graph.reachable_from(internal, "owner", :docs) == ["helper", "owner"]
      assert Graph.reachable_from(internal, "owner", :test) == ["helper", "owner"]
    end
    assert {:ok, union} = Graph.merge_dependency_scopes(Graph.external_dependency(dependency(:docs, "~> 1.0")), Graph.external_dependency(dependency(:test, "~> 1.0")))
    assert union.kind == [:docs, :test]
    refute Weld.Graph.View.allowed?(union.kind, :package)
  end

  test "unscoped requirements dominate scoped duplicates while different requirements conflict" do
    unscoped = %{app: :dep, requirement: "~> 1.0", opts: [], original: {:dep, "~> 1.0"}}
    scoped = dependency(:test, "~> 1.0")
    scoped = %{scoped | opts: scoped.opts ++ [runtime: true, optional: false]}
    assert {:ok, merged} = Graph.merge_dependency_scopes(unscoped, scoped)
    refute Keyword.has_key?(merged.opts, :only)
    graph = Graph.new() |> Graph.add_external_dep("owner", Graph.external_dependency(unscoped))
      |> Graph.add_external_dep("owner", Graph.external_dependency(dependency(:test, "~> 2.0")))
    assert %{violations: [%{code: :conflicting_external_dependency}]} = Selection.merge_external_deps(graph, ["owner"], :test)
    assert %{external_deps: [%{requirement: "~> 1.0"}], violations: []} = Selection.merge_external_deps(graph, ["owner"], :package)
  end

  test "topology is dependency-first with stable ties and a concrete cycle witness" do
    graph = %{Graph.new() | projects: Map.new(~w(a b c z), &{&1, nil})}
    graph = graph |> Graph.add_edge(edge("a", "b")) |> Graph.add_edge(edge("b", "c"))
    assert {:ok, ["c", "z", "b", "a"]} = Graph.topology(graph, :package)
    assert {:cycle, ["a", "b", "c", "a"]} = Graph.topology(Graph.add_edge(graph, edge("c", "a")), :package)
    assert {:ok, ["a", "b", "c"]} = Graph.path(graph, "a", "c", :package)
  end

  test "external requirements and canonical declarations must agree" do
    dependency = %{app: :dep, requirement: "~> 1.0", opts: [], original: {:dep, "~> 1.0"}}
    manifest = %{repo_root: "/workspace", dependencies: %{dep: %{requirement: "~> 2.0", opts: []}}}
    graph = Graph.build(manifest, %{"owner" => project(dependency)})
    assert [%{code: :conflicting_dependency, project: "owner", details: %{source: "owner/mix.exs"}}] = Graph.violations(graph)
    missing = %{dependency | requirement: nil, original: {:dep, []}}
    graph = Graph.build(%{manifest | dependencies: %{}}, %{"owner" => project(missing)})
    assert [%{code: :conflicting_dependency}] = Graph.violations(graph)
  end

  test "canonical path replacements preserve runtime and target scopes" do
    dependency = %{app: :dep, requirement: nil, opts: [path: "../../external", targets: [:host], runtime: false],
      original: {:dep, [path: "../../external", targets: [:host], runtime: false]}}
    manifest = %{repo_root: "/workspace", dependencies: %{dep: %{requirement: "~> 1.0", opts: [targets: [:embedded]]}}}
    graph = Graph.build(manifest, %{"owner" => project(dependency)})
    assert [%{code: :external_path_dependency}] = Graph.violations(graph)
    manifest = put_in(manifest, [:dependencies, :dep, :opts], [])
    graph = Graph.build(manifest, %{"owner" => project(dependency)})
    assert Graph.violations(graph) == []
    assert [%{opts: opts, origins: ["owner/mix.exs"]}] = Graph.external_deps(graph, "owner")
    assert opts[:targets] == [:host]
    assert opts[:runtime] == false
  end

  defp project(dep), do: %Weld.Workspace.Project{id: "owner", abs_path: "/workspace/owner", app: :owner,
    version: "1.0.0", elixir: "~> 1.18", deps: [dep], application: %{}, elixirc_paths: [], erlc_paths: [],
    copy_dirs: [], classification: :runtime, publication_role: :default,
    facts: %{root: "/workspace", nodes: %{}}}

  defp dependency(scope, requirement), do: %{app: :dep, requirement: requirement,
    opts: [only: scope], original: {:dep, requirement, [only: scope]}}
  defp edge(from, to), do: %Edge{from: from, to: to, app: :edge, kind: :runtime, opts: []}
end
