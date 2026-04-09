defmodule Weld.ProjectorTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "projects a welded artifact with a generated lockfile and no path deps" do
    result = Weld.project!(FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle"))

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
    refute mixfile =~ ", path:"
    assert mixfile =~ "components/core/contracts/lib"
    assert mixfile =~ "components/runtime/local/lib"
  end

  test "projects canonicalized external deps instead of local path or scm transport" do
    manifest_path = FixtureCase.copied_manifest_path("external_dependencies", "app_bundle")
    result = Weld.project!(manifest_path)
    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))

    refute mixfile =~ ", path:"
    refute mixfile =~ "github:"
    assert mixfile =~ "{:external_lib, \"~> 1.2.0\"}"
    assert mixfile =~ "{:git_only, \"~> 0.5.0\"}"
  end

  test "projects a generated application module when selected projects have supervision roots" do
    result =
      Weld.project!(FixtureCase.copied_manifest_path("composite_runtime", "composite_bundle"))

    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))
    application_file = Path.join(result.build_path, "lib/composite_bundle/application.ex")

    assert File.regular?(application_file)
    assert mixfile =~ "mod: {CompositeBundle.Application, []}"
    assert mixfile =~ "lib"
    assert File.read!(application_file) =~ "Fixture.State.Application"
  end
end
