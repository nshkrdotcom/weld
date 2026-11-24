defmodule CompositeBundleTest do
  use ExUnit.Case, async: true

  test "the generated package boots selected supervision roots" do
    assert Fixture.Runtime.ready?()
  end
end
