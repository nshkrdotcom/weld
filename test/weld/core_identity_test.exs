defmodule Weld.Core.IdentityTest do
  use ExUnit.Case, async: true

  alias Weld.Core.{Identity, Inventory}

  @vectors Path.expand("../fixtures/canonical-vectors.json", __DIR__)

  test "implements the specification's portable digest vectors" do
    vectors = @vectors |> File.read!() |> Jason.decode!()

    for vector <- vectors["raw_sha256"] do
      assert Identity.raw(vector["utf8"]) == vector["sha256"]
    end

    for vector <- vectors["domain_vectors"] do
      assert Identity.canonical(vector["value"]) == vector["canonical_utf8"]
      assert Identity.digest(vector["domain"], vector["value"]) == vector["sha256"]
    end
  end

  test "rejects values outside the canonical wire model" do
    for value <- [1.5, %{key: "value"}, {:a, 1}, <<255>>] do
      assert_raise ArgumentError, fn -> Identity.canonical(value) end
    end
  end

  test "inventory rejects collisions and exposes reverse provenance" do
    entry = %{target: "lib/a.ex", inputs: [%{source: "core/a.ex"}], publish: true}
    assert Inventory.reverse_index([entry]) == %{"core/a.ex" => ["lib/a.ex"]}
    assert_raise ArgumentError, fn -> Inventory.validate!([entry, entry]) end
    assert_raise ArgumentError, fn -> Inventory.validate!([entry, %{entry | target: "lib"}]) end
    assert_raise ArgumentError, fn -> Inventory.validate_path!("../secret") end
  end
end
