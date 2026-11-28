Code.require_file("../../scripts/qc/support.exs", __DIR__)

defmodule Weld.HexConsumptionContractTest do
  use ExUnit.Case, async: false
  alias Weld.FixtureCase
  @moduletag :integration
  @moduletag ci_build: "hex_consumption"
  @moduletag timeout: 3_600_000

  test "components, flat, preserve and pinned native packages resolve through a signed Hex registry after source removal" do
    layout = System.get_env("WELD_CI_QC_LAYOUT")

    root =
      case System.get_env("WELD_QC_LAYOUT_OUTPUT") do
        nil -> Path.join(FixtureCase.unique_tmp_dir("exact_hex_matrix"), "results")
        output -> Path.expand(output)
      end

    for name <- ~w(MIX_EXS MIX_LOCKFILE MIX_TARGET) do
      previous = System.get_env(name)
      System.put_env(name, "unexpected-inherited-setting")

      on_exit(fn ->
        if is_nil(previous), do: System.delete_env(name), else: System.put_env(name, previous)
      end)
    end

    {results, expected} =
      if layout do
        {[Weld.QC.scenario!(root, layout)], [layout]}
      else
        {Weld.QC.matrix!(root), ~w(components flat preserve native)}
      end

    assert Enum.map(results, & &1["layout"]) == expected

    for result <- results do
      assert result["original_source_removed"]
      assert result["canonical_checkout_root_isolated"]
      assert result["ordinary_hex_consumer"].consumer == "ordinary_mix_hex"
      assert result["ordinary_hex_consumer"].registry_signed
      assert result["ordinary_hex_consumer"].lock_verified
      assert result["ordinary_hex_consumer"].application_started
      refute File.exists?(Path.join([root, result["layout"], "source"]))

      gates = Map.new(result["gates"], &{&1["id"], &1})

      if result["layout"] == "components" do
        assert gates["G04"]["status"] == "pass"
        assert gates["G07"]["status"] == "pass"
        assert gates["G08"]["status"] == "pass"
        assert gates["G09"]["status"] == "skip"
      end

      if result["layout"] == "flat" do
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

      if result["layout"] == "native" do
        assert result["ordinary_hex_consumer"].offline_rebuild
      end
    end
  end
end
