defmodule Weld.ProjectorMonolithTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "projects a monolith artifact into a real root project tree" do
    result = Weld.project!(FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle"))

    assert result.build_path =~ "/dist/monolith/monolith_bundle"
    assert File.regular?(Path.join(result.build_path, "mix.exs"))
    assert File.regular?(Path.join(result.build_path, "projection.lock.json"))
    assert File.regular?(Path.join(result.build_path, "lib/fixture/store.ex"))
    assert File.regular?(Path.join(result.build_path, "lib/fixture/api.ex"))
    assert File.regular?(Path.join(result.build_path, "config/config.exs"))
    assert File.regular?(Path.join(result.build_path, "config/test.exs"))
    assert File.regular?(Path.join(result.build_path, "config/sources/core_store/config.exs"))
    assert File.regular?(Path.join(result.build_path, "config/sources/runtime_api/config.exs"))
    assert File.regular?(Path.join(result.build_path, "test/test_helper.exs"))
    assert File.regular?(Path.join(result.build_path, "test/core_store/fixture/store_test.exs"))
    assert File.regular?(Path.join(result.build_path, "test/runtime_api/fixture/api_test.exs"))
    assert File.regular?(Path.join(result.build_path, "test/support/core_store/store_case.exs"))
    assert File.regular?(
             Path.join(result.build_path, "test/support/weld_helpers/core_store_test_helper.exs")
           )

    assert File.regular?(
             Path.join(result.build_path, "priv/repo/migrations/20260101000000_create_store.exs")
           )

    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))
    refute mixfile =~ "components/"
    refute mixfile =~ "path:"
  end

  test "the generated monolith compiles and runs real package tests" do
    result = Weld.project!(FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle"))

    {output, status} =
      System.cmd("mix", ["test"], cd: result.build_path, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])

    assert status == 0, output
    assert output =~ "2 tests, 0 failures"
  end
end
