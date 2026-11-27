defmodule Weld.Core.FactsTest do
  use ExUnit.Case, async: true

  alias Weld.Core.{Facts, Identity}

  defp facts do
    %{
      root: "/unavailable/checkout",
      nodes: %{
        "/unavailable/checkout" => %{type: :directory, mode: 0o755},
        "/unavailable/checkout/lib" => %{type: :directory, mode: 0o755},
        "/unavailable/checkout/lib/a.ex" => %{
          type: :regular,
          mode: 0o644,
          size: 3,
          sha256: Identity.raw("one"),
          content: "one"
        },
        "/unavailable/checkout/empty" => %{type: :directory, mode: 0o755}
      }
    }
  end

  test "literal observations compile without a real checkout or IO" do
    observed = facts()
    assert Facts.read!(observed, "/unavailable/checkout/lib/a.ex") == "one"

    assert Facts.list_files(observed, "/unavailable/checkout/lib") ==
             ["/unavailable/checkout/lib/a.ex"]

    assert Facts.type(observed, "/unavailable/checkout/config") == :missing
    assert Facts.empty_dirs(observed, "/unavailable/checkout") == ["empty"]

    assert Facts.wildcard(observed, "/unavailable/checkout/**/*.ex") ==
             ["/unavailable/checkout/lib/a.ex"]
  end

  test "relative directory listing uses the explicit fact root" do
    assert Facts.ls!(facts(), "lib") == ["a.ex"]
    assert Facts.ls!(facts(), "empty") == []
  end

  test "typed declarations reject wrong existing types even when optional" do
    for declaration <- [
          [path: "lib/a.ex", type: :tree, required: true],
          [path: "lib", type: :file, required: false]
        ] do
      assert_raise Weld.Error, ~r/type mismatch/, fn ->
        Weld.Core.Inputs.observe!(facts(), facts().root, declaration)
      end
    end

    assert %{entries: []} =
             Weld.Core.Inputs.observe!(facts(), facts().root,
               path: "missing",
               type: :file,
               required: false
             )

    assert %{entries: []} =
             Weld.Core.Inputs.observe!(facts(), facts().root,
               path: "empty",
               type: :tree,
               required: true
             )
  end

  test "missing generated input fails instead of reaching out to disk" do
    assert_raise Weld.Error, ~r/missing_fact/, fn ->
      Facts.read!(facts(), "/unavailable/checkout/VERSION")
    end
  end

  test "glob rules preserve literal commas, choices and character ranges" do
    assert Facts.matches?("a,b.ex", "a,b.ex")
    refute Facts.matches?("a.ex", "a,b.ex")
    assert Facts.matches?("lib/a.ex", "{lib,src}/[a-z].ex")
    assert Facts.matches?("src/z.ex", "{lib,src}/[!0-9].ex")
    refute Facts.matches?("src/2.ex", "{lib,src}/[!0-9].ex")
    assert Facts.matches?("root.ex", "**/*.ex")
    assert_raise Weld.Error, fn -> Facts.matches?("x", "{x") end
    assert_raise Weld.Error, fn -> Facts.matches?("x", "[x") end
  end

  test "unsafe parents and case-fold output collisions fail before effects" do
    observed = put_in(facts(), [:nodes, "/unavailable/checkout/lib"], %{type: :symlink})

    assert_raise Weld.Error, fn ->
      Facts.source!(observed, "/unavailable/checkout", "lib/a.ex")
    end

    assert_raise ArgumentError, fn ->
      Weld.Core.Inventory.validate!([%{target: "lib/A.ex"}, %{target: "lib/a.ex"}])
    end
  end
end
