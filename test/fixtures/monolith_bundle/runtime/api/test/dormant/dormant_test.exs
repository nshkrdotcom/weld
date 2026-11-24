defmodule Fixture.DormantTest do
  use ExUnit.Case, async: true

  test "is not part of the owning project's declared test paths" do
    flunk("Weld projected a test outside the owning project's test_paths")
  end
end
