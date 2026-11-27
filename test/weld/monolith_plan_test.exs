defmodule Weld.MonolithPlanTest do
  use ExUnit.Case, async: false

  alias Weld.{Error, FixtureCase, Plan}
  alias Weld.Plan.Inventory
  alias Weld.Projector

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
    before_state = Weld.Receipt.tree(Path.join(c.root, ".weld"))
    plan = Plan.build!(c.manifest)
    assert Weld.Receipt.tree(Path.join(c.root, ".weld")) == before_state
    assert plan.output_inventory != []
    report = Weld.Commands.inspect!(c.manifest).artifact
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
      inventory = Inventory.portable(plan)
      assert Enum.map(inventory["entries"], & &1["target"]) == Enum.sort(targets(plan))
      assert inventory["layout"]["name"] == "flat"
      refute File.exists?(Path.join(result.build_path, "projection.lock.json"))
      refute File.exists?(Path.join(result.build_path, "weld.provenance.json"))
      assert Enum.all?(targets(plan), &File.regular?(Path.join(result.build_path, &1)))
      refute "test" in result.package_files
    end
  end

  test "deduplication and repeated remaps have exact source relationships", c do
    [first, second] = Enum.map(Plan.build!(c.manifest).selected_projects, & &1.id)
    slugs = %{"core/store" => "core_store", "runtime/api" => "runtime_api"}
    slug = Map.fetch!(slugs, second)
    occupied = "#{slug}__collision.txt"
    remapped = "lib/#{slug}__#{slug}__collision.txt"
    source = "#{second}/lib/collision.txt"

    put(c.root, "#{first}/lib/same.txt", "same")
    put(c.root, "#{second}/lib/same.txt", "same")
    put(c.root, "#{first}/lib/collision.txt", "first")
    put(c.root, "#{first}/lib/#{occupied}", "occupied")
    put(c.root, source, "second")

    plan = Plan.build!(c.manifest)
    same = Enum.find(plan.output_inventory, &(&1.target == "lib/same.txt"))

    assert Enum.sort(Enum.map(same.inputs, & &1.source)) ==
             ["core/store/lib/same.txt", "runtime/api/lib/same.txt"]

    assert Enum.any?(plan.source_inventory, fn entry ->
             entry.source == source and entry.target == remapped
           end)

    for live <- [false, true] do
      result = Projector.project!(plan, live: live)
      assert File.read!(Path.join(result.build_path, "lib/collision.txt")) == "first"
      assert File.read!(Path.join(result.build_path, "lib/#{occupied}")) == "occupied"
      assert File.read!(Path.join(result.build_path, remapped)) == "second"
    end

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
    previous = Weld.Commands.project!(c.manifest)
    marker = Weld.Hash.observation(previous.build_path)
    stale = Plan.build!(c.manifest)
    put(c.root, "runtime/api/lib/new.txt", "changed after planning")
    assert_raise Error, ~r/inputs changed after planning/, fn -> Projector.project!(stale) end
    assert Weld.Hash.observation(previous.build_path) == marker

    path = put(c.root, "core/store/lib/monolith_bundle/application.ex", "# reserved\n")
    assert_raise Error, ~r/projection path collision/, fn -> Plan.build!(c.manifest) end
    assert File.read!(path) == "# reserved\n"
    assert Weld.Hash.observation(previous.build_path) == marker
  end

  test "non-support helper requires retain their projected relative target", c do
    put(c.root, "core/store/test/setup.exs", "# standalone helper input\n")
    path = Path.join(c.root, "core/store/test/test_helper.exs")
    File.write!(path, File.read!(path) <> "\nCode.require_file(\"setup.exs\", __DIR__)\n")
    plan = Plan.build!(c.manifest)

    fragment =
      Enum.find(
        plan.layout.full,
        &String.ends_with?(&1.target, "/core_store_test_helper.exs")
      )

    assert fragment.content =~ "../../core_store/setup.exs"
    assert "test/core_store/setup.exs" in targets(plan)
  end
end
