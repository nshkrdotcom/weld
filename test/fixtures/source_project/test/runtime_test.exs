defmodule Sprout.RuntimeTest do
  use ExUnit.Case, async: true

  test "aggregate exports the private implementation and owns its assets" do
    assert Sprout.Runtime.value() == :seed
    assert Sprout.Runtime.asset() == "sage\n"
  end
end
