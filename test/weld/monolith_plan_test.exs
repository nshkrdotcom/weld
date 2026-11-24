defmodule Weld.MonolithPlanTest do
  use ExUnit.Case, async: false

  alias Weld.{Error, FixtureCase, Plan, Projector}

  setup do
    root = FixtureCase.copy_fixture("monolith_bundle")
    %{root: root, manifest: Path.join(root, "packaging/weld/monolith_bundle.exs")}
  end

  defp put(root, relative, bytes) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp targets(plan), do: Enum.map(plan.output_inventory, & &1.target)

  test "read-only planning, inspection, live and full share the final inventory", c do
    plan = Plan.build!(c.manifest)
    refute File.exists?(Path.join(c.root, ".weld"))
    assert plan.output_inventory != []
    report = Weld.inspect!(c.manifest).artifact
    assert report.source_target_basis == :projection
    assert report.source_inventory == plan.source_inventory
    assert report.output_inventory == plan.output_inventory

    assert Enum.any?(plan.source_inventory, fn entry ->
             entry.source == "core/store/test/support/store_case.exs" and
               entry.target == "test/support/core_store/store_case.exs" and not entry.publish
           end)

    assert Enum.any?(plan.source_inventory, fn entry ->
             entry.source == "core/store/test/test_helper.exs" and
               entry.target == "test/support/weld_helpers/core_store_test_helper.exs" and
               entry.operation == :transform
           end)

    assert Enum.any?(plan.source_inventory, fn entry ->
             entry.source == "core/store/config/config.exs" and
               entry.target == "config/config.exs" and entry.publish
           end)

    for live <- [false, true] do
      result = Projector.project!(plan, live: live)
      assert Enum.sort(result.verification_files) == Enum.sort(targets(plan))
      lock = result.lockfile_path |> File.read!() |> Jason.decode!()
      assert lock["source"]["target_basis"] == "projection"

      assert lock["source"]["output_inventory"] ==
               Jason.decode!(Jason.encode!(plan.output_inventory))

      assert lock["source"]["inventory"] == Jason.decode!(Jason.encode!(plan.source_inventory))
      assert Enum.all?(targets(plan), &File.regular?(Path.join(result.build_path, &1)))
      refute "test" in result.package_files
    end
  end

  test "deduplication and repeated remaps have exact source relationships", c do
    put(c.root, "core/store/lib/same.txt", "same")
    put(c.root, "runtime/api/lib/same.txt", "same")
    put(c.root, "core/store/lib/collision.txt", "first")
    put(c.root, "core/store/lib/runtime_api__collision.txt", "occupied")
    put(c.root, "runtime/api/lib/collision.txt", "second")
    plan = Plan.build!(c.manifest)
    same = Enum.find(plan.output_inventory, &(&1.target == "lib/same.txt"))

    assert Enum.sort(Enum.map(same.inputs, & &1.source)) ==
             ["core/store/lib/same.txt", "runtime/api/lib/same.txt"]

    assert Enum.any?(plan.source_inventory, fn entry ->
             entry.source == "runtime/api/lib/collision.txt" and
               entry.target == "lib/runtime_api__runtime_api__collision.txt"
           end)

    result = Projector.project!(plan)

    assert File.read!(Path.join(result.build_path, "lib/runtime_api__runtime_api__collision.txt")) ==
             "second"

    assert Plan.build!(c.manifest).output_inventory == plan.output_inventory
  end

  test "multiple migration repositories share a deterministic final restamp plan", c do
    source = "runtime/api/priv/repo/migrations/20260101000000_create_api.exs"
    put(c.root, source, "# synthetic migration\n")
    plan = Plan.build!(c.manifest)
    entries = Enum.filter(plan.source_inventory, &(&1.source == source))

    migration =
      Enum.find(
        entries,
        &String.starts_with?(&1.target, "priv/weld_repos/runtime_api/migrations/")
      )

    assert migration
    refute Path.basename(migration.target) == Path.basename(source)
    assert "priv/.weld_remap.json" in targets(plan)
    assert Enum.any?(entries, &(&1.target == "config/test.exs"))
    result = Projector.project!(plan)
    assert File.regular?(Path.join(result.build_path, migration.target))
    assert result.migration_layout.repo_count == 2
    assert length(result.migration_remaps) == 2
    assert Plan.build!(c.manifest).output_inventory == plan.output_inventory
  end

  test "a stale plan or a generated path collision cannot replace an active view", c do
    previous = Weld.project!(c.manifest)
    marker = File.read!(Path.join(previous.build_path, "weld.provenance.json"))
    stale = Plan.build!(c.manifest)
    put(c.root, "runtime/api/lib/new.txt", "changed after planning")
    assert_raise Error, ~r/inputs changed after planning/, fn -> Projector.project!(stale) end
    assert File.read!(Path.join(previous.build_path, "weld.provenance.json")) == marker

    path = put(c.root, "core/store/lib/monolith_bundle/application.ex", "# reserved\n")
    assert_raise Error, ~r/projection path collision/, fn -> Plan.build!(c.manifest) end
    assert File.read!(path) == "# reserved\n"
    assert File.read!(Path.join(previous.build_path, "weld.provenance.json")) == marker
  end

  test "non-support helper requires retain their projected relative target", c do
    put(c.root, "core/store/test/setup.exs", "# standalone helper input\n")
    path = Path.join(c.root, "core/store/test/test_helper.exs")
    File.write!(path, File.read!(path) <> "\nCode.require_file(\"setup.exs\", __DIR__)\n")
    plan = Plan.build!(c.manifest)

    fragment =
      Enum.find(
        plan.monolith_plan.full,
        &String.ends_with?(&1.target, "/core_store_test_helper.exs")
      )

    assert fragment.content =~ "../../core_store/setup.exs"
    assert "test/core_store/setup.exs" in targets(plan)
  end
end
