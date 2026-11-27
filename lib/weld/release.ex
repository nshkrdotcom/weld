defmodule Weld.Release do
  @moduledoc """
  Concrete pinned release operations over one immutable evidence store.
  Preparation runs qualification outside metadata locks; all later operations
  use the stored bundle, including historical pins without a current manifest.
  """

  alias Weld.Core.Identity
  alias Weld.{Error, Git, Hash, Output, Plan, ReleaseReceipt, ReleaseStatus, Verifier}
  alias Weld.Plan.Inventory
  alias Weld.Shell.{Hex, Runner}

  def prepare!(%Plan{} = plan, opts \\ []) do
    plan = Plan.ensure_valid!(plan)
    root = plan.manifest.repo_root
    Git.ensure_clean_repo!(root)
    revision = Git.revision(root)

    Output.with_lease(root, "prepare", plan.artifact.id, "prepare", [], fn lease ->
      run =
        Output.run!(root, "prepare", plan.artifact.id, lease,
          plan_id: Inventory.portable(plan)["plan_id"]
        )

      try do
        Output.update_run!(run, %{"phase" => "executing"})
        Output.failpoint(opts, :prepare_snapshot)

        result =
          case reusable_bundle(plan, revision, opts) do
            {:ok, bundle, metadata} ->
              ensure_source!(root, revision)
              result(plan, bundle, metadata) |> Map.merge(%{reused?: true, reuse_reasons: []})

            {:miss, reasons} ->
              qualification_opts =
                opts
                |> Keyword.put(:no_cache, opts[:fresh] == true or opts[:no_cache] == true)
                |> Keyword.put(:context, opts[:reuse] || opts[:context])
                |> Keyword.put(:parent_lease, lease)

              verification = Verifier.verify!(plan, qualification_opts)
              Output.failpoint(opts, :prepare_qualified)
              ensure_source!(root, revision)

              seal_prepared!(plan, verification, revision, lease, opts)
              |> Map.merge(%{reused?: false, reuse_reasons: reasons})
          end

        Output.update_run!(run, %{"bundle_id" => result.identity})
        Output.finish_run!(run, "completed")
        Map.merge(result, %{run: run.id, run_path: run.path})
      rescue
        error ->
          Output.finish_run!(run, "failed", [
            %{"code" => "prepare_failed", "message" => Runner.sanitize(Exception.message(error))}
          ])

          reraise error, __STACKTRACE__
      end
    end)
  end

  defp reusable_bundle(plan, revision, opts) do
    cond do
      opts[:fresh] == true or opts[:no_cache] == true -> {:miss, [:fresh_requested]}
      not is_binary(opts[:reuse]) or opts[:reuse] == "" -> {:miss, [:reuse_not_requested]}
      plan.artifact.mode != :source_project -> {:miss, [:layout_not_eligible]}
      true -> reuse_candidate(plan, revision, opts[:reuse])
    end
  end

  defp reuse_candidate(plan, revision, context) do
    inventory = Inventory.portable(plan)
    current = Output.path(plan.manifest.repo_root, ["current", plan.artifact.id])
    tracked = Git.tracked_files(plan.manifest.repo_root)

    cond do
      inventory["qualification_policy"]["hex_publish_check"] != false ->
        {:miss, [:publication_check_requires_fresh_run]}

      Enum.any?(inventory["inputs"], &(&1["kind"] == "external" and &1["fact"]["opaque"] == true)) ->
        {:miss, [:opaque_inputs]}

      Enum.any?(inventory["inputs"], fn input ->
        input["kind"] == "file" and not MapSet.member?(tracked, input["fact"]["path"])
      end) ->
        {:miss, [:untracked_inputs]}

      not File.exists?(current) ->
        {:miss, [:no_prepared_bundle]}

      true ->
        validate_reuse_candidate(plan, revision, context, inventory)
    end
  end

  defp validate_reuse_candidate(plan, revision, context, inventory) do
    {id, bundle} = ReleaseStatus.resolve_path!(plan)
    # Sealed proof corruption is fatal.
    metadata = ReleaseStatus.validate_bundle_integrity!(bundle, id)
    evidence = ReleaseStatus.evidence!(bundle)

    case Verifier.reuse_facts(plan, context) do
      {:ok, facts} ->
        if reuse_inputs_match?(metadata, evidence.inventory, inventory, revision) and
             reuse_observations_match?(plan, evidence.qualification, facts),
           do: {:ok, bundle, metadata},
           else: {:miss, [:proof_inputs_changed]}

      {:ineligible, reasons} ->
        {:miss, List.wrap(reasons)}
    end
  end

  defp reuse_inputs_match?(metadata, sealed_inventory, inventory, revision) do
    metadata["source"]["commit"] == revision and
      Map.take(metadata, ~w(plan_id input_id compiler_id)) ==
        Map.take(inventory, ~w(plan_id input_id compiler_id)) and
      sealed_inventory["qualification_policy"] == inventory["qualification_policy"]
  end

  defp reuse_observations_match?(plan, proof, facts) do
    lock = proof["lock_sha256"]

    is_binary(lock) and proof["toolchain"] == facts.toolchain and
      proof["trust"] == facts.trust and proof["context_digest"] == facts.context_digest and
      reusable_lock?(plan, lock)
  end

  defp reusable_lock?(plan, expected) do
    [id] = plan.artifact.roots
    source = plan.workspace.projects[id].abs_path
    path = Output.source!(source, "mix.lock")
    File.regular?(path) and Hash.sha256_file(path) == expected
  end

  defp seal_prepared!(plan, verification, revision, lease, opts) do
    stage = Path.join(lease.stage, "bundle")
    File.mkdir!(stage)
    project = Path.join(stage, "project")
    docs = Path.join(stage, "docs")

    copy_tree!(
      verification.build_path,
      project,
      verification.frozen_project,
      verification.empty_dirs
    )

    copy_tree!(
      verification.docs_path,
      docs,
      verification.docs_entries,
      verification.docs_empty_dirs
    )

    Output.failpoint(opts, :prepare_copied)

    inventory =
      Inventory.portable(plan)
      |> Map.merge(%{
        "frozen_project" => verification.frozen_project,
        "empty_dirs" => verification.empty_dirs,
        "package_entries" => verification.package_entries,
        "package_metadata" => verification.package_metadata,
        "docs_entries" => verification.docs_entries,
        "docs_empty_dirs" => verification.docs_empty_dirs
      })

    Inventory.validate_portable!(inventory)

    source = %{
      "git_algorithm" => Git.object_format(plan.manifest.repo_root),
      "commit" => revision,
      "manifest_path" =>
        Path.relative_to(plan.manifest.manifest_path, Git.root(plan.manifest.repo_root)),
      "manifest_sha256" => Hash.sha256_file(plan.manifest.manifest_path)
    }

    proof =
      verification.qualification
      |> Map.merge(%{
        "schema" => "weld.qualification/2",
        "source" => source,
        "plan_id" => inventory["plan_id"]
      })
      |> Map.delete("qualification_id")

    unless proof["trust"]["verified"] == true,
      do: raise(Error, "trusted registry observations are required to seal a release")

    proof = Map.put(proof, "qualification_id", Identity.digest("qualification", proof))
    write_proof!(Path.join(stage, "inventory.json"), inventory)
    write_proof!(Path.join(stage, "qualification.json"), proof)

    if verification.tarball_path do
      copy_file!(verification.tarball_path, Path.join(stage, "package.tar"), false)
      copy_file!(verification.docs_archive_path, Path.join(stage, "docs.tar.gz"), false)
    end

    metadata = %{
      "schema" => "weld.bundle/2",
      "artifact" => plan.artifact.id,
      "layout" => layout(plan),
      "package" => plan.artifact.package.name,
      "version" => plan.artifact.package.version,
      "compiler_id" => inventory["compiler_id"],
      "input_id" => inventory["input_id"],
      "plan_id" => inventory["plan_id"],
      "project_id" => proof["project_id"],
      "qualification_id" => proof["qualification_id"],
      "package_id" => proof["package_id"],
      "archive_sha256" => proof["archive_sha256"],
      "docs_id" => proof["docs_id"],
      "docs_archive_sha256" => proof["docs_archive_sha256"],
      "source" => source,
      "files" => %{
        "inventory" => descriptor(stage, "inventory.json"),
        "qualification" => descriptor(stage, "qualification.json"),
        "package" => if(verification.tarball_path, do: descriptor(stage, "package.tar")),
        "docs_archive" => if(verification.tarball_path, do: descriptor(stage, "docs.tar.gz"))
      }
    }

    metadata = Map.put(metadata, "bundle_id", identity(metadata))
    write_proof!(Path.join(stage, "bundle.json"), metadata)
    ReleaseStatus.validate_bundle_integrity!(stage, metadata["bundle_id"])
    Output.failpoint(opts, :prepare_sealed)
    root = plan.manifest.repo_root
    bundle = Output.path(root, ["bundles", plan.artifact.id, metadata["bundle_id"]])
    pointer = Output.path(root, ["current", plan.artifact.id])

    pointer_bytes =
      Identity.canonical(%{
        "schema" => "weld.current/2",
        "artifact" => plan.artifact.id,
        "bundle_id" => metadata["bundle_id"]
      })

    ensure_source!(root, revision)

    if File.exists?(bundle),
      do: ReleaseStatus.validate_bundle_integrity!(bundle, metadata["bundle_id"])

    if File.exists?(pointer) do
      previous = ReleaseStatus.pointer!(File.read!(pointer), plan.artifact.id)

      ReleaseStatus.validate_bundle_integrity!(
        Output.path(root, ["bundles", plan.artifact.id, previous]),
        previous
      )
    end

    Output.seal!(
      root,
      stage,
      bundle,
      pointer,
      pointer_bytes,
      fn target ->
        ReleaseStatus.validate_bundle_integrity!(target, metadata["bundle_id"])
        ensure_source!(root, revision)
      end,
      Keyword.put(opts, :lease, lease)
    )

    result(plan, bundle, metadata) |> Map.put(:build_path, verification.build_path)
  end

  defp write_proof!(path, record) do
    File.write!(path, Identity.canonical(record), [:exclusive, :sync])
    File.chmod!(path, 0o644)
  end

  defp descriptor(root, relative) do
    target = Path.join(root, relative)
    %{"path" => relative, "sha256" => Hash.sha256_file(target), "size" => File.stat!(target).size}
  end

  def identity(metadata), do: Identity.digest("bundle", Map.delete(metadata, "bundle_id"))
  def bundle_path(selection, id \\ nil), do: ReleaseStatus.resolve_path!(selection, id) |> elem(1)

  defp layout(%{artifact: %{mode: :package_projection}}), do: "components"
  defp layout(%{artifact: %{mode: :monolith}}), do: "flat"
  defp layout(%{artifact: %{mode: :source_project}}), do: "preserve"

  def stage!(selection, opts \\ []) do
    with_bundle(selection, "stage", opts, fn lease, bundle, metadata ->
      %{repo_root: root, artifact: artifact} = ReleaseStatus.selector(selection)

      run =
        Output.run!(root, "stage", artifact, lease,
          bundle_id: metadata["bundle_id"],
          plan_id: metadata["plan_id"]
        )

      try do
        evidence = ReleaseStatus.evidence!(bundle)
        project = Path.join(run.path, "project")

        copy_tree!(
          Path.join(bundle, "project"),
          project,
          evidence.inventory["frozen_project"],
          evidence.inventory["empty_dirs"]
        )

        Output.finish_run!(run, "completed")

        %{
          run: run.id,
          run_path: run.path,
          project_path: project,
          identity: metadata["bundle_id"],
          package: metadata["package"],
          version: metadata["version"],
          archive_sha256: metadata["archive_sha256"],
          refreshed?: true
        }
      rescue
        error ->
          Output.finish_run!(run, "failed", [
            %{"code" => "stage_failed", "message" => Runner.sanitize(Exception.message(error))}
          ])

          reraise error, __STACKTRACE__
      end
    end)
  end

  def archive!(selection, opts \\ []) do
    with_bundle(selection, "archive", opts, fn lease, bundle, metadata ->
      %{repo_root: root, artifact: artifact} = ReleaseStatus.selector(selection)
      target = Output.path(root, ["archives", artifact, metadata["bundle_id"]])

      if File.exists?(target) do
        ReleaseStatus.validate_bundle_integrity!(target, metadata["bundle_id"])
      else
        stage = Path.join(lease.stage, "archive")
        File.cp_r!(bundle, stage)
        ReleaseStatus.validate_bundle_integrity!(stage, metadata["bundle_id"])
        Output.insert_immutable!(root, stage, target, Keyword.put(opts, :lease, lease))
        ReleaseStatus.validate_bundle_integrity!(target, metadata["bundle_id"])
      end

      %{archive_path: target, source_bundle_path: bundle, identity: metadata["bundle_id"]}
    end)
  end

  def track!(selection, opts \\ []) do
    if opts[:tag] && opts[:tag_release],
      do: raise(Error, "pass either --tag or --tag-release, not both")

    with_bundle(selection, "track", opts, fn lease, bundle, metadata ->
      %{repo_root: root} = ReleaseStatus.selector(selection)
      branch = opts[:branch] || "projection/" <> metadata["package"]
      tag = if opts[:tag_release], do: ReleaseStatus.default_tag(metadata), else: opts[:tag]
      ref = Git.check_ref!(root, "refs/heads/" <> branch)
      if tag, do: Git.check_ref!(root, "refs/tags/" <> tag)
      old = Git.ref_oid(root, ref)
      expected = ReleaseReceipt.from_bundle(metadata)
      parent = preflight_branch!(root, ref, old, expected)
      existing_tag = preflight_tag!(root, tag, old, expected)

      tracking = %{
        ref: ref,
        old: old,
        tag: tag,
        existing_tag: existing_tag,
        parent: parent,
        expected: expected,
        branch: branch
      }

      {commit, reusable} =
        track_candidate!(selection, bundle, lease.stage, metadata, tracking, opts)

      %{
        artifact: metadata["artifact"],
        identity: metadata["bundle_id"],
        branch: branch,
        branch_created?: is_nil(old),
        commit_sha: commit,
        committed?: not reusable,
        pushed?: opts[:push] == true,
        tag: tag,
        has_tarball: not is_nil(metadata["archive_sha256"]),
        warnings: ReleaseStatus.docs_source_ref_warnings(selection, tag)
      }
    end)
  end

  defp track_candidate!(selection, bundle, stage, metadata, tracking, opts) do
    %{repo_root: root} = ReleaseStatus.selector(selection)
    %{ref: ref, old: old, tag: tag, existing_tag: existing_tag, branch: branch} = tracking
    remote = opts[:remote] || "origin"

    if opts[:push], do: preflight_remote!(root, remote, ref, old, tag, existing_tag)
    Output.failpoint(opts, :track_preflight)
    {tree, observed} = Git.write_project_tree!(root, Path.join(bundle, "project"), stage)

    unless Identity.digest("project", observed) == metadata["project_id"] and
             Git.project_id(root, tree) == metadata["project_id"],
           do: raise(Error, "qualified project or actual Git blobs changed during tracking")

    {commit, reused} = candidate_commit!(root, tree, stage, selection, metadata, tracking)

    updates =
      [{ref, commit, old}] ++
        candidate_tag_updates!(root, commit, stage, selection, metadata, tracking)

    Output.failpoint(opts, :track_before_refs)
    Git.transaction!(root, updates)
    if opts[:push], do: Git.push_release!(root, remote, branch, tag)
    {commit, reused}
  end

  defp candidate_commit!(root, tree, stage, selection, metadata, tracking) do
    %{parent: parent, expected: expected} = tracking

    if is_binary(parent) and ReleaseReceipt.from_commit(root, parent) == {:ok, expected} and
         Git.project_id(root, parent) == metadata["project_id"] do
      {parent, true}
    else
      message = ReleaseReceipt.format_commit_message(selection, metadata)
      {Git.write_commit!(root, tree, parent, message, stage), false}
    end
  end

  defp candidate_tag_updates!(_root, _commit, _stage, _selection, _metadata, %{tag: nil}), do: []

  defp candidate_tag_updates!(root, commit, stage, selection, metadata, tracking) do
    %{tag: tag, existing_tag: existing} = tracking

    oid =
      existing ||
        Git.write_tag!(
          root,
          tag,
          commit,
          ReleaseReceipt.format_tag_message(selection, metadata, tag),
          stage
        )

    [{"refs/tags/" <> tag, oid, existing}]
  end

  defp preflight_branch!(_root, _ref, nil, _expected), do: nil

  defp preflight_branch!(root, ref, old, _expected) do
    case ReleaseReceipt.from_commit(root, old) do
      {:ok, receipt} ->
        unless Git.project_id(root, old) == receipt["project_id"],
          do: raise(Error, "projection branch tree disagrees with its receipt")

        old

      _ ->
        raise Error, "projection branch #{ref} lacks strict v2 evidence; select a new --branch"
    end
  end

  defp preflight_tag!(_root, nil, _parent, _expected), do: nil

  defp preflight_tag!(root, tag, parent, expected) do
    case ReleaseReceipt.from_tag(root, tag) do
      :missing -> nil
      {:ok, %{target_sha: ^parent, receipt: ^expected}} -> Git.ref_oid(root, "refs/tags/" <> tag)
      _ -> raise Error, "tag #{tag} already exists with different or unsupported evidence"
    end
  end

  defp preflight_remote!(root, remote, branch, old, tag, tag_oid) do
    refs = [branch] ++ if(tag, do: ["refs/tags/" <> tag], else: [])

    case Git.remote_refs(root, remote, refs) do
      {:ok, observed} ->
        unless (is_nil(observed[branch]) or Git.fast_forward_from?(root, observed[branch], old)) and
                 (is_nil(tag) or is_nil(observed["refs/tags/" <> tag]) or
                    observed["refs/tags/" <> tag] == tag_oid),
               do: raise(Error, "remote projection branch or tag conflicts; no refs were changed")

      _ ->
        raise Error, "remote refs cannot be established; no refs were changed"
    end
  end

  def publish!(selection, opts \\ []), do: publication(selection, "publish", opts)
  def reconcile!(selection, opts), do: publication(selection, "reconcile", opts)

  defp publication(selection, operation, opts) do
    with_bundle(selection, operation, opts, fn lease, bundle, metadata ->
      unless metadata["package_id"],
        do: raise(Error, "qualified internal bundle has no Hex payload")

      check_publication_intent!(selection, operation, metadata, opts)

      %{repo_root: root, artifact: artifact} = ReleaseStatus.selector(selection)

      run =
        Output.run!(root, "publish", artifact, lease,
          bundle_id: metadata["bundle_id"],
          plan_id: metadata["plan_id"]
        )

      try do
        Output.update_run!(run, %{"phase" => "executing"})

        result =
          if operation == "publish",
            do: Hex.publish!(selection, bundle, metadata, opts),
            else: Hex.reconcile!(selection, bundle, metadata, opts)

        Output.finish_run!(run, "completed")
        Map.merge(result, %{run: run.id, run_path: run.path})
      rescue
        error ->
          Output.finish_run!(run, "failed", [
            %{
              "code" => "publication_failed",
              "message" => Runner.sanitize(Exception.message(error))
            }
          ])

          reraise error, __STACKTRACE__
      end
    end)
  end

  defp check_publication_intent!(selection, "publish", metadata, opts) do
    ensure_publish_fresh!(selection, metadata, opts)
    check_publication_tag!(selection, metadata, opts[:tag])
  end

  defp check_publication_intent!(_selection, _operation, _metadata, _opts), do: :ok

  defp check_publication_tag!(_selection, _metadata, nil), do: :ok

  defp check_publication_tag!(selection, metadata, tag) do
    %{repo_root: root} = ReleaseStatus.selector(selection)

    result =
      ReleaseStatus.verify_tag(root, tag,
        artifact: metadata["artifact"],
        identity: metadata["bundle_id"]
      )

    unless result.status == :match,
      do: raise(Error, "tag does not identify the pinned bundle")
  end

  defp ensure_publish_fresh!(selection, metadata, opts) do
    %{repo_root: root} = ReleaseStatus.selector(selection)
    reasons = ReleaseStatus.freshness_reasons(selection, metadata, Git.revision(root))

    allowed =
      if opts[:allow_source_drift] == true or opts[:allow_stale] == true do
        [:head_moved, :dirty_worktree, :current_manifest_unavailable] ++
          if(:head_moved in reasons, do: [:manifest_changed, :package_mismatch], else: [])
      else
        []
      end

    blocking = reasons -- allowed
    evidence = ReleaseStatus.evidence!(bundle_path(selection, metadata["bundle_id"]))

    check_registry_publication!(evidence.qualification["trust"], opts)

    unless blocking == [],
      do: raise(Error, "pinned bundle freshness blocks publication: #{Enum.join(blocking, ", ")}")
  end

  defp check_registry_publication!(trust, opts) do
    if trust["reason"] == "unsafe_registry_settings",
      do: raise(Error, "unsafe registry trust policy blocks publication")

    if trust["policy"] == "isolated-signed-candidate-hex/1" and opts[:dry_run] != true,
      do:
        raise(
          Error,
          "candidate registry qualification requires a fresh official prepare before publication"
        )
  end

  defp with_bundle(selection, operation, opts, fun) do
    %{repo_root: root, artifact: artifact} = ReleaseStatus.selector(selection)

    unless Identity.valid?(opts[:identity]) or opts[:current] == true,
      do:
        raise(Error, "release operation requires --identity <full-sha256> or explicit --current")

    {id, bundle} =
      Output.with_lock(root, fn -> ReleaseStatus.resolve_path!(selection, opts[:identity]) end)

    metadata = ReleaseStatus.validate_bundle_integrity!(bundle, id)
    unless metadata["artifact"] == artifact, do: raise(Error, "artifact and bundle disagree")

    resource =
      case operation do
        part when part in ["publish", "reconcile"] ->
          "publication:" <>
            Hex.destination(opts) <> ":" <> metadata["package"] <> ":" <> metadata["version"]

        "track" ->
          "track:" <> (opts[:branch] || "projection/" <> metadata["package"])

        _ ->
          operation <> ":" <> id
      end

    Output.with_lease(root, operation, artifact, resource, [id], fn lease ->
      ReleaseStatus.validate_bundle_integrity!(bundle, id)
      fun.(lease, bundle, metadata)
    end)
  end

  defp ensure_source!(root, revision) do
    Git.ensure_clean_repo!(root)

    unless Git.revision(root) == revision,
      do: raise(Error, "source revision changed during release preparation")
  end

  defp result(selection, bundle, metadata) do
    %{
      identity: metadata["bundle_id"],
      artifact: metadata["artifact"],
      package: metadata["package"],
      version: metadata["version"],
      source_revision: metadata["source"]["commit"],
      bundle_path: bundle,
      docs_path: Path.join(bundle, "docs"),
      project_path: Path.join(bundle, "project"),
      tarball_path: if(metadata["archive_sha256"], do: Path.join(bundle, "package.tar")),
      release_metadata_path: Path.join(bundle, "bundle.json"),
      archive_sha256: metadata["archive_sha256"],
      docs_archive_sha256: metadata["docs_archive_sha256"],
      warnings: ReleaseStatus.docs_source_ref_warnings(selection)
    }
  end

  defp copy_tree!(source, target, files, empty_dirs) do
    File.mkdir!(target)

    for entry <- files do
      from = Output.source!(source, entry["path"])
      to = Output.source!(target, entry["path"])

      unless File.stat!(from).size == entry["size"] and Hash.sha256_file(from) == entry["sha256"] and
               Bitwise.band(File.stat!(from).mode, 0o111) != 0 == entry["executable"],
             do: raise(Error, "frozen file changed before copying: #{entry["path"]}")

      copy_file!(from, to, entry["executable"])
    end

    for path <- empty_dirs, do: File.mkdir_p!(Output.source!(target, path))

    unless Hash.observation(target) == %{"entries" => files, "empty_dirs" => empty_dirs},
      do: raise(Error, "frozen tree changed during copying")
  end

  defp copy_file!(source, target, executable) do
    Output.reject_link!(source)
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
    File.chmod!(target, if(executable, do: 0o755, else: 0o644))
  end
end
