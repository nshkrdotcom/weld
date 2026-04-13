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

  test "release tracking uses projection package-name branches with orphan history" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    FixtureCase.init_git!(repo_root)
    Weld.release_prepare!(manifest_path)

    result = Weld.release_track!(manifest_path)

    assert result.branch == "projection/fixture_bundle"
    assert result.branch_created?
    assert result.committed?
    assert FixtureCase.branch_exists?(repo_root, "projection/fixture_bundle")

    assert result.commit_sha ==
             FixtureCase.git_output!(repo_root, ["rev-parse", "projection/fixture_bundle"])

    assert FixtureCase.git_output!(repo_root, ["rev-list", "--count", "projection/fixture_bundle"]) ==
             "1"

    {_output, status} =
      FixtureCase.git(repo_root, ["merge-base", "HEAD", "projection/fixture_bundle"])

    assert status != 0
  end

  test "release tracking is a no-op when the prepared bundle has not changed" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    FixtureCase.init_git!(repo_root)
    Weld.release_prepare!(manifest_path)

    first = Weld.release_track!(manifest_path)
    second = Weld.release_track!(manifest_path)

    assert first.committed?
    refute second.branch_created?
    refute second.committed?
    assert second.commit_sha == first.commit_sha
  end

  test "release tracking commits a new projection revision when the bundle changes" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    FixtureCase.init_git!(repo_root)
    Weld.release_prepare!(manifest_path)

    first = Weld.release_track!(manifest_path)

    readme_path = Path.join(repo_root, "README.md")
    File.write!(readme_path, File.read!(readme_path) <> "\nprojection drift\n")

    Weld.release_prepare!(manifest_path)
    second = Weld.release_track!(manifest_path)

    assert second.committed?
    refute second.branch_created?
    refute second.commit_sha == first.commit_sha
  end

  test "release tracking can tag and push the projection branch" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])
    remote_root = FixtureCase.unique_tmp_dir("weld_remote")

    FixtureCase.init_git!(repo_root)
    FixtureCase.init_bare_git!(remote_root)
    FixtureCase.git_output!(repo_root, ["remote", "add", "origin", remote_root])

    Weld.release_prepare!(manifest_path)

    result =
      Weld.release_track!(manifest_path,
        tag: "fixture_bundle/rc/2026-04-13-test",
        push: true
      )

    assert result.pushed?
    assert result.tag == "fixture_bundle/rc/2026-04-13-test"
    assert FixtureCase.tag_exists?(repo_root, "fixture_bundle/rc/2026-04-13-test")
    assert FixtureCase.remote_branch_exists?(repo_root, "origin", "projection/fixture_bundle")
  end

  test "prepares and archives internal-only bundles without a tarball" do
    manifest_path = internal_only_monolith_manifest_path()
    prepared = Weld.release_prepare!(manifest_path)

    assert File.dir?(prepared.bundle_path)
    assert File.dir?(prepared.project_path)
    assert File.regular?(prepared.release_metadata_path)
    refute prepared.tarball_path

    metadata =
      prepared.release_metadata_path
      |> File.read!()
      |> Jason.decode!()

    assert metadata["tarball_path"] == nil

    archived = Weld.release_archive!(manifest_path)

    assert File.dir?(archived.archive_path)
    refute File.exists?(Path.join(archived.archive_path, "root_web_monolith-0.1.0.tar"))
  end

  test "release tracking works from internal-only bundles without a tarball" do
    repo_root = FixtureCase.copy_fixture("root_workspace")
    manifest_path = write_internal_only_monolith_manifest(repo_root)

    FixtureCase.init_git!(repo_root)
    prepared = Weld.release_prepare!(manifest_path)

    refute prepared.tarball_path

    result = Weld.release_track!(manifest_path)

    assert result.branch == "projection/root_web_monolith"
    assert result.branch_created?
    assert result.committed?
    assert FixtureCase.branch_exists?(repo_root, "projection/root_web_monolith")
  end

  defp internal_only_monolith_manifest_path do
    repo_root = FixtureCase.copy_fixture("root_workspace")
    write_internal_only_monolith_manifest(repo_root)
  end

  defp write_internal_only_monolith_manifest(repo_root) do
    manifest_path = Path.join([repo_root, "packaging", "weld", "web_monolith.exs"])

    File.write!(
      manifest_path,
      """
      [
        workspace: [
          root: "../.."
        ],
        classify: [
          tooling: [".", "tooling/test_support"],
          proofs: ["proofs/demo"]
        ],
        publication: [
          internal_only: ["tooling/test_support"]
        ],
        artifacts: [
          web_monolith: [
            mode: :monolith,
            roots: ["apps/web"],
            package: [
              name: "root_web_monolith",
              otp_app: :root_web_monolith,
              version: "0.1.0",
              description: "Root web monolith"
            ],
            output: [
              docs: ["README.md"]
            ],
            verify: [
              hex_build: false
            ]
          ]
        ]
      ]
      """
    )

    manifest_path
  end
end
