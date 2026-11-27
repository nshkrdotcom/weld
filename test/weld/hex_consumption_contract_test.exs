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

      if result["layout"] == "native" do
        assert result["ordinary_hex_consumer"].offline_rebuild
      end
    end
  end
end
