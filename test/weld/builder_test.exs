defmodule Weld.BuilderTest do
  use ExUnit.Case

  alias Weld.FixtureCase

  test "builds a standalone projection that compiles without path deps" do
    manifest_path = FixtureCase.manifest_path("library_bundle", "sample")
    dist_root = FixtureCase.unique_tmp_dir("weld_builder_dist")

    build_path = Weld.build!(manifest_path, dist_root: dist_root)

    assert File.exists?(Path.join(build_path, "mix.exs"))
    assert File.exists?(Path.join(build_path, "README.md"))

    assert File.exists?(
             Path.join(build_path, "vendor/core_contracts/lib/weld_fixture/contracts.ex")
           )

    assert File.exists?(Path.join(build_path, "vendor/runtime_local/lib/weld_fixture/runtime.ex"))

    mixfile = File.read!(Path.join(build_path, "mix.exs"))

    assert mixfile =~ "vendor/core_contracts/lib"
    assert mixfile =~ "vendor/runtime_local/lib"
    refute mixfile =~ "path:"

    {_, 0} = System.cmd("mix", ["deps.get"], cd: build_path, stderr_to_stdout: true)
    {output, 0} = System.cmd("mix", ["compile"], cd: build_path, stderr_to_stdout: true)
    assert output =~ "Generated fixture_bundle app"
  end
end
