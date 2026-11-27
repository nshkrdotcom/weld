defmodule Weld.SnapshotContractTest do
  use ExUnit.Case, async: false

  alias Weld.{Error, FixtureCase, Plan, Projector}
  alias Weld.Plan.Inventory

  setup do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    plan = Plan.build!(manifest)
    %{plan: plan, root: plan.manifest.repo_root,
      input_id: Inventory.portable(plan)["input_id"]}
  end

  test "selected rechecks ignore unrelated bytes but observe new discovery matches", ctx do
    File.write!(Path.join(ctx.root, "unrelated-not-an-input.txt"), "unrelated")
    assert :ok == Projector.recheck_inputs!(ctx.plan, ctx.input_id)

    project = Path.join(ctx.root, "core/newly_discovered")
    File.mkdir_p!(project)
    File.write!(Path.join(project, "mix.exs"), "# newly discovered structural input\n")
    error = assert_raise Error, fn ->
      Projector.recheck_inputs!(ctx.plan, ctx.input_id)
    end
    assert error.code == :inputs_changed
  end

  test "absent configuration emergence and executable changes invalidate frozen facts", ctx do
    config = Path.join(ctx.root, "core/contracts/config")
    File.mkdir_p!(config)
    File.write!(Path.join(config, "config.exs"), "import Config\n")
    error = assert_raise Error, fn ->
      Projector.recheck_inputs!(ctx.plan, ctx.input_id)
    end
    assert error.code == :inputs_changed
    File.rm_rf!(config)
    assert :ok == Projector.recheck_inputs!(ctx.plan, ctx.input_id)

    source = Path.join(ctx.root, "core/contracts/lib/weld_fixture/contracts.ex")
    File.chmod!(source, 0o755)
    error = assert_raise Error, fn ->
      Projector.recheck_inputs!(ctx.plan, ctx.input_id)
    end
    assert error.code == :inputs_changed
  end

  test "selected roots never follow a replacement source symlink", ctx do
    source = Path.join(ctx.root, "core/contracts/lib/weld_fixture/contracts.ex")
    File.rm!(source)
    File.ln_s!("/etc/passwd", source)
    assert_raise Error, fn -> Projector.recheck_inputs!(ctx.plan, ctx.input_id) end
  end
end
