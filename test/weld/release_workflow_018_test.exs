defmodule Weld.ReleaseWorkflow018Test do
  use ExUnit.Case, async: false

  alias Weld.{Error, FixtureCase, Git, Hash, ReleaseReceipt, ReleaseStatus}

  test "track writes weld.receipt/v1 trailers, annotated tags, same-tree commits, and verifies tags" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    repo_root = Path.expand("../../..", manifest_path)
    remote = FixtureCase.unique_tmp_dir("weld_remote_018")
    FixtureCase.init_git!(repo_root)
    FixtureCase.init_bare_git!(remote)
    Git.run!(repo_root, ["remote", "add", "origin", remote])

    bundle1 = write_bundle!(repo_root, manifest_path, "tarball-v1")

    tracked1 =
      Weld.release_track!(manifest_path,
        artifact: "fixture_bundle",
        tag_release: true,
        push: true
      )

    assert tracked1.committed?
    assert tracked1.tag == "fixture_bundle-v0.1.0"
    assert tracked1.identity == bundle1.identity

    assert {:ok, commit_receipt} =
             ReleaseReceipt.from_commit(repo_root, "refs/heads/projection/fixture_bundle")

    assert commit_receipt.schema == "weld.receipt/v1"
    assert commit_receipt.identity == bundle1.identity
    assert commit_receipt.archive_sha256 == bundle1.archive_sha256
    assert commit_receipt.docs_sha256 == bundle1.docs_sha256

    assert {:ok, %{type: :annotated, receipt: tag_receipt}} =
             ReleaseReceipt.from_tag(repo_root, "fixture_bundle-v0.1.0")

    assert tag_receipt == commit_receipt

    # Exact retry reuses commit and tag cleanly.
    retry =
      Weld.release_track!(manifest_path,
        artifact: "fixture_bundle",
        tag_release: true
      )

    refute retry.committed?
    assert retry.commit_sha == tracked1.commit_sha

    # Verify tag matches local bundle and tarball.
    verified =
      Weld.release_verify_tag!(manifest_path, "fixture_bundle-v0.1.0",
        artifact: "fixture_bundle",
        tarball: bundle1.tarball_path
      )

    assert verified.status == :match

    # Same project tree, new bundle identity (different docs/tarball) creates a receipt commit.
    bundle2 = write_bundle!(repo_root, manifest_path, "tarball-v2")
    assert bundle2.identity != bundle1.identity

    # Conflicting existing tag is rejected.
    assert_raise Error, ~r/already exists with a different commit or release identity/, fn ->
      Weld.release_track!(manifest_path,
        artifact: "fixture_bundle",
        tag: "fixture_bundle-v0.1.0"
      )
    end

    tracked2 =
      Weld.release_track!(manifest_path,
        artifact: "fixture_bundle",
        tag: "fixture_bundle-v0.1.0-rc2"
      )

    assert tracked2.committed?
    assert tracked2.commit_sha != tracked1.commit_sha

    assert {:ok, tip_receipt} =
             ReleaseReceipt.from_commit(repo_root, "refs/heads/projection/fixture_bundle")

    assert tip_receipt.identity == bundle2.identity

    # Legacy lightweight tag is reported without rewriting.
    Git.run!(repo_root, ["tag", "legacy-v0.1.0", tracked1.commit_sha])

    legacy_verify =
      Weld.release_verify_tag!(manifest_path, "legacy-v0.1.0", artifact: "fixture_bundle")

    assert legacy_verify.status == :legacy_tag

    assert_raise Error, ~r/legacy lightweight tag already exists/, fn ->
      Weld.release_track!(manifest_path, artifact: "fixture_bundle", tag: "legacy-v0.1.0")
    end

    # Fresh clone / missing local bundle reports :missing_local when Git receipts agree.
    File.rm_rf!(bundle1.bundle_path)

    missing_local =
      Weld.release_verify_tag!(manifest_path, "fixture_bundle-v0.1.0", artifact: "fixture_bundle")

    assert missing_local.status == :missing_local
  end

  test "release_status classifies states cleanly and --identity pins archive across CURRENT swaps" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    repo_root = Path.expand("../../..", manifest_path)
    FixtureCase.init_git!(repo_root)

    unprepared = Weld.release_status!(manifest_path, artifact: "fixture_bundle")
    assert unprepared.state == :unprepared
    assert unprepared.reasons == [:missing_current]

    bundle1 = write_bundle!(repo_root, manifest_path, "archive-one")
    ready = Weld.release_status!(manifest_path, artifact: "fixture_bundle")
    assert ready.state == :ready
    assert ready.identity == bundle1.identity
    assert ready.has_tarball
    assert ready.publish_workspace == :none
    refute ready.archived

    # Write a second bundle (CURRENT now points to bundle2), then archive bundle1 via --identity.
    bundle2 = write_bundle!(repo_root, manifest_path, "archive-two")
    assert bundle2.identity != bundle1.identity

    archived1 =
      Weld.release_archive!(manifest_path,
        artifact: "fixture_bundle",
        identity: bundle1.identity
      )

    assert archived1.identity == bundle1.identity
    assert File.dir?(archived1.archive_path)

    status1 =
      Weld.release_status!(manifest_path,
        artifact: "fixture_bundle",
        identity: bundle1.identity
      )

    assert status1.archived

    # Dirty worktree marks status stale without raising.
    File.write!(Path.join(repo_root, "UNTRACKED.txt"), "dirty\n")
    dirty = Weld.release_status!(manifest_path, artifact: "fixture_bundle")
    assert dirty.state == :stale
    assert :dirty_worktree in dirty.reasons

    # Commit advances HEAD -> :head_moved.
    Git.run!(repo_root, ["add", "UNTRACKED.txt"])
    Git.run!(repo_root, ["commit", "-m", "advance head"])
    moved = Weld.release_status!(manifest_path, artifact: "fixture_bundle")
    assert moved.state == :stale
    assert :head_moved in moved.reasons

    # --all returns a deterministic list.
    all = Weld.release_status!(manifest_path, all: true)
    assert length(all) == 1
    assert hd(all).artifact == "fixture_bundle"
  end

  test "stage --fresh recovers dirty symlink workspaces and publish verifies rebuilt archive bytes" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    repo_root = Path.expand("../../..", manifest_path)
    FixtureCase.init_git!(repo_root)

    bundle = write_bundle!(repo_root, manifest_path, "exact-tar-bytes")

    staged = Weld.release_stage!(manifest_path, artifact: "fixture_bundle")
    assert staged.identity == bundle.identity
    assert staged.archive_sha256 == bundle.archive_sha256

    # Simulate Mix writing a _build symlink into the publish workspace.
    priv_link = Path.join(staged.project_path, "_build/dev/lib/fixture_bundle/priv")
    File.mkdir_p!(Path.dirname(priv_link))
    File.ln_s!(Path.join(staged.project_path, "README.md"), priv_link)

    assert_raise Error, ~r/re-run with --fresh/, fn ->
      Weld.release_stage!(manifest_path, artifact: "fixture_bundle")
    end

    refreshed = Weld.release_stage!(manifest_path, artifact: "fixture_bundle", fresh: true)
    assert refreshed.refreshed?
    refute File.exists?(priv_link)

    # Track and tag so we can test --tag verification in publish!.
    Weld.release_track!(manifest_path, artifact: "fixture_bundle", tag_release: true)

    scripts_dir = FixtureCase.unique_tmp_dir("weld_fake_cmds")

    build_ok =
      write_script!(scripts_dir, "build_ok.sh", """
      #!/usr/bin/env bash
      printf 'exact-tar-bytes' > fixture_bundle-0.1.0.tar
      """)

    build_bad =
      write_script!(scripts_dir, "build_bad.sh", """
      #!/usr/bin/env bash
      printf 'different-bytes' > fixture_bundle-0.1.0.tar
      """)

    pub_ok = write_script!(scripts_dir, "pub_ok.sh", "#!/usr/bin/env bash\nexit 0\n")
    pub_fail = write_script!(scripts_dir, "pub_fail.sh", "#!/usr/bin/env bash\nexit 1\n")

    # Mismatched rebuild stops before publish_cmd.
    assert_raise Error, ~r/does not match prepared SHA-256/, fn ->
      Weld.release_publish!(manifest_path,
        artifact: "fixture_bundle",
        tag: "fixture_bundle-v0.1.0",
        build_cmd: {build_bad, []},
        publish_cmd: {pub_ok, []}
      )
    end

    # Matching rebuild + successful publish returns published?: true.
    ok_res =
      Weld.release_publish!(manifest_path,
        artifact: "fixture_bundle",
        tag: "fixture_bundle-v0.1.0",
        build_cmd: {build_ok, []},
        publish_cmd: {pub_ok, []}
      )

    assert ok_res.published?
    assert ok_res.exit_status == 0
    assert ok_res.identity == bundle.identity

    # Failed publish returns published?: false with exit status.
    fail_res =
      Weld.release_publish!(manifest_path,
        artifact: "fixture_bundle",
        build_cmd: {build_ok, []},
        publish_cmd: {pub_fail, []}
      )

    refute fail_res.published?
    assert fail_res.exit_status == 1

    # Stale HEAD blocks publish unless --allow-stale is passed.
    File.write!(Path.join(repo_root, "NEXT.txt"), "new\n")
    Git.run!(repo_root, ["add", "NEXT.txt"])
    Git.run!(repo_root, ["commit", "-m", "move head"])

    assert_raise Error, ~r/head_moved/, fn ->
      Weld.release_publish!(manifest_path,
        artifact: "fixture_bundle",
        build_cmd: {build_ok, []},
        publish_cmd: {pub_ok, []}
      )
    end

    allowed =
      Weld.release_publish!(manifest_path,
        artifact: "fixture_bundle",
        allow_stale: true,
        build_cmd: {build_ok, []},
        publish_cmd: {pub_ok, []}
      )

    assert allowed.published?
  end

  test "docs_source_ref_warnings flags mutable source_ref and tag mismatches" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    plan = Weld.Plan.build!(manifest_path, artifact: "fixture_bundle")

    mutable_plan =
      put_in(plan.artifact.package.docs.source_url, "https://github.com/example/fixture")
      |> then(&put_in(&1.artifact.package.docs.source_ref, "main"))

    assert [warning] = ReleaseStatus.docs_source_ref_warnings(mutable_plan)
    assert warning =~ "immutable projection tag"

    pinned_plan = put_in(mutable_plan.artifact.package.docs.source_ref, "fixture_bundle-v0.1.0")
    assert ReleaseStatus.docs_source_ref_warnings(pinned_plan, "fixture_bundle-v0.1.0") == []

    assert [mismatch] =
             ReleaseStatus.docs_source_ref_warnings(pinned_plan, "fixture_bundle-v0.2.0")

    assert mismatch =~ "differs from tracked tag"
  end

  defp write_bundle!(repo_root, manifest_path, tarball_bytes) do
    stage = FixtureCase.unique_tmp_dir("weld_bundle_018")
    project = Path.join(stage, "project")
    docs = Path.join(stage, "docs")
    File.mkdir_p!(project)
    File.mkdir_p!(docs)
    File.cp!(Path.join(repo_root, "README.md"), Path.join(project, "README.md"))
    File.write!(Path.join(docs, "index.html"), "<html>#{tarball_bytes}</html>")
    tarball_name = "fixture_bundle-0.1.0.tar"
    tarball = Path.join(stage, tarball_name)
    File.write!(tarball, tarball_bytes)

    revision = Git.revision(repo_root)
    archive_sha = Hash.sha256_file(tarball)
    docs_sha = Hash.sha256_tree(docs)

    metadata = %{
      artifact: "fixture_bundle",
      package: %{name: "fixture_bundle", version: "0.1.0", otp_app: :fixture_bundle},
      source_revision: revision,
      manifest_path: Path.relative_to(manifest_path, repo_root),
      manifest_digest: Hash.sha256_file(manifest_path),
      weld_version: Weld.version(),
      project_path: "project",
      docs_path: "docs",
      tarball_path: tarball_name,
      integrity: %{
        project_sha256: Hash.sha256_tree(project),
        project_identity: Hash.content_identity(project),
        docs_sha256: docs_sha,
        docs_identity: Hash.content_identity(docs),
        archive_sha256: archive_sha
      }
    }

    identity = Weld.Release.identity(metadata)
    release_root = Path.join(repo_root, ".weld/releases/fixture_bundle")
    bundle = Path.join(release_root, identity)
    File.mkdir_p!(release_root)
    File.rename!(stage, bundle)

    File.write!(
      Path.join(bundle, "release.json"),
      Jason.encode!(Map.put(metadata, :identity, identity), pretty: true)
    )

    File.write!(Path.join(release_root, "CURRENT"), "weld.release/v1 #{identity}\n")

    %{
      identity: identity,
      bundle_path: bundle,
      tarball_path: Path.join(bundle, tarball_name),
      archive_sha256: archive_sha,
      docs_sha256: docs_sha
    }
  end

  defp write_script!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
  end
end
