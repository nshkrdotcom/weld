defmodule Weld.BundleIntegrityTest do
  use ExUnit.Case, async: false
  alias Weld.{Error, FixtureCase, Git, Hash, Output, Release, ReleaseReceipt, ReleaseStatus}
  alias Weld.Core.Identity

  setup do
    root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(root)
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    bundle = FixtureCase.write_tracking_fixture!(root, manifest, hex: true)

    %{
      root: root,
      manifest: manifest,
      bundle: bundle,
      selector: %{repo_root: root, artifact: "fixture_bundle"}
    }
  end

  test "all bundle keys are mandatory and unknown evidence fields reject", %{bundle: bundle} do
    for key <- Map.keys(bundle.metadata) do
      path = copy_bundle(bundle)
      metadata = Map.delete(bundle.metadata, key)
      File.write!(Path.join(path, "bundle.json"), Identity.canonical(metadata))

      assert_raise Error, fn ->
        ReleaseStatus.validate_bundle_integrity!(path, bundle.identity)
      end
    end

    for name <- ~w(inventory.json qualification.json bundle.json) do
      path = copy_bundle(bundle)
      file = Path.join(path, name)
      value = File.read!(file) |> Jason.decode!() |> Map.put("future_optional_integrity", nil)
      File.write!(file, Identity.canonical(value))

      assert_raise Error, fn ->
        ReleaseStatus.validate_bundle_integrity!(path, bundle.identity)
      end
    end
  end

  test "canonical JSON rejects duplicate keys and byte-equivalent noncanonical forms", %{
    bundle: bundle
  } do
    path = copy_bundle(bundle)
    target = Path.join(path, "bundle.json")
    File.write!(target, Jason.encode!(bundle.metadata, pretty: true))

    assert_raise Error, ~r/noncanonical/, fn ->
      ReleaseStatus.validate_bundle_integrity!(path, bundle.identity)
    end

    original = Identity.canonical(bundle.metadata)
    File.write!(target, String.replace_prefix(original, "{", "{\"schema\":\"weld.bundle/2\","))
    assert_raise Error, fn -> ReleaseStatus.validate_bundle_integrity!(path, bundle.identity) end
  end

  test "project and docs sets, executable modes and both archive bodies are exact", %{
    bundle: bundle
  } do
    changes = [
      fn root -> File.write!(Path.join(root, "project/injected"), "extra") end,
      fn root -> File.mkdir!(Path.join(root, "project/extra-empty")) end,
      fn root -> File.chmod!(Path.join(root, "project/README.md"), 0o755) end,
      fn root -> File.chmod!(Path.join(root, "project/README.md"), 0o600) end,
      fn root -> File.write!(Path.join(root, "docs/index.html"), "changed") end,
      fn root -> File.rm!(Path.join(root, "docs/index.html")) end,
      fn root -> File.write!(Path.join(root, "package.tar"), "extra", [:append]) end,
      fn root -> File.write!(Path.join(root, "docs.tar.gz"), "extra", [:append]) end,
      fn root -> File.ln_s!("README.md", Path.join(root, "project/escape")) end
    ]

    for change <- changes do
      path = copy_bundle(bundle)
      change.(path)

      assert_raise Error, fn ->
        ReleaseStatus.validate_bundle_integrity!(path, bundle.identity)
      end
    end
  end

  test "self-consistent outer hashes cannot conceal mismatched cross bindings or a skipped required gate",
       %{bundle: bundle} do
    for change <- [
          fn metadata, inventory, proof ->
            {Map.put(metadata, "layout", "flat"), inventory, proof}
          end,
          fn metadata, inventory, proof ->
            {Map.put(metadata, "project_id", String.duplicate("0", 64)), inventory, proof}
          end,
          fn metadata, inventory, proof ->
            gates =
              Enum.map(proof["gates"], fn gate ->
                if gate["id"] == "G12",
                  do: %{gate | "status" => "skip", "skip_reason" => "not allowed"},
                  else: gate
              end)

            {metadata, inventory, %{proof | "gates" => gates}}
          end,
          fn metadata, inventory, proof ->
            {metadata, inventory, Map.put(proof, "lock_sha256", String.duplicate("1", 64))}
          end
        ] do
      {path, id} = rewrite_evidence(bundle, change)
      assert_raise Error, fn -> ReleaseStatus.validate_bundle_integrity!(path, id) end
    end
  end

  test "source provenance is bound to the exact manifest input fact", %{bundle: bundle} do
    for changes <- [
          %{"manifest_sha256" => String.duplicate("0", 64)},
          %{"manifest_path" => "packaging/weld/unobserved.exs"}
        ] do
      {path, id} =
        rewrite_evidence(bundle, fn metadata, inventory, proof ->
          source = Map.merge(metadata["source"], changes)
          {Map.put(metadata, "source", source), inventory, Map.put(proof, "source", source)}
        end)

      assert_raise Error, ~r/manifest input/, fn ->
        ReleaseStatus.validate_bundle_integrity!(path, id)
      end
    end
  end

  test "normalized artifact identity cannot disagree after recomputing plan and bundle hashes", %{
    bundle: bundle
  } do
    for {keys, value} <- [
          {["id"], "another_artifact"},
          {["mode"], "monolith"},
          {["package", "name"], "another_package"},
          {["package", "version"], "9.0.0"}
        ] do
      {path, id} =
        rewrite_evidence(bundle, fn metadata, inventory, proof ->
          inventory = put_in(inventory, ["normalized_metadata", "artifact" | keys], value)
          {metadata, inventory, proof}
        end)

      assert_raise Error, ~r/normalized artifact/, fn ->
        ReleaseStatus.validate_bundle_integrity!(path, id)
      end
    end
  end

  test "internal bundle package identity is also bound to normalized artifact metadata", %{
    root: root,
    manifest: manifest
  } do
    bundle = FixtureCase.write_tracking_fixture!(root, manifest)

    for {field, value} <- [{"package", "another_package"}, {"version", "9.0.0"}] do
      {path, id} =
        rewrite_evidence(bundle, fn metadata, inventory, proof ->
          {Map.put(metadata, field, value), inventory, proof}
        end)

      assert_raise Error, ~r/normalized artifact/, fn ->
        ReleaseStatus.validate_bundle_integrity!(path, id)
      end
    end
  end

  test "frozen empty directory set must match the compiler layout", %{bundle: bundle} do
    {path, id} =
      rewrite_evidence(bundle, fn metadata, inventory, proof ->
        {metadata, put_in(inventory, ["layout", "empty_dirs"], ["unmaterialized"]), proof}
      end)

    assert_raise Error, ~r/empty director/, fn ->
      ReleaseStatus.validate_bundle_integrity!(path, id)
    end
  end

  test "gate archive and docs observations bind to the frozen proof identities", %{bundle: bundle} do
    for {gate_id, field, value} <- [
          {"G08", "archive_sha256", String.duplicate("0", 64)},
          {"G08", "package_id", String.duplicate("1", 64)},
          {"G08", "entries", 999},
          {"G11", "docs_id", String.duplicate("2", 64)},
          {"G11", "docs_archive_sha256", String.duplicate("3", 64)},
          {"G11", "roundtrip_verified", false}
        ] do
      {path, id} =
        rewrite_evidence(bundle, fn metadata, inventory, proof ->
          gates =
            Enum.map(proof["gates"], fn gate ->
              if gate["id"] == gate_id, do: put_in(gate, ["facts", field], value), else: gate
            end)

          {metadata, inventory, Map.put(proof, "gates", gates)}
        end)

      assert_raise Error, ~r/gate.*frozen proof/, fn ->
        ReleaseStatus.validate_bundle_integrity!(path, id)
      end
    end
  end

  test "status rejects a valid bundle copied under another artifact selector", %{
    root: root,
    bundle: bundle
  } do
    misplaced = Output.path(root, ["bundles", "other", bundle.identity])
    File.mkdir_p!(Path.dirname(misplaced))
    File.cp_r!(bundle.bundle_path, misplaced)

    Output.write_atomic!(
      Output.path(root, ["current", "other"]),
      Identity.canonical(%{
        "schema" => "weld.current/2",
        "artifact" => "other",
        "bundle_id" => bundle.identity
      })
    )

    result = ReleaseStatus.status(%{repo_root: root, artifact: "other"})
    assert result.integrity == :corrupt
    assert result.qualification == :not_qualified
    assert result.next_command == nil
    assert Enum.any?(result.reasons, &String.contains?(&1, "artifact and bundle disagree"))
  end

  test "historical pin stages tracks and archives without the current manifest", %{
    root: root,
    manifest: manifest,
    bundle: bundle,
    selector: selection
  } do
    File.rm!(manifest)
    assert Release.bundle_path(selection, bundle.identity) == bundle.bundle_path
    staged = Release.stage!(selection, identity: bundle.identity)

    assert File.read!(Path.join(staged.project_path, "README.md")) ==
             File.read!(Path.join(bundle.bundle_path, "project/README.md"))

    tracked = Release.track!(selection, identity: bundle.identity, tag_release: true)
    assert Git.project_id(root, tracked.commit_sha) == bundle.metadata["project_id"]
    archived = Release.archive!(selection, identity: bundle.identity)
    assert Hash.observation(archived.archive_path) == Hash.observation(bundle.bundle_path)

    assert :current_manifest_unavailable in ReleaseStatus.status(selection,
             identity: bundle.identity
           ).reasons

    assert_raise Error, ~r/freshness/, fn ->
      Release.publish!(selection, identity: bundle.identity, dry_run: true)
    end

    assert %{dry_run: true} =
             Release.publish!(selection,
               identity: bundle.identity,
               dry_run: true,
               allow_source_drift: true
             )
  end

  test "archive is idempotent while corrupt immutable destinations fail closed", %{
    bundle: bundle,
    selector: selection
  } do
    first = Release.archive!(selection, identity: bundle.identity)
    before = Hash.observation(first.archive_path)
    assert Release.archive!(selection, identity: bundle.identity) == first
    assert Hash.observation(first.archive_path) == before
    File.write!(Path.join(first.archive_path, "docs/extra.html"), "unqualified")
    assert_raise Error, fn -> Release.archive!(selection, identity: bundle.identity) end
    assert File.read!(Path.join(first.archive_path, "docs/extra.html")) == "unqualified"
  end

  test "tag-only verification hashes actual Git blobs and executable flags", %{
    root: root,
    bundle: bundle,
    selector: selection
  } do
    good = Release.track!(selection, identity: bundle.identity, tag_release: true)
    scratch = Output.temporary!(root, "staging")
    project = Path.join(scratch, "project")
    File.cp_r!(Path.join(bundle.bundle_path, "project"), project)
    File.chmod!(Path.join(project, "README.md"), 0o755)
    {tree, _} = Git.write_project_tree!(root, project, scratch)
    message = ReleaseReceipt.format_commit_message(nil, bundle.metadata)
    bad_commit = Git.write_commit!(root, tree, nil, message, scratch)
    tag = "tampered-mode"

    tag_oid =
      Git.write_tag!(
        root,
        tag,
        bad_commit,
        ReleaseReceipt.format_tag_message(nil, bundle.metadata, tag),
        scratch
      )

    Git.transaction!(root, [{"refs/tags/" <> tag, tag_oid, nil}])
    File.rm_rf!(bundle.bundle_path)
    assert %{status: :missing_local, tree: :match} = ReleaseStatus.verify_tag(root, good.tag)
    assert %{status: :mismatch} = ReleaseStatus.verify_tag(root, tag)
  end

  test "local ref CAS rejects a race without creating the companion tag", %{
    root: root,
    bundle: bundle,
    selector: selection
  } do
    tracked = Release.track!(selection, identity: bundle.identity)
    ref = "refs/heads/" <> tracked.branch

    assert_raise Error, ~r/transaction/, fn ->
      Git.transaction!(root, [
        {ref, tracked.commit_sha, Git.revision(root)},
        {"refs/tags/cas-companion", tracked.commit_sha, nil}
      ])
    end

    assert Git.ref_oid(root, ref) == tracked.commit_sha
    refute Git.tag_exists?(root, "cas-companion")
  end

  test "remote tag conflict is detected before any projection ref is created", %{
    root: root,
    bundle: bundle,
    selector: selection
  } do
    remote = FixtureCase.unique_tmp_dir("weld-conflicting-remote")
    FixtureCase.init_bare_git!(remote)
    Git.run!(root, ["remote", "add", "origin", remote])
    Git.run!(root, ["tag", "-a", "reserved-tag", "-m", "owned by another release"])
    Git.run!(root, ["push", "origin", "refs/tags/reserved-tag"])
    Git.run!(root, ["tag", "-d", "reserved-tag"])

    assert_raise Error, ~r/remote.*conflict/, fn ->
      Release.track!(selection, identity: bundle.identity, tag: "reserved-tag", push: true)
    end

    refute Git.branch_exists?(root, "projection/fixture_bundle")
    refute Git.tag_exists?(root, "reserved-tag")
  end

  defp copy_bundle(bundle) do
    parent = FixtureCase.unique_tmp_dir("weld-bundle-tamper")
    target = Path.join(parent, "bundle")
    File.cp_r!(bundle.bundle_path, target)
    target
  end

  defp rewrite_evidence(bundle, change) do
    path = copy_bundle(bundle)
    evidence = ReleaseStatus.evidence!(path)

    {metadata, inventory, proof} =
      change.(bundle.metadata, evidence.inventory, evidence.qualification)

    inventory = Map.put(inventory, "input_id", Weld.Plan.Inventory.input_id(inventory))
    inventory = Map.put(inventory, "plan_id", Weld.Plan.Inventory.plan_id(inventory))
    metadata = Map.merge(metadata, Map.take(inventory, ["input_id", "plan_id"]))
    proof = Map.put(proof, "plan_id", inventory["plan_id"])
    proof = Map.delete(proof, "qualification_id")
    proof = Map.put(proof, "qualification_id", Identity.digest("qualification", proof))
    File.write!(Path.join(path, "inventory.json"), Identity.canonical(inventory))
    File.write!(Path.join(path, "qualification.json"), Identity.canonical(proof))

    descriptor = fn name ->
      %{
        "path" => name,
        "sha256" => Hash.sha256_file(Path.join(path, name)),
        "size" => File.stat!(Path.join(path, name)).size
      }
    end

    metadata =
      metadata
      |> Map.put("qualification_id", proof["qualification_id"])
      |> put_in(["files", "inventory"], descriptor.("inventory.json"))
      |> put_in(["files", "qualification"], descriptor.("qualification.json"))
      |> Map.delete("bundle_id")

    id = Release.identity(metadata)
    metadata = Map.put(metadata, "bundle_id", id)
    File.write!(Path.join(path, "bundle.json"), Identity.canonical(metadata))
    {path, id}
  end
end
