defmodule Fixture.StoreTest do
  use ExUnit.Case, async: true

  test "exposes the store module" do
    assert Fixture.Store.source() == :store
    assert Fixture.StoreCase.source() == :store_support
  end
end
