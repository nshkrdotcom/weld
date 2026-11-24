defmodule RootCoreBundle.CoreTest do
  use ExUnit.Case, async: true

  test "the projected core bundle compiles normally" do
    assert RootWorkspace.Core.greet() == "core"
  end
end
