defmodule Weld.Core.CompilerTest do
  use ExUnit.Case, async: true
  @moduletag :pure
  alias Weld.Core.Identity
  alias Weld.{LiteralPlan, Plan}

  test "literal observations compile complete full/live variants without a checkout" do
    plan = LiteralPlan.build()
    assert plan.violations == []
    assert plan.dependency_ids == ["apps/a"]
    inventory = Plan.Inventory.portable(plan)
    assert inventory["layout"]["name"] == "components"
    assert Enum.map(plan.layout.full, & &1.target) == Enum.map(plan.layout.live, & &1.target)

    assert Enum.any?(
             inventory["inputs"],
             &(&1["id"] == "absence:apps/a/config" or
                 (&1["kind"] == "tree" and &1["fact"]["root"] == "apps/a/config" and
                    &1["fact"]["matches"] == []))
           )

    assert Enum.all?(inventory["entries"], &(&1["origins"] != []))
  end

  test "checkout relocation and unrelated bytes leave portable identities unchanged" do
    left = LiteralPlan.build("/nowhere/one") |> Plan.Inventory.portable()

    right =
      LiteralPlan.build("/another/place/two", %{"unrelated.txt" => "outside every selected rule"})
      |> Plan.Inventory.portable()

    assert left["input_id"] == right["input_id"]
    assert left["plan_id"] == right["plan_id"]
    refute Identity.canonical(left) =~ "/nowhere/one"
  end

  test "new config inputs and discovery members alter relevant watches" do
    original = LiteralPlan.build() |> Plan.Inventory.portable()

    configured =
      LiteralPlan.build(
        "/nonexistent/weld-literal",
        %{"apps/a/config/config.exs" => "import Config\nconfig :literal_a, :enabled, true\n"}
      )
      |> Plan.Inventory.portable()

    discovered =
      LiteralPlan.build("/nonexistent/weld-literal", %{"apps/new/mix.exs" => "# new member\n"})
      |> Plan.Inventory.portable()

    refute original["input_id"] == configured["input_id"]
    refute original["input_id"] == discovered["input_id"]
  end

  test "operational transport, storage and timing do not enter portable proof" do
    plan = Weld.LiteralPlan.build()
    before = Weld.Plan.Inventory.portable(plan)

    facts =
      Map.merge(plan.facts, %{
        upload_endpoint: "https://transport.example.test/api",
        state_directory: "/different/local/state",
        elapsed_microseconds: 9_999
      })

    changed = %{plan | facts: facts}
    assert Weld.Plan.Inventory.portable(changed) == before

    compiler_changed = %{
      plan
      | facts: %{plan.facts | compiler_id: Identity.raw("other compiler")}
    }

    refute Weld.Plan.Inventory.portable(compiler_changed)["input_id"] == before["input_id"]
  end
end
