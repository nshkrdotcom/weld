defmodule Weld.ManifestTest do
  use ExUnit.Case, async: true

  alias Weld.FixtureCase
  alias Weld.Manifest

  test "loads a single-artifact manifest" do
    manifest = Manifest.load!(FixtureCase.manifest_path("library_bundle", "fixture_bundle"))
    artifact = Manifest.artifact!(manifest, nil)

    assert manifest.workspace.project_globs == ["core/*", "runtime/*"]
    assert manifest.dependencies == %{}
    assert artifact.id == "fixture_bundle"
    assert artifact.roots == ["runtime/local"]
    assert artifact.verify.smoke.enabled
  end

  test "requires an explicit artifact when the manifest defines more than one" do
    manifest = Manifest.load!(FixtureCase.manifest_path("root_workspace", "artifacts"))

    assert_raise Weld.Error, ~r/multiple artifacts/, fn ->
      Manifest.artifact!(manifest, nil)
    end

    assert Manifest.artifact!(manifest, "web_bundle").id == "web_bundle"
  end

  test "loads monolith mode artifacts and canonical git dependency opts" do
    manifest = Manifest.load!(FixtureCase.manifest_path("monolith_bundle", "monolith_bundle"))
    artifact = Manifest.artifact!(manifest, nil)

    assert artifact.mode == :monolith
    assert artifact.monolith_opts == []
    assert manifest.dependencies[:git_dep].requirement == nil
    assert manifest.dependencies[:git_dep].opts[:git] == "https://example.test/git_dep.git"
    assert manifest.dependencies[:git_dep].opts[:branch] == "main"
  end
end
