Code.require_file("../../scripts/qc/support.exs", __DIR__)

defmodule Weld.HexConsumptionContractTest do
  use ExUnit.Case, async: false

  alias Weld.Core.Identity
  alias Weld.FixtureCase

  @moduletag :integration
  @moduletag timeout: 3_600_000

  @tag ci_build: "hex_consumption"
  test "components package resolves through a signed Hex registry after source removal" do
    run_layout!("components")
  end

  @tag ci_build: "hex_flat"
  test "flat monolith package resolves through a signed Hex registry after source removal" do
    run_layout!("flat")
  end

  @tag ci_build: "hex_preserve"
  test "preserve source-project package resolves through a signed Hex registry after source removal" do
    run_layout!("preserve")
  end

  @tag ci_build: "hex_native"
  test "pinned native package resolves and rebuilds offline through a signed Hex registry after source removal" do
    run_layout!("native")
  end

  defp run_layout!(layout) do
    root =
      case System.get_env("WELD_QC_LAYOUT_OUTPUT") do
        nil -> Path.join(FixtureCase.unique_tmp_dir("exact_hex_#{layout}"), "results")
        output -> Path.expand(output)
      end

    File.mkdir_p!(root)

    for name <- ~w(MIX_EXS MIX_LOCKFILE MIX_TARGET) do
      previous = System.get_env(name)
      System.put_env(name, "unexpected-inherited-setting")
      on_exit(fn -> restore_env(name, previous) end)
    end

    result = Weld.QC.scenario!(root, layout)

    assert result["layout"] == layout
    assert result["original_source_removed"]
    assert result["canonical_checkout_root_isolated"]
    assert result["ordinary_hex_consumer"].consumer == "ordinary_mix_hex"
    assert result["ordinary_hex_consumer"].registry_signed
    assert result["ordinary_hex_consumer"].lock_verified
    assert result["ordinary_hex_consumer"].application_started
    refute File.exists?(Path.join([root, layout, "source"]))

    assert_layout_contracts!(layout, root, result)
  end

  defp assert_layout_contracts!("components", _root, result) do
    gates = Map.new(result["gates"], &{&1["id"], &1})
    assert Identity.valid?(gates["G02"]["facts"]["lock_sha256"])
    assert gates["G04"]["status"] == "pass"
    assert gates["G07"]["status"] == "pass"
    assert gates["G08"]["status"] == "pass"
    assert gates["G09"]["status"] == "skip"
  end

  defp assert_layout_contracts!("flat", root, result) do
    gates = Map.new(result["gates"], &{&1["id"], &1})
    assert Identity.valid?(gates["G02"]["facts"]["lock_sha256"])
    assert gates["G03"]["status"] == "pass"
    assert gates["G03"]["facts"]["count"] == 2
    assert gates["G05"]["status"] == "pass"
    assert gates["G05"]["facts"]["count"] == 2
    assert gates["G07"]["status"] == "skip"
    assert gates["G09"]["status"] == "skip"
    assert gates["G09"]["skip_reason"] == "hex_publish_check_disabled"

    tar_path = Path.join([root, "flat", "package.tar"])
    {:ok, outer} = :erl_tar.extract(String.to_charlist(tar_path), [:memory])
    {~c"contents.tar.gz", contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
    {:ok, files} = :erl_tar.extract({:binary, contents}, [:compressed, :memory])
    refute List.keymember?(files, ~c"projection.lock.json", 0)
  end

  defp assert_layout_contracts!("native", _root, result) do
    assert result["ordinary_hex_consumer"].offline_rebuild
  end

  defp assert_layout_contracts!("preserve", _root, _result), do: :ok

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
