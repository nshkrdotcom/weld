defmodule Weld.ReleaseWorkflow018Test do
  use ExUnit.Case, async: false

  alias Weld.{Error, FixtureCase, Git, Hash, ReleaseReceipt, ReleaseStatus}
  alias Weld.Shell.Hex

  test "receipt parser refuses duplicated fields, malformed trailers and missing digests" do
    schema = "Weld-Receipt-Schema: weld.receipt/v2"

    assert {:error, "duplicate receipt field:" <> _} =
             ReleaseReceipt.parse(schema <> "\n" <> schema)

    assert {:error, "malformed Weld receipt field"} =
             ReleaseReceipt.parse(schema <> "\nWeld-Identity:")

    assert {:error, "missing required receipt fields:" <> _} = ReleaseReceipt.parse(schema)
  end

  test "status lists all artifacts by default and identifies their release paths" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    {manifest, _binding} = Code.eval_file(manifest_path)
    [artifact] = Keyword.values(manifest[:artifacts])

    File.write!(
      manifest_path,
      inspect(put_in(manifest[:artifacts][:other], artifact), limit: :infinity)
    )

    assert [first, second] = Weld.Commands.release_status!(manifest_path)
    assert [first.artifact, second.artifact] == ["fixture_bundle", "other"]
    assert first.state == :unprepared
    assert first.default_tag == "fixture_bundle-v0.1.0"
    assert first.projection.branch == "projection/fixture_bundle"
    assert String.ends_with?(first.paths.releases, "/.weld/v2/bundles/fixture_bundle")
    assert String.ends_with?(first.paths.full_project, "/.weld/v2/full/fixture_bundle/project")
    assert first.paths.bundle == nil
    assert second.paths.releases != first.paths.releases

    bundle = write_bundle!(Path.expand("../../..", manifest_path), manifest_path, "archive")
    File.write!(bundle.tarball_path, "corrupt")
    File.mkdir_p!(second.paths.releases)
    File.write!(Path.join(second.paths.releases, "CURRENT"), "invalid pointer")

    assert [corrupt, malformed] = Weld.Commands.release_status!(manifest_path)
    assert corrupt.state == :corrupt_bundle
    assert corrupt.identity == bundle.identity
    assert malformed.state == :malformed_pointer

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Task.rerun("weld", ["status", "--manifest", manifest_path, "--format", "json"])
      end)

    assert [%{"state" => "corrupt_bundle"}, %{"state" => "malformed_pointer"}] =
             Jason.decode!(output)["data"]
  end

  test "batch archive continues after an artifact fails and names the failure" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    {manifest, _binding} = Code.eval_file(manifest_path)
    [artifact] = Keyword.values(manifest[:artifacts])

    File.write!(
      manifest_path,
      inspect(put_in(manifest[:artifacts][:a_missing], artifact), limit: :infinity)
    )

    repo_root = Path.expand("../../..", manifest_path)
    FixtureCase.init_git!(repo_root)
    bundle = write_bundle!(repo_root, manifest_path, "archive")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert catch_exit(
                 Mix.Task.rerun(
                   "weld",
                   [
                     "archive",
                     "--manifest",
                     manifest_path,
                     "--all",
                     "--current",
                     "--format",
                     "json"
                   ]
                 )
               ) == {:shutdown, 5}
      end)

    assert %{
             "data" => %{
               "results" => [
                 %{"artifact" => "a_missing", "ok" => false},
                 %{"artifact" => "fixture_bundle", "ok" => true}
               ]
             }
           } = Jason.decode!(output)

    assert File.regular?(
             Path.join([
               repo_root,
               ".weld/v2/archive/fixture_bundle",
               bundle.identity,
               "bundle.json"
             ])
           )
  end

  test "track writes weld.receipt/v2 trailers, annotated tags, same-tree commits, and verifies tags" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    repo_root = Path.expand("../../..", manifest_path)
    remote = FixtureCase.unique_tmp_dir("weld_remote_018")
    FixtureCase.init_git!(repo_root)
    FixtureCase.init_bare_git!(remote)
    Git.run!(repo_root, ["remote", "add", "origin", remote])

    bundle1 = write_bundle!(repo_root, manifest_path, "tarball-v1")

    tracked1 =
      Weld.Commands.release_track!(manifest_path,
        artifact: "fixture_bundle",
        tag_release: true,
        push: true
      )

    assert tracked1.committed?
    assert tracked1.tag == "fixture_bundle-v0.1.0"
    assert tracked1.identity == bundle1.identity

    assert {:ok, commit_receipt} =
             ReleaseReceipt.from_commit(repo_root, "refs/heads/projection/fixture_bundle")

    assert commit_receipt.schema == "weld.receipt/v2"
    assert commit_receipt.identity == bundle1.identity
    assert commit_receipt.archive_sha256 == bundle1.archive_sha256
    assert commit_receipt.docs_sha256 == bundle1.docs_sha256

    assert {:ok, %{type: :annotated, receipt: tag_receipt}} =
             ReleaseReceipt.from_tag(repo_root, "fixture_bundle-v0.1.0")

    assert tag_receipt == commit_receipt

    status = Weld.Commands.release_status!(manifest_path, artifact: "fixture_bundle")
    assert status.projection.tree_matches
    assert status.projection.matches_identity

    # Read the durable receipt in a clone that has no Weld output.
    Git.run!(repo_root, ["push", "origin", "HEAD:refs/heads/main"])
    clone = FixtureCase.unique_tmp_dir("weld_clone_018")
    Git.run!(repo_root, ["clone", "--branch", "main", remote, clone])
    cloned_manifest = Path.join(clone, Path.relative_to(manifest_path, repo_root))

    assert %{status: :missing_local, tag_receipt: ^tag_receipt} =
             Weld.Commands.release_verify_tag!(cloned_manifest, "fixture_bundle-v0.1.0")

    # Exact retry reuses commit and tag cleanly.
    retry =
      Weld.Commands.release_track!(manifest_path,
        artifact: "fixture_bundle",
        tag_release: true
      )

    refute retry.committed?
    assert retry.commit_sha == tracked1.commit_sha

    # Verify tag matches local bundle and tarball.
    verified =
      Weld.Commands.release_verify_tag!(manifest_path, "fixture_bundle-v0.1.0",
        artifact: "fixture_bundle",
        tarball: bundle1.tarball_path
      )

    assert verified.status == :match

    # Same project tree, new bundle identity (different docs/tarball) creates a receipt commit.
    bundle2 = write_bundle!(repo_root, manifest_path, "tarball-v2")
    assert bundle2.identity != bundle1.identity

    status = Weld.Commands.release_status!(manifest_path, artifact: "fixture_bundle")
    assert status.projection.tree_matches
    refute status.projection.matches_identity

    # Conflicting existing tag is rejected.
    assert_raise Error, ~r/already exists with a different commit or release identity/, fn ->
      Weld.Commands.release_track!(manifest_path,
        artifact: "fixture_bundle",
        tag: "fixture_bundle-v0.1.0"
      )
    end

    tracked2 =
      Weld.Commands.release_track!(manifest_path,
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
      Weld.Commands.release_verify_tag!(manifest_path, "legacy-v0.1.0",
        artifact: "fixture_bundle"
      )

    assert legacy_verify.status == :legacy_tag

    assert_raise Error, ~r/legacy lightweight tag already exists/, fn ->
      Weld.Commands.release_track!(manifest_path,
        artifact: "fixture_bundle",
        tag: "legacy-v0.1.0"
      )
    end

    # The receipt selects the artifact even when the manifest has multiple entries.
    {manifest, _binding} = Code.eval_file(manifest_path)
    [artifact] = Keyword.values(manifest[:artifacts])

    File.write!(
      manifest_path,
      inspect(put_in(manifest[:artifacts][:other], artifact), limit: :infinity)
    )

    assert %{status: :match} =
             Weld.Commands.release_verify_tag!(manifest_path, "fixture_bundle-v0.1.0")

    assert %{status: :mismatch} =
             Weld.Commands.release_verify_tag!(manifest_path, "fixture_bundle-v0.1.0",
               artifact: "other"
             )

    assert %{status: :mismatch} =
             Weld.Commands.release_verify_tag!(manifest_path, "fixture_bundle-v0.1.0",
               identity: bundle2.identity
             )

    # Fresh clone / missing local bundle reports :missing_local when Git receipts agree.
    File.rm_rf!(bundle1.bundle_path)

    missing_local =
      Weld.Commands.release_verify_tag!(manifest_path, "fixture_bundle-v0.1.0",
        artifact: "fixture_bundle"
      )

    assert missing_local.status == :missing_local
  end

  test "release_status classifies states cleanly and --identity pins archive across CURRENT swaps" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    repo_root = Path.expand("../../..", manifest_path)
    FixtureCase.init_git!(repo_root)

    unprepared = Weld.Commands.release_status!(manifest_path, artifact: "fixture_bundle")
    assert unprepared.state == :unprepared
    assert unprepared.reasons == [:missing_current]

    bundle1 = write_bundle!(repo_root, manifest_path, "archive-one")
    ready = Weld.Commands.release_status!(manifest_path, artifact: "fixture_bundle")
    assert ready.state == :ready
    assert ready.identity == bundle1.identity
    assert ready.has_tarball
    refute ready.archived

    # Write a second bundle (CURRENT now points to bundle2), then archive bundle1 via --identity.
    bundle2 = write_bundle!(repo_root, manifest_path, "archive-two")
    assert bundle2.identity != bundle1.identity

    archived1 =
      Weld.Commands.release_archive!(manifest_path,
        artifact: "fixture_bundle",
        identity: bundle1.identity
      )

    assert archived1.identity == bundle1.identity
    assert File.dir?(archived1.archive_path)

    status1 =
      Weld.Commands.release_status!(manifest_path,
        artifact: "fixture_bundle",
        identity: bundle1.identity
      )

    assert status1.archived

    # Dirty worktree marks status stale without raising.
    File.write!(Path.join(repo_root, "UNTRACKED.txt"), "dirty\n")
    dirty = Weld.Commands.release_status!(manifest_path, artifact: "fixture_bundle")
    assert dirty.state == :stale
    assert :dirty_worktree in dirty.reasons

    # Commit advances HEAD -> :head_moved.
    Git.run!(repo_root, ["add", "UNTRACKED.txt"])
    Git.run!(repo_root, ["commit", "-m", "advance head"])
    moved = Weld.Commands.release_status!(manifest_path, artifact: "fixture_bundle")
    assert moved.state == :stale
    assert :head_moved in moved.reasons

    # --all returns a deterministic list.
    all = Weld.Commands.release_status!(manifest_path, all: true)
    assert length(all) == 1
    assert hd(all).artifact == "fixture_bundle"
  end

  test "stage isolates edits and run lookup identifies each review copy" do
    {manifest, plan, bundle} = publication_fixture!()
    first = Weld.Release.stage!(plan, identity: bundle.identity)
    File.write!(Path.join(first.project_path, "README.md"), "local edit")
    second = Weld.Release.stage!(plan, identity: bundle.identity)
    refute first.project_path == second.project_path
    refute File.read!(Path.join(second.project_path, "README.md")) == "local edit"

    request =
      Weld.CLI.parse!("path", ["--manifest", manifest, "--kind", "run", "--run", second.run])

    assert {:ok, %{path: path, exists: true}} = Weld.run(request)
    assert path == second.project_path
  end

  test "publication requires confirmation and dry-run makes no transport calls" do
    {_manifest, plan, bundle} = publication_fixture!()

    transport = %{
      read: fn _, _, _ -> flunk("unexpected remote read") end,
      write: fn _, _, _, _ -> flunk("unexpected upload") end
    }

    assert %{dry_run: true, archive_sha256: sha} =
             Weld.Release.publish!(plan,
               identity: bundle.identity,
               transport: transport,
               dry_run: true
             )

    assert sha == bundle.archive_sha256

    assert_raise Error, ~r/requires --yes/, fn ->
      Weld.Release.publish!(plan, identity: bundle.identity, transport: transport)
    end
  end

  test "publication submits exactly the pinned package and docs bytes" do
    {_manifest, plan, bundle} = publication_fixture!()
    parent = self()
    {:ok, server} = Agent.start_link(fn -> %{} end)

    transport = %{
      read: fn part, _, _ ->
        case Agent.get(server, &Map.get(&1, part)) do
          nil -> {:ok, {404, [], ""}}
          body -> {:ok, {200, [], body}}
        end
      end,
      write: fn part, name, version, body ->
        send(parent, {part, name, version, Hash.sha256_binary(body)})
        Agent.update(server, &Map.put(&1, part, body))
        {:ok, {201, [], ""}}
      end
    }

    assert %{state: "confirmed", completed?: true} =
             Weld.Release.publish!(plan,
               identity: bundle.identity,
               transport: transport,
               yes: true
             )

    assert_receive {:package, "fixture_bundle", "0.1.0", archive_sha}
    assert_receive {:docs, "fixture_bundle", "0.1.0", docs_sha}
    assert archive_sha == bundle.archive_sha256
    assert docs_sha == Hash.sha256_file(Path.join(bundle.bundle_path, "docs.tar.gz"))
  end

  test "crash after docs submission blocks a repeat; read-only reconciliation can confirm it" do
    {_manifest, plan, bundle} = publication_fixture!()
    {:ok, server} = Agent.start_link(fn -> %{package: File.read!(bundle.tarball_path)} end)

    transport = %{
      read: fn part, _, _ ->
        case Agent.get(server, &Map.get(&1, part)) do
          nil -> {:ok, {404, [], ""}}
          body -> {:ok, {200, [], body}}
        end
      end,
      write: fn :docs, _, _, body ->
        Agent.update(server, &Map.put(&1, :docs, body))
        raise Error, "connection failed after submission"
      end
    }

    opts = [identity: bundle.identity, transport: transport, yes: true]
    assert_raise Error, ~r/connection failed/, fn -> Weld.Release.publish!(plan, opts) end
    assert_raise Error, ~r/unresolved/, fn -> Weld.Release.publish!(plan, opts) end
    assert %{state: "confirmed"} = Weld.Release.reconcile!(plan, opts)
  end

  defp publication_fixture! do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    plan = Weld.Plan.build!(manifest)
    root = plan.manifest.repo_root
    FixtureCase.init_git!(root)
    {manifest, plan, write_bundle!(root, manifest, "exact package archive bytes")}
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

    docs_archive = Hex.freeze_docs!(docs, Path.join(stage, "docs.tar.gz"))

    metadata = %{
      schema: "weld.bundle/2",
      lock_sha256: nil,
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
        docs_archive_sha256: Hash.sha256_file(docs_archive),
        docs_identity: Hash.content_identity(docs),
        archive_sha256: archive_sha
      }
    }

    identity = Weld.Release.identity(metadata)
    release_root = Path.join(repo_root, ".weld/v2/bundles/fixture_bundle")
    bundle = Path.join(release_root, identity)
    File.mkdir_p!(release_root)
    File.rename!(stage, bundle)

    File.write!(
      Path.join(bundle, "bundle.json"),
      Jason.encode!(Map.put(metadata, :identity, identity), pretty: true)
    )

    File.write!(
      Path.join(release_root, "CURRENT"),
      Jason.encode!(%{schema: "weld.current/2", artifact: "fixture_bundle", bundle_id: identity})
    )

    %{
      identity: identity,
      bundle_path: bundle,
      tarball_path: Path.join(bundle, tarball_name),
      archive_sha256: archive_sha,
      docs_sha256: docs_sha
    }
  end
end
