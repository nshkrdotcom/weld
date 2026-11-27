defmodule Weld.ReleaseWorkflow018Test do
  use ExUnit.Case, async: false

  alias Weld.Core.Identity
  alias Weld.{Error, FixtureCase, Git, Hash, Output, Release, ReleaseReceipt, ReleaseStatus}

  test "receipt parser refuses duplicated fields, malformed trailers and missing digests" do
    {_, _, bundle} = publication_fixture!()
    trailer = ReleaseReceipt.format_trailers(nil, bundle.metadata)
    assert {:ok, receipt} = ReleaseReceipt.parse(trailer)
    assert receipt["schema"] == "weld.receipt/2"
    assert {:error, _} = ReleaseReceipt.parse(trailer <> "\n" <> trailer)
    assert {:error, _} = ReleaseReceipt.parse("Weld-Receipt: invalid=")
    assert {:error, _} = ReleaseReceipt.parse("Weld-Receipt-Schema: weld.receipt/v2")

    missing =
      Map.delete(receipt, "docs_id") |> Identity.canonical() |> Base.url_encode64(padding: false)

    assert {:error, _} = ReleaseReceipt.parse("Weld-Receipt: " <> missing)
    noncanonical = Jason.encode!(receipt, pretty: true) |> Base.url_encode64(padding: false)
    assert {:error, _} = ReleaseReceipt.parse("Weld-Receipt: " <> noncanonical)
  end

  test "status lists all artifacts by default and identifies their release paths" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    {source, _} = Code.eval_file(manifest)
    [artifact] = Keyword.values(source[:artifacts])
    File.write!(manifest, inspect(put_in(source[:artifacts][:other], artifact), limit: :infinity))
    root = Path.expand("../../..", manifest)
    FixtureCase.init_git!(root)
    assert [first, second] = Weld.Commands.release_status!(manifest)
    assert [first.artifact, second.artifact] == ["fixture_bundle", "other"]
    assert first.state == :unprepared
    assert first.default_tag == "fixture_bundle-v0.1.0"
    assert String.ends_with?(first.paths.releases, "/.weld/v2/bundles/fixture_bundle")
    assert String.ends_with?(first.paths.full_project, "/.weld/v2/full/fixture_bundle/project")
    bundle = FixtureCase.write_tracking_fixture!(root, manifest, hex: true)
    File.write!(bundle.tarball_path, "corrupt")
    Output.write_atomic!(Output.path(root, ["current", "other"]), "invalid pointer")
    before = state_inventory(root)
    assert [corrupt, malformed] = Weld.Commands.release_status!(manifest)
    assert corrupt.integrity == :corrupt
    assert corrupt.identity == bundle.identity
    assert malformed.integrity == :corrupt
    assert state_inventory(root) == before

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Task.rerun("weld", ["status", "--manifest", manifest, "--format", "json"])
      end)

    assert [%{"integrity" => "corrupt"}, %{"integrity" => "corrupt"}] =
             Jason.decode!(output)["data"]
  end

  test "batch archive continues after an artifact fails and names the failure" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    {source, _} = Code.eval_file(manifest)
    [artifact] = Keyword.values(source[:artifacts])

    File.write!(
      manifest,
      inspect(put_in(source[:artifacts][:a_missing], artifact), limit: :infinity)
    )

    root = Path.expand("../../..", manifest)
    FixtureCase.init_git!(root)
    bundle = FixtureCase.write_tracking_fixture!(root, manifest)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert catch_exit(
                 Mix.Task.rerun("weld", [
                   "archive",
                   "--manifest",
                   manifest,
                   "--all",
                   "--current",
                   "--format",
                   "json"
                 ])
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
             Output.path(root, ["archives", "fixture_bundle", bundle.identity, "bundle.json"])
           )
  end

  test "track writes canonical receipts, annotated tags, same-tree commits, and verifies tags" do
    {manifest, plan, first} = publication_fixture!()
    root = plan.manifest.repo_root
    remote = FixtureCase.unique_tmp_dir("weld_remote_receipt")
    FixtureCase.init_bare_git!(remote)
    Git.run!(root, ["remote", "add", "origin", remote])
    source_head = Git.revision(root)
    tracked = Release.track!(plan, identity: first.identity, tag_release: true, push: true)
    assert tracked.committed?
    assert tracked.tag == "fixture_bundle-v0.1.0"
    assert Git.revision(root) == source_head
    assert {:ok, receipt} = ReleaseReceipt.from_commit(root, tracked.commit_sha)
    assert receipt["bundle_id"] == first.identity
    assert receipt["archive_sha256"] == first.archive_sha256
    assert Git.project_id(root, tracked.commit_sha) == receipt["project_id"]

    assert {:ok, %{type: :annotated, receipt: ^receipt}} =
             ReleaseReceipt.from_tag(root, tracked.tag)

    assert %{status: :match, tree: :match} =
             ReleaseStatus.verify_tag(root, tracked.tag, tarball: first.tarball_path)

    retry = Release.track!(plan, identity: first.identity, tag_release: true, push: true)
    refute retry.committed?
    assert retry.commit_sha == tracked.commit_sha
    Git.run!(root, ["push", "origin", "HEAD:refs/heads/main"])
    clone = FixtureCase.unique_tmp_dir("weld_receipt_clone")
    Git.run!(root, ["clone", "--branch", "main", remote, clone])

    assert %{status: :missing_local, tree: :match, tag_receipt: ^receipt} =
             ReleaseStatus.verify_tag(clone, tracked.tag)

    second =
      FixtureCase.write_tracking_fixture!(root, manifest, hex: true, docs: "different exact docs")

    assert second.identity != first.identity
    assert second.metadata["project_id"] == first.metadata["project_id"]
    status = ReleaseStatus.status(plan)
    assert status.projection.tree_matches
    refute status.projection.matches_identity
    before = Git.ref_oid(root, "refs/heads/" <> tracked.branch)

    assert_raise Error, ~r/already exists/, fn ->
      Release.track!(plan, identity: second.identity, tag: tracked.tag)
    end

    assert Git.ref_oid(root, "refs/heads/" <> tracked.branch) == before
    changed = Release.track!(plan, identity: second.identity, tag: "fixture_bundle-v0.1.0-rc2")
    assert changed.committed?
    assert changed.commit_sha != tracked.commit_sha
    Git.run!(root, ["tag", "unsupported-lightweight", changed.commit_sha])
    assert %{status: :mismatch} = ReleaseStatus.verify_tag(root, "unsupported-lightweight")

    assert_raise Error, fn ->
      Release.track!(plan, identity: second.identity, tag: "unsupported-lightweight")
    end

    assert %{status: :mismatch} = ReleaseStatus.verify_tag(root, tracked.tag, artifact: "other")

    assert %{status: :mismatch} =
             ReleaseStatus.verify_tag(root, tracked.tag, identity: second.identity)

    File.rm_rf!(first.bundle_path)
    assert %{status: :missing_local, tree: :match} = ReleaseStatus.verify_tag(root, tracked.tag)
  end

  test "release_status classifies states and explicit pins archive across current swaps" do
    {manifest, plan, first} = publication_fixture!()

    assert %{state: :ready, integrity: :valid, qualification: :passed} =
             ReleaseStatus.status(plan)

    second =
      FixtureCase.write_tracking_fixture!(plan.manifest.repo_root, manifest,
        hex: true,
        docs: "second"
      )

    refute first.identity == second.identity
    archived = Release.archive!(plan, identity: first.identity)
    assert archived.identity == first.identity
    assert Release.archive!(plan, identity: first.identity) == archived
    assert ReleaseStatus.status(plan, identity: first.identity).archived
    File.write!(Path.join(plan.manifest.repo_root, "UNTRACKED.txt"), "dirty\n")
    assert :dirty_worktree in ReleaseStatus.status(plan).reasons
    FixtureCase.commit_all!(plan.manifest.repo_root, "advance source")
    assert :head_moved in ReleaseStatus.status(plan).reasons
    assert [one] = Weld.Commands.release_status!(manifest, all: true)
    assert one.artifact == "fixture_bundle"
  end

  test "local tracking can later atomically push over a proved remote ancestor" do
    {manifest, plan, first} = publication_fixture!()
    root = plan.manifest.repo_root
    remote = FixtureCase.unique_tmp_dir("weld_local_first_remote")
    FixtureCase.init_bare_git!(remote)
    Git.run!(root, ["remote", "add", "origin", remote])
    source_head = Git.revision(root)
    published = Release.track!(plan, identity: first.identity, push: true)
    branch = "refs/heads/" <> published.branch

    second =
      FixtureCase.write_tracking_fixture!(root, manifest,
        hex: true,
        docs: "locally reviewed docs"
      )

    local = Release.track!(plan, identity: second.identity)
    assert local.committed?
    assert local.commit_sha != published.commit_sha
    assert Git.remote_refs(root, "origin", [branch]) == {:ok, %{branch => published.commit_sha}}

    pushed = Release.track!(plan, identity: second.identity, tag: "local-review-v2", push: true)
    assert pushed.pushed?
    refute pushed.committed?
    assert pushed.commit_sha == local.commit_sha
    tag_ref = "refs/tags/" <> pushed.tag

    assert Git.remote_refs(root, "origin", [branch, tag_ref]) ==
             {:ok, %{branch => local.commit_sha, tag_ref => Git.ref_oid(root, tag_ref)}}

    assert Git.revision(root) == source_head
  end

  test "remote divergence or unavailable ancestry proof cannot advance local refs" do
    {manifest, plan, first} = publication_fixture!()
    root = plan.manifest.repo_root
    remote = FixtureCase.unique_tmp_dir("weld_divergent_remote")
    FixtureCase.init_bare_git!(remote)
    Git.run!(root, ["remote", "add", "origin", remote])
    published = Release.track!(plan, identity: first.identity, push: true)
    branch = "refs/heads/" <> published.branch
    second = FixtureCase.write_tracking_fixture!(root, manifest, hex: true, docs: "local branch")
    local = Release.track!(plan, identity: second.identity)

    scratch = Output.temporary!(root, "staging")
    tree = Git.run!(root, ["rev-parse", published.commit_sha <> "^{tree}"])

    divergent =
      Git.write_commit!(root, tree, published.commit_sha, "Other projection history\n", scratch)

    Git.run!(root, ["push", "origin", divergent <> ":" <> branch])
    refute Git.fast_forward_from?(root, divergent, local.commit_sha)

    refute Git.fast_forward_from?(
             root,
             String.duplicate("f", byte_size(local.commit_sha)),
             local.commit_sha
           )

    third =
      FixtureCase.write_tracking_fixture!(root, manifest,
        hex: true,
        docs: "must remain untracked"
      )

    assert_raise Error, ~r/remote.*conflict/, fn ->
      Release.track!(plan, identity: third.identity, tag: "must-not-be-created", push: true)
    end

    assert Git.ref_oid(root, branch) == local.commit_sha
    refute Git.tag_exists?(root, "must-not-be-created")
    assert Git.remote_refs(root, "origin", [branch]) == {:ok, %{branch => divergent}}
  end

  test "tracked-file observations remain checkout-relative from a nested workspace" do
    {manifest, plan, _bundle} = publication_fixture!()
    tracked = Git.tracked_files(Path.dirname(manifest))
    assert MapSet.member?(tracked, Path.relative_to(manifest, plan.manifest.repo_root))
    refute MapSet.member?(tracked, Path.basename(manifest))
  end

  test "stage isolates edits and run lookup identifies each review copy" do
    {manifest, plan, bundle} = publication_fixture!()
    first = Release.stage!(plan, identity: bundle.identity)
    File.write!(Path.join(first.project_path, "README.md"), "local edit")
    second = Release.stage!(plan, identity: bundle.identity)
    refute first.project_path == second.project_path
    refute File.read!(Path.join(second.project_path, "README.md")) == "local edit"

    assert Output.run_path(plan.manifest.repo_root, "fixture_bundle", second.run) ==
             second.run_path

    request =
      Weld.CLI.parse!("path", ["--manifest", manifest, "--kind", "run", "--run", second.run])

    assert {:ok, %{path: path, exists: true}} = Weld.run(request)
    assert path == second.run_path
    assert Path.join(path, "project") == second.project_path
  end

  test "publication requires confirmation and dry-run makes no transport calls" do
    {_, plan, bundle} = publication_fixture!()

    transport =
      transport(fn _, _, _ -> flunk("unexpected read") end, fn _, _, _, _ ->
        flunk("unexpected write")
      end)

    assert %{dry_run: true, archive_sha256: sha} =
             Release.publish!(plan,
               identity: bundle.identity,
               transport: transport,
               dry_run: true
             )

    assert sha == bundle.archive_sha256

    assert_raise Error, ~r/requires --yes/, fn ->
      Release.publish!(plan, identity: bundle.identity, transport: transport)
    end
  end

  test "publication submits exactly the pinned package and docs bytes" do
    {_, plan, bundle} = publication_fixture!()
    parent = self()
    {:ok, remote} = Agent.start_link(fn -> %{} end)

    transport =
      transport(fn part, _, _ -> remote_value(remote, part) end, fn part, name, version, body ->
        send(parent, {part, name, version, Identity.raw(body)})
        Agent.update(remote, &Map.put(&1, part, body))
        {:ok, {201, [], %{}}}
      end)

    assert %{state: "confirmed", completed?: true} =
             Release.publish!(plan, identity: bundle.identity, transport: transport, yes: true)

    assert_receive {:package, "fixture_bundle", "0.1.0", archive_sha}
    assert_receive {:docs, "fixture_bundle", "0.1.0", docs_sha}
    assert archive_sha == bundle.archive_sha256
    assert docs_sha == bundle.metadata["docs_archive_sha256"]

    assert %{state: "confirmed"} =
             Release.publish!(plan, identity: bundle.identity, transport: transport, yes: true)

    refute_receive {:package, _, _, _}
    refute_receive {:docs, _, _, _}
  end

  test "crash after docs submission blocks a repeat and reconciliation only reads" do
    {_, plan, bundle} = publication_fixture!()
    {:ok, remote} = Agent.start_link(fn -> %{package: File.read!(bundle.tarball_path)} end)

    transport =
      transport(fn part, _, _ -> remote_value(remote, part) end, fn :docs, _, _, body ->
        Agent.update(remote, &Map.put(&1, :docs, body))
        raise Error, "connection failed after submission"
      end)

    opts = [identity: bundle.identity, transport: transport, yes: true]
    assert %{state: "unknown", completed?: false} = Release.publish!(plan, opts)
    assert_raise Error, ~r/unresolved/, fn -> Release.publish!(plan, opts) end
    read_only = %{transport | write: fn _, _, _, _ -> flunk("reconcile writes remotely") end}

    assert %{state: "confirmed"} =
             Release.reconcile!(plan, Keyword.put(opts, :transport, read_only))
  end

  test "docs_source_ref_warnings flags mutable source_ref and tag mismatches" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    plan = Weld.Plan.build!(manifest, artifact: "fixture_bundle")

    mutable =
      put_in(plan.artifact.package.docs.source_url, "https://github.com/example/fixture")
      |> then(&put_in(&1.artifact.package.docs.source_ref, "main"))

    assert [warning] = ReleaseStatus.docs_source_ref_warnings(mutable)
    assert warning =~ "immutable projection tag"
    pinned = put_in(mutable.artifact.package.docs.source_ref, "fixture_bundle-v0.1.0")
    assert ReleaseStatus.docs_source_ref_warnings(pinned, "fixture_bundle-v0.1.0") == []
    assert [mismatch] = ReleaseStatus.docs_source_ref_warnings(pinned, "fixture_bundle-v0.2.0")
    assert mismatch =~ "differs from the tracked projection tag"
  end

  defp publication_fixture! do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    root = Path.expand("../../..", manifest)
    FixtureCase.init_git!(root)
    plan = Weld.Plan.build!(manifest)
    {manifest, plan, FixtureCase.write_tracking_fixture!(root, manifest, hex: true)}
  end

  defp transport(read, write),
    do: %{
      read: read,
      write: write,
      trust: %{
        authenticated: true,
        authoritative: true,
        destination: "http://127.0.0.1:56789",
        adapter: "hex_core/0.21.1",
        conformance: :loopback
      }
    }

  defp remote_value(remote, part) do
    case Agent.get(remote, &Map.get(&1, part)) do
      nil ->
        {:ok, %{state: "absent", authoritative: true, code: "authenticated_fixture_noncommit"}}

      bytes ->
        {:ok,
         %{
           state: "confirmed",
           authoritative: true,
           sha256: Identity.raw(bytes),
           source: "fixture"
         }}
    end
  end

  defp state_inventory(root), do: Hash.observation(Output.path(root, []))
end
