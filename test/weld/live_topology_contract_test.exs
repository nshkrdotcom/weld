defmodule Weld.LiveTopologyContractTest do
  use ExUnit.Case, async: false

  alias Weld.Layout.Live

  setup do
    %{tmp_dir: Weld.FixtureCase.unique_tmp_dir("weld_live_topology")}
  end

  test "live topology comparison uses canonical path order for prefix siblings", %{tmp_dir: root} do
    plan =
      Weld.LiteralPlan.build(root, %{
        "apps/a/lib/a/b.ex" => "defmodule Literal.NestedB, do: def(value, do: :ok)\n"
      })

    for {path, %{type: :regular, content: contents}} <- plan.facts.nodes do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    live = Path.join(root, ".weld/v2/live/literal")
    File.mkdir_p!(live)

    guard =
      Live.guard_ast(plan,
        topology: [Path.join(root, "apps/a/lib")]
      )

    assert {nil, _bindings} = Code.eval_quoted(guard, [], file: Path.join(live, "mix.exs"))

    File.write!(Path.join(root, "apps/a/lib/new.ex"), "# new compiler input\n")

    assert_raise Mix.Error, ~r/live projection inputs changed/, fn ->
      Code.eval_quoted(guard, [], file: Path.join(live, "mix.exs"))
    end
  end
end
