defmodule Weld.ProjectGraphTest do
  use ExUnit.Case

  alias Weld.FixtureCase
  alias Weld.Manifest
  alias Weld.ProjectGraph

  test "loads selected projects and internalizes selected sibling deps" do
    manifest = Manifest.load!(FixtureCase.manifest_path("library_bundle", "sample"))
    graph = ProjectGraph.load!(manifest)

    assert Map.keys(graph.projects) == ["core/contracts", "runtime/local"]
    assert graph.external_deps == []

    runtime = Map.fetch!(graph.projects, "runtime/local")

    assert runtime.app == :fixture_runtime
    assert runtime.path == "runtime/local"
    assert runtime.internal_deps == [:fixture_contracts]
  end

  test "fails when a selected project depends on an unselected sibling" do
    manifest = Manifest.load!(FixtureCase.manifest_path("library_bundle", "broken"))

    assert_raise Weld.Error, ~r/unselected sibling project/, fn ->
      ProjectGraph.load!(manifest)
    end
  end
end
