defmodule Weld.ProjectorTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "projects a welded artifact with a generated lockfile and no path deps" do
    result = Weld.project!(FixtureCase.manifest_path("library_bundle", "fixture_bundle"))

    assert File.regular?(Path.join(result.build_path, "mix.exs"))
    assert File.regular?(Path.join(result.build_path, "projection.lock.json"))

    assert File.regular?(
             Path.join(
               result.build_path,
               "components/core/contracts/lib/weld_fixture/contracts.ex"
             )
           )

    assert File.regular?(
             Path.join(result.build_path, "components/runtime/local/lib/weld_fixture/runtime.ex")
           )

    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))
    refute mixfile =~ "path:"
    assert mixfile =~ "components/core/contracts/lib"
    assert mixfile =~ "components/runtime/local/lib"
  end
end
