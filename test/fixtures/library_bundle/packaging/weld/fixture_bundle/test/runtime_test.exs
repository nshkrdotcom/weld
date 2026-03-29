defmodule FixtureBundle.RuntimeTest do
  use ExUnit.Case, async: true

  test "the welded runtime can see its dependency closure" do
    assert WeldFixture.Runtime.hello() == ~s({"contract":"fixture_contracts"})
  end
end
