Code.require_file("../../scripts/qc/support.exs", __DIR__)

defmodule Weld.HexConsumptionContractTest do
  use ExUnit.Case, async: false
  alias Weld.FixtureCase
  @moduletag :integration
  @moduletag ci_build: "hex_consumption"
  @moduletag timeout: 3_600_000

  test "components, flat, preserve and pinned native packages resolve through a signed Hex registry after source removal" do
    root = Path.join(FixtureCase.unique_tmp_dir("exact_hex_matrix"), "results")
    results = Weld.QC.matrix!(root)
    assert Enum.map(results, & &1["layout"]) == ~w(components flat preserve native)
    for result <- results do
      assert result["original_source_removed"]
      assert result["canonical_checkout_root_isolated"]
      assert result["ordinary_hex_consumer"].consumer == "ordinary_mix_hex"
      assert result["ordinary_hex_consumer"].registry_signed
      assert result["ordinary_hex_consumer"].lock_verified
      assert result["ordinary_hex_consumer"].application_started
      refute File.exists?(Path.join([root, result["layout"], "source"]))
    end
    assert List.last(results)["ordinary_hex_consumer"].offline_rebuild
  end
end
