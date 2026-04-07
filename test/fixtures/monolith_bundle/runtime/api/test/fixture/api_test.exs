defmodule Fixture.ApiTest do
  use ExUnit.Case, async: true

  test "exposes merged config and dependency modules" do
    assert Fixture.Api.source() == {:store, :api}
  end
end
