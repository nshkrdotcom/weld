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

  test "prepared package bundles preserve root mix tooling config" do
    manifest_path = FixtureCase.copied_manifest_path("package_repo_bundle", "package_repo_bundle")
    prepared = Weld.release_prepare!(manifest_path)
    project_path = Path.join(prepared.bundle_path, "project")

    assert File.regular?(Path.join(project_path, ".formatter.exs"))

    {output, status} =
      System.cmd("mix", ["format", "--check-formatted"],
        cd: project_path,
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "release metadata records a repo-relative manifest path and the Weld version" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    prepared = Weld.release_prepare!(manifest_path)

    metadata =
      prepared.release_metadata_path
      |> File.read!()
      |> Jason.decode!()

    assert metadata["manifest_path"] == "packaging/weld/fixture_bundle.exs"
    refute Path.type(metadata["manifest_path"]) == :absolute
    assert metadata["weld_version"] == Weld.version()
  end

  test "release bundle slugs are stable across checkout locations" do
    prepared_a =
      "library_bundle"
      |> FixtureCase.copied_manifest_path("fixture_bundle")
      |> Weld.release_prepare!()

    prepared_b =
      "library_bundle"
      |> FixtureCase.copied_manifest_path("fixture_bundle")
      |> Weld.release_prepare!()

    assert Path.basename(prepared_a.bundle_path) == Path.basename(prepared_b.bundle_path)
  end
end
