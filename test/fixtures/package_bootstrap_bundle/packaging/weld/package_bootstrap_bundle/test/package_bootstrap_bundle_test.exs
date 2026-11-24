defmodule PackageBootstrapBundleTest do
  use ExUnit.Case, async: true

  test "exposes the fixture public surface" do
    assert Fixture.Bootstrap.marker() == :ok
  end
end
