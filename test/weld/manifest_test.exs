defmodule Weld.ManifestTest do
  use ExUnit.Case

  alias Weld.FixtureCase
  alias Weld.Manifest

  test "loads and normalizes a manifest file" do
    manifest = Manifest.load!(FixtureCase.manifest_path("library_bundle", "sample"))

    assert manifest.package_name == "fixture_bundle"
    assert manifest.otp_app == :fixture_bundle
    assert manifest.version == "0.1.0"
    assert manifest.mode == :library_bundle
    assert manifest.source_projects == ["core/contracts", "runtime/local"]

    assert manifest.copy.docs == [
             "README.md",
             "CHANGELOG.md",
             "guides/architecture.md",
             "guides/getting_started.md"
           ]

    assert manifest.docs.main == "readme"
    assert manifest.repo_root == FixtureCase.fixture_path("library_bundle")
  end
end
