defmodule Weld.ManifestTest do
  use ExUnit.Case, async: true

  alias Weld.FixtureCase
  alias Weld.Manifest

  test "loads a single-artifact manifest" do
    manifest = Manifest.load!(FixtureCase.manifest_path("library_bundle", "fixture_bundle"))
    artifact = Manifest.artifact!(manifest, nil)

    assert manifest.workspace.project_globs == ["core/*", "runtime/*"]
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
end
