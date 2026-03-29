defmodule Weld.ReleaseTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "prepares and archives a release bundle" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    prepared = Weld.release_prepare!(manifest_path)

    assert File.dir?(prepared.bundle_path)
    assert Weld.release_bundle_path!(manifest_path) == prepared.bundle_path
    assert File.regular?(prepared.release_metadata_path)
    assert File.regular?(prepared.tarball_path)

    archived = Weld.release_archive!(manifest_path)

    assert File.dir?(archived.archive_path)
    assert File.regular?(Path.join(archived.archive_path, "release.json"))
  end
end
