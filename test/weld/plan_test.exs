defmodule Weld.PlanTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase
  alias Weld.Graph
  alias Weld.Plan

  test "computes a runtime closure from roots" do
    plan = Plan.build!(FixtureCase.manifest_path("library_bundle", "fixture_bundle"))

    assert plan.selected_ids == ["core/contracts", "runtime/local"]
    assert plan.excluded_ids == []
    assert plan.violations == []
  end

  test "keeps test-only tooling out of the selected closure while preserving the edge" do
    plan =
      Plan.build!(FixtureCase.manifest_path("root_workspace", "artifacts"),
        artifact: "web_bundle"
      )

    assert plan.selected_ids == ["apps/core", "apps/web"]
    refute "tooling/test_support" in plan.selected_ids

    assert Enum.any?(Graph.edges(plan.graph), fn edge ->
             edge.from == "apps/web" and edge.to == "tooling/test_support" and edge.kind == :test
           end)
  end

  test "explains why one runtime project depends on another" do
    result =
      Weld.query_why!(
        FixtureCase.manifest_path("root_workspace", "artifacts"),
        "apps/web",
        "apps/core",
        artifact: "web_bundle"
      )

    assert result.path == ["apps/web", "apps/core"]
  end
end
