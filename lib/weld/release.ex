defmodule Weld.Release do
  @moduledoc """
  Prepares and archives deterministic welded release bundles.
  """

  alias Weld.Error
  alias Weld.Git
  alias Weld.Hash
  alias Weld.Output
  alias Weld.Plan
  alias Weld.Verifier

  @spec prepare!(Plan.t()) :: map()
  def prepare!(%Plan{} = plan) do
    Weld.Output.with_lock(plan.manifest.repo_root, fn -> prepare_locked!(plan) end)
  end

  defp prepare_locked!(plan) do
    plan = Plan.ensure_valid!(plan)
    repo_root = plan.manifest.repo_root
    source_revision = Git.revision(repo_root)

    if is_nil(source_revision) and plan.artifact.mode == :source_project do
      raise Error, "source-project release preparation requires a committed Git revision"
    end

    if source_revision, do: Git.ensure_clean_repo!(repo_root)
    verification = Verifier.verify!(plan)
    ensure_source!(repo_root, source_revision)
    stage = Output.temporary!(repo_root, "staging")

    try do
      finish_prepare!(plan, verification, source_revision, stage)
    after
      File.rm_rf!(stage)
    end
  end

  defp finish_prepare!(plan, verification, source_revision, stage) do
    relative_manifest_path = manifest_path(plan)
    manifest_digest = Hash.sha256_file(plan.manifest.manifest_path)
    project_target = Path.join(stage, "project")

    inventory = Map.get(verification, :verification_files, verification.package_files)
    copy_prepared_project!(verification.build_path, project_target, inventory)

    if expected = verification[:verification_input_identity] do
      unless Hash.verification_identity(project_target, inventory) == expected do
        raise Error, "verified source or test inputs changed before release preparation"
      end
    end

    finalize_project_identity!(project_target)

    tarball_target = maybe_copy_tarball(stage, verification.tarball_path)
    docs_path = Path.join(stage, "docs")
    copy_docs_preview!(Path.join(verification.build_path, "doc"), docs_path)

    release_json =
      %{
        artifact: plan.artifact.id,
        package: %{
          name: plan.artifact.package.name,
          version: plan.artifact.package.version,
          otp_app: plan.artifact.package.otp_app
        },
        source_revision: source_revision,
        manifest_path: relative_manifest_path,
        manifest_digest: manifest_digest,
        weld_version: Weld.version(),
        lock_sha256: optional_digest(Path.join(project_target, "mix.lock")),
        content_sha256:
          project_target
          |> Path.join("weld.provenance.json")
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("artifact_id"),
        elixir_version: System.version(),
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        prepared_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        project_path: Path.basename(project_target),
        docs_path: Path.basename(docs_path),
        verification_results: verification.verification_results,
        integrity: %{
          project_sha256: Hash.sha256_tree(project_target),
          project_identity: Hash.content_identity(project_target),
          docs_sha256: Hash.sha256_tree(docs_path),
          docs_identity: Hash.content_identity(docs_path),
          archive_sha256: tarball_target && Hash.sha256_file(tarball_target)
        },
        tarball_path: tarball_target && Path.basename(tarball_target),
        handoff:
          prepared_artifact_handoff(
            plan,
            source_revision,
            relative_manifest_path,
            manifest_digest,
            project_target,
            tarball_target
          )
      }

    identity = identity(release_json)
    bundle = release_path(plan, identity)

    File.write!(
      Path.join(stage, "release.json"),
      Jason.encode!(Map.put(release_json, :identity, identity), pretty: true)
    )

    validate_bundle!(plan, stage, identity)
    ensure_source!(plan.manifest.repo_root, source_revision)

    if File.exists?(bundle) do
      validate_bundle!(plan, bundle, identity)
    else
      File.mkdir_p!(Path.dirname(bundle))
      File.rename!(stage, bundle)
    end

    set_current!(plan, identity)

    %{
      identity: identity,
      bundle_path: bundle,
      docs_path: Path.join(bundle, "docs"),
      project_path: Path.join(bundle, "project"),
      tarball_path: tarball_target && Path.join(bundle, Path.basename(tarball_target)),
      release_metadata_path: Path.join(bundle, "release.json"),
      build_path: verification.build_path
    }
  end

  defp copy_docs_preview!(source, target) do
    File.mkdir!(target)

    # ExDoc's EPUB includes a random UUID, wall-clock time and ZIP timestamps.
    for entry <- File.ls!(source), Path.extname(entry) != ".epub" do
      File.cp_r!(Path.join(source, entry), Path.join(target, entry))
    end
  end

  defp optional_digest(path), do: if(File.regular?(path), do: Hash.sha256_file(path))

  @doc false
  def identity(metadata) do
    metadata
    |> Map.drop([:prepared_at, :identity, "prepared_at", "identity"])
    |> Weld.Lockfile.encode!()
    |> Hash.sha256_binary()
  end

  defp ensure_source!(_root, nil), do: :ok

  defp ensure_source!(root, revision) do
    Git.ensure_clean_repo!(root)

    unless Git.revision(root) == revision do
      raise Error, "source revision changed during release preparation"
    end
  end

  @spec archive!(Plan.t()) :: map()
  def archive!(%Plan{} = plan) do
    Weld.Output.with_lock(plan.manifest.repo_root, fn -> archive_locked!(plan) end)
  end

  defp archive_locked!(plan) do
    prepared_bundle = bundle_path(plan)

    unless File.dir?(prepared_bundle) do
      raise Error, "release bundle not prepared: #{prepared_bundle}"
    end

    validate_bundle!(plan, prepared_bundle)

    identity = Path.basename(prepared_bundle)
    archive_path = Output.path(plan.manifest.repo_root, ["archive", plan.artifact.id, identity])

    if File.exists?(archive_path) do
      validate_bundle!(plan, archive_path, identity)
    else
      stage = Output.temporary!(plan.manifest.repo_root, "staging")

      try do
        File.cp_r!(prepared_bundle, stage)
        validate_bundle!(plan, stage, identity)
        File.mkdir_p!(Path.dirname(archive_path))
        File.rename!(stage, archive_path)
      after
        File.rm_rf!(stage)
      end
    end

    %{archive_path: archive_path, source_bundle_path: prepared_bundle}
  end

  @spec track!(Plan.t(), keyword()) :: map()
  def track!(%Plan{} = plan, opts \\ []) do
    Weld.Output.with_lock(plan.manifest.repo_root, fn -> track_locked!(plan, opts) end)
  end

  defp track_locked!(plan, opts) do
    prepared_bundle = bundle_path(plan)
    project_path = Path.join(prepared_bundle, "project")
    metadata = validate_bundle!(plan, prepared_bundle)
    track_opts = track_opts(plan, opts)
    source_revision = metadata["source_revision"]

    {branch_created?, commit_sha, committed?} =
      track_projection!(plan, project_path, source_revision, track_opts)

    %{
      branch: track_opts.branch,
      branch_created?: branch_created?,
      commit_sha: commit_sha,
      committed?: committed?,
      pushed?: track_opts.push?,
      tag: track_opts.tag
    }
  end

  @spec bundle_path(Plan.t()) :: Path.t()
  def bundle_path(%Plan{} = plan) do
    current = current_path(plan)

    case File.read(current) do
      {:ok, bytes} -> release_path(plan, parse_pointer!(bytes))
      _ -> raise Error, "release bundle not prepared: #{current}"
    end
  end

  defp parse_pointer!("weld.release/v1 " <> value) do
    digest = String.trim_trailing(value, "\n")

    unless Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: raise(Error, "invalid prepared identity")

    digest
  end

  defp parse_pointer!(_), do: raise(Error, "unmanaged prepared release pointer")

  defp current_path(plan),
    do: Output.path(plan.manifest.repo_root, ["releases", plan.artifact.id, "CURRENT"])

  defp release_path(plan, identity),
    do: Output.path(plan.manifest.repo_root, ["releases", plan.artifact.id, identity])

  defp set_current!(plan, identity) do
    path = current_path(plan)
    if File.exists?(path), do: path |> File.read!() |> parse_pointer!()
    temp = path <> "-" <> Output.nonce()

    try do
      File.write!(temp, "weld.release/v1 #{identity}\n", [:exclusive])
      File.rename!(temp, path)
    after
      File.rm(temp)
    end
  end

  defp manifest_path(plan) do
    repository_root = Git.root(plan.manifest.repo_root) || plan.manifest.repo_root
    Path.relative_to(plan.manifest.manifest_path, repository_root)
  end

  defp projection_branch(%Plan{} = plan) do
    "projection/#{plan.artifact.package.name}"
  end

  defp maybe_copy_tarball(_bundle_path, nil), do: nil

  defp maybe_copy_tarball(bundle_path, tarball_path) do
    target = Path.join(bundle_path, Path.basename(tarball_path))
    File.cp!(tarball_path, target)
    target
  end

  defp copy_prepared_project!(source, target, project_files) do
    optional =
      for file <- ["mix.lock", "weld.provenance.json", "projection.lock.json"],
          File.exists?(Path.join(source, file)),
          do: file

    File.mkdir_p!(target)

    (project_files ++ optional)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn relative ->
      source_path = Output.source!(source, relative)

      unless match?({:ok, %{type: :regular}}, File.lstat(source_path)),
        do: raise(Error, "verified project file missing or unsafe: #{relative}")

      target_path = Path.join(target, relative)
      File.mkdir_p!(Path.dirname(target_path))
      File.cp!(source_path, target_path)
      File.chmod!(target_path, Bitwise.band(File.stat!(source_path).mode, 0o777))
    end)
  end

  defp finalize_project_identity!(project) do
    path = Path.join(project, "weld.provenance.json")
    marker = path |> File.read!() |> Jason.decode!()

    File.write!(
      path,
      Jason.encode!(Map.put(marker, "artifact_id", Hash.project_identity(project)), pretty: true)
    )
  end

  defp prepared_artifact_handoff(
         plan,
         source_revision,
         manifest_path,
         manifest_digest,
         project_path,
         tarball_path
       )
       when is_binary(source_revision) and byte_size(source_revision) == 40 do
    %{
      schema: "mix_workspace_ops.prepared_artifact/v2",
      package: plan.artifact.package.name,
      version: plan.artifact.package.version,
      source_revision: source_revision,
      manifest_path: manifest_path,
      manifest_sha256: manifest_digest,
      project_path: Path.basename(project_path),
      project_sha256: Hash.sha256_tree(project_path),
      archive_path: tarball_path && Path.basename(tarball_path),
      archive_sha256: tarball_path && Hash.sha256_file(tarball_path)
    }
  end

  defp prepared_artifact_handoff(
         _plan,
         _source_revision,
         _manifest_path,
         _manifest_digest,
         _project_path,
         _tarball_path
       ),
       do: nil

  defp track_opts(%Plan{} = plan, opts) do
    %{
      branch: opts[:branch] || projection_branch(plan),
      remote: opts[:remote] || "origin",
      tag: opts[:tag],
      push?: Keyword.get(opts, :push, false),
      worktree_path: unique_worktree_path(plan)
    }
  end

  defp validate_bundle!(plan, bundle), do: validate_bundle!(plan, bundle, Path.basename(bundle))

  defp validate_bundle!(plan, bundle, expected_identity) do
    Output.reject_tree_links!(bundle)
    metadata_path = Path.join(bundle, "release.json")

    with {:ok, json} <- File.read(metadata_path),
         {:ok, %{} = metadata} <- Jason.decode(json),
         true <-
           metadata["identity"] == expected_identity and identity(metadata) == expected_identity,
         %{"name" => name, "version" => version} <- metadata["package"],
         true <- {name, version} == {plan.artifact.package.name, plan.artifact.package.version},
         true <- metadata["artifact"] == plan.artifact.id,
         true <- metadata["manifest_digest"] == Hash.sha256_file(plan.manifest.manifest_path),
         true <- valid_inventory?(bundle, metadata),
         true <- valid_bundle_contents?(bundle, metadata, "#{name}-#{version}.tar") do
      metadata
    else
      _ ->
        raise Error,
              "prepared release bundle is missing or failed integrity verification: #{bundle}"
    end
  end

  defp valid_inventory?(bundle, metadata) do
    known = ["release.json", "project", "docs"] ++ List.wrap(metadata["tarball_path"])
    File.ls!(bundle) -- known == []
  end

  defp valid_bundle_contents?(bundle, metadata, archive_name) do
    integrity = metadata["integrity"] || metadata["handoff"]
    project = Path.join(bundle, "project")
    docs = Path.join(bundle, "docs")
    archive = Path.join(bundle, archive_name)

    is_map(integrity) and
      valid_archive?(archive, metadata["tarball_path"], archive_name, integrity["archive_sha256"]) and
      File.dir?(project) and Hash.sha256_tree(project) == integrity["project_sha256"] and
      match_identity?(project, integrity["project_identity"]) and
      valid_docs?(docs, metadata["integrity"]) and
      match_identity?(docs, integrity["docs_identity"])
  end

  defp match_identity?(_path, nil), do: true

  defp match_identity?(path, expected) do
    File.dir?(path) and Hash.content_identity(path) == expected
  end

  defp valid_archive?(path, name, name, digest) do
    File.regular?(path) and Hash.sha256_file(path) == digest
  end

  defp valid_archive?(path, nil, _name, nil), do: not File.exists?(path)
  defp valid_archive?(_path, _recorded, _expected, _digest), do: false

  defp valid_docs?(_path, nil), do: true

  defp valid_docs?(path, integrity) do
    File.dir?(path) and Hash.sha256_tree(path) == integrity["docs_sha256"]
  end

  defp unique_worktree_path(%Plan{} = plan) do
    path = Output.path(plan.manifest.repo_root, ["worktrees", Output.nonce()])
    File.mkdir_p!(Path.dirname(path))
    path
  end

  defp track_projection!(%Plan{} = plan, project_path, source_revision, track_opts) do
    repo_root = plan.manifest.repo_root
    worktree_path = track_opts.worktree_path

    try do
      branch_created? =
        prepare_worktree!(
          repo_root,
          worktree_path,
          track_opts.branch,
          track_opts.remote
        )

      sync_project!(project_path, worktree_path)
      Git.stage_all!(worktree_path)
      committed? = commit_projection!(plan, source_revision, worktree_path)
      maybe_tag_projection!(track_opts)
      maybe_push_projection!(track_opts)

      {branch_created?, Git.revision(worktree_path), committed?}
    after
      cleanup_worktree!(repo_root, worktree_path)
    end
  end

  defp commit_projection!(%Plan{} = plan, source_revision, worktree_path) do
    if Git.staged_changes?(worktree_path) do
      Git.commit_all!(worktree_path, track_commit_message(plan, source_revision))
      true
    else
      false
    end
  end

  defp maybe_tag_projection!(%{tag: nil}), do: :ok

  defp maybe_tag_projection!(%{tag: tag, worktree_path: worktree_path}) do
    Git.create_tag!(worktree_path, tag)
  end

  defp maybe_push_projection!(%{push?: false}), do: :ok

  defp maybe_push_projection!(%{
         branch: branch,
         remote: remote,
         tag: tag,
         worktree_path: worktree_path
       }) do
    Git.push_branch!(worktree_path, remote, branch)

    if tag do
      Git.push_tag!(worktree_path, remote, tag)
    end
  end

  defp cleanup_worktree!(repo_root, worktree_path) do
    if File.exists?(worktree_path) do
      Git.worktree_remove!(repo_root, worktree_path)
    end
  end

  defp prepare_worktree!(repo_root, worktree_path, branch, remote) do
    if File.exists?(worktree_path), do: raise(Error, "unmanaged worktree path: #{worktree_path}")

    cond do
      Git.branch_exists?(repo_root, branch) ->
        Git.worktree_add!(repo_root, worktree_path, branch)
        false

      Git.remote_branch_exists?(repo_root, remote, branch) ->
        Git.fetch_branch!(repo_root, remote, branch)
        Git.worktree_add!(repo_root, worktree_path, branch)
        false

      true ->
        Git.worktree_add_detached!(repo_root, worktree_path)
        Git.switch_orphan!(worktree_path, branch)
        true
    end
  end

  defp sync_project!(project_path, worktree_path) do
    clear_worktree!(worktree_path)

    for entry <- File.ls!(project_path) do
      source = Path.join(project_path, entry)
      target = Path.join(worktree_path, entry)
      File.cp_r!(source, target)
    end
  end

  defp clear_worktree!(worktree_path) do
    worktree_path
    |> File.ls!()
    |> Enum.reject(&(&1 == ".git"))
    |> Enum.each(fn entry ->
      File.rm_rf!(Path.join(worktree_path, entry))
    end)
  end

  defp track_commit_message(%Plan{} = plan, source_revision) do
    """
    Track projection for #{plan.artifact.package.name}

    Source revision: #{source_revision}
    Artifact: #{plan.artifact.id}
    """
  end
end
