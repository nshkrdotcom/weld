defmodule Weld.Release do
  @moduledoc """
  Prepares, stages, and archives deterministic welded release bundles.
  """

  alias Weld.DocsPreview
  alias Weld.DocsSmoke
  alias Weld.Error
  alias Weld.Git
  alias Weld.Hash
  alias Weld.Output
  alias Weld.Plan
  alias Weld.Receipt
  alias Weld.ReleaseInputs
  alias Weld.ReleaseReceipt
  alias Weld.ReleaseStatus
  alias Weld.Verifier

  @spec prepare!(Plan.t(), keyword()) :: map()
  def prepare!(%Plan{} = plan, opts \\ []) do
    Output.with_lock(plan.manifest.repo_root, fn -> prepare_locked!(plan, opts) end)
  end

  defp prepare_locked!(plan, opts) do
    plan = Plan.ensure_valid!(plan)
    repo_root = plan.manifest.repo_root
    source_revision = Git.revision(repo_root)

    if is_nil(source_revision) and plan.artifact.mode == :source_project do
      raise Error, "source-project release preparation requires a committed Git revision"
    end

    if source_revision, do: Git.ensure_clean_repo!(repo_root)
    context = unless opts[:no_cache], do: opts[:reuse]
    input = ReleaseInputs.fingerprint(plan, source_revision, context)
    receipt = Output.path(repo_root, ["cache", "release", plan.artifact.id, "prepare.receipt"])

    case reused_bundle(plan, receipt, input, source_revision) do
      {:ok, result} ->
        ensure_source!(repo_root, source_revision)
        Map.put(result, :reused?, true)

      :miss ->
        prepare_new_bundle!(plan, receipt, input, source_revision, context, opts)
    end
  end

  defp reused_bundle(_plan, _receipt, nil, _revision), do: :miss

  defp reused_bundle(plan, receipt, {input, lock}, revision) do
    with {:ok, identity} <- Receipt.read(receipt, input),
         true <- File.regular?(current_path(plan)),
         bundle <- bundle_path(plan),
         ^identity <- Path.basename(bundle),
         metadata <- validate_bundle!(plan, bundle),
         %{"source_revision" => ^revision, "lock_sha256" => ^lock} <- metadata do
      {:ok, prepared_result(plan, bundle, identity, metadata["tarball_path"])}
    else
      _ -> :miss
    end
  end

  defp prepare_new_bundle!(plan, receipt, input, source_revision, context, opts) do
    repo_root = plan.manifest.repo_root
    verification = Verifier.verify!(plan, no_cache: opts[:no_cache] == true)
    ensure_source!(repo_root, source_revision)
    stage = Output.temporary!(repo_root, "staging")

    try do
      if input && ReleaseInputs.fingerprint(plan, source_revision, context) != input do
        raise Error, "release verification inputs changed during preparation"
      end

      result = finish_prepare!(plan, verification, source_revision, stage)

      if input do
        {key, lock} = input

        if optional_digest(Path.join(result.project_path, "mix.lock")) == lock do
          Receipt.write!(receipt, key, result.identity)
        end
      end

      Map.put(result, :reused?, false)
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
    DocsPreview.copy!(Path.join(verification.build_path, "doc"), docs_path)
    verify_docs_smoke!(docs_path)

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

    prepared_result(plan, bundle, identity, release_json.tarball_path)
  end

  defp prepared_result(plan, bundle, identity, archive) do
    %{
      identity: identity,
      artifact: plan.artifact.id,
      bundle_path: bundle,
      docs_path: Path.join(bundle, "docs"),
      project_path: Path.join(bundle, "project"),
      tarball_path: archive && Path.join(bundle, archive),
      release_metadata_path: Path.join(bundle, "release.json"),
      build_path: Weld.Projector.build_path(plan),
      warnings: ReleaseStatus.docs_source_ref_warnings(plan)
    }
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

  @doc "Stages a verified release project as a writable workspace for Hex."
  @spec stage!(Plan.t(), keyword()) :: map()
  def stage!(%Plan{} = plan, opts \\ []) do
    Output.with_lock(plan.manifest.repo_root, fn -> stage_locked!(plan, opts) end)
  end

  defp stage_locked!(plan, opts) do
    root = plan.manifest.repo_root
    bundle = bundle_path(plan, opts[:identity])
    metadata = validate_bundle!(plan, bundle)
    ensure_tarball_present!(metadata, bundle)

    identity = metadata["identity"]
    parts = ["publish", plan.artifact.id, identity]
    project = Output.path(root, parts ++ ["project"])
    fresh? = opts[:fresh] == true

    refreshed? =
      cond do
        File.exists?(project) and not fresh? ->
          validate_existing_publish_project!(project, metadata)
          false

        File.exists?(project) and fresh? ->
          replace_publish_workspace!(root, bundle, project, metadata)
          true

        true ->
          write_publish_workspace!(root, bundle, project, metadata)
          false
      end

    integrity = metadata["integrity"] || metadata["handoff"] || %{}

    %{
      project_path: project,
      identity: identity,
      package: plan.artifact.package.name,
      version: plan.artifact.package.version,
      archive_sha256: integrity["archive_sha256"],
      refreshed?: refreshed?
    }
  end

  @doc """
  Stages an isolated per-invocation workspace, verifies that a local rebuild
  matches the prepared tarball SHA-256, and hands off interactively to
  `mix hex.publish` without holding the repository output lock.
  """
  @spec publish!(Plan.t(), keyword()) :: map()
  def publish!(%Plan{} = plan, opts \\ []) do
    prepared =
      Output.with_lock(plan.manifest.repo_root, fn ->
        prepare_publish_run!(plan, opts)
      end)

    try do
      run_publish_handoff!(prepared, opts)
    after
      File.rm(prepared.active_marker)
    end
  end

  defp prepare_publish_run!(plan, opts) do
    root = plan.manifest.repo_root
    bundle = bundle_path(plan, opts[:identity])
    identity = Path.basename(bundle)
    metadata = ReleaseStatus.validate_bundle_integrity!(bundle, identity)
    ensure_publish_fresh!(plan, metadata, opts)
    ensure_tarball_present!(metadata, bundle)

    if tag = opts[:tag] do
      verify = ReleaseStatus.verify_tag(root, tag, artifact: plan.artifact.id, identity: identity)

      unless verify.status == :match do
        raise Error, "tag #{tag} does not match prepared identity #{identity}: #{verify.message}"
      end
    end

    run_dir = Output.path(root, ["publish", plan.artifact.id, identity, "run-" <> Output.nonce()])
    project = Path.join(run_dir, "project")
    write_publish_workspace!(root, bundle, project, metadata)
    integrity = metadata["integrity"] || metadata["handoff"] || %{}

    prepared = %{
      plan: plan,
      identity: identity,
      package: plan.artifact.package.name,
      version: plan.artifact.package.version,
      tarball_name: metadata["tarball_path"],
      archive_sha256: integrity["archive_sha256"],
      project_path: project,
      docs_path: Path.join(bundle, "docs"),
      warnings: ReleaseStatus.docs_source_ref_warnings(plan, opts[:tag])
    }

    # GC takes the same repository lock, then skips marked runs. Keep this
    # lease outside the package tree so it cannot change the prepared bytes.
    active_marker = Path.join(run_dir, "ACTIVE")
    File.write!(active_marker, "weld.publish/v1\n", [:exclusive])
    Map.put(prepared, :active_marker, active_marker)
  end

  defp ensure_publish_fresh!(plan, metadata, opts) do
    reasons =
      ReleaseStatus.freshness_reasons(plan, metadata, Git.revision(plan.manifest.repo_root))

    allowed = if opts[:allow_stale] == true, do: [:head_moved, :dirty_worktree], else: []
    blocking = reasons -- allowed

    unless blocking == [] do
      formatted = Enum.map_join(blocking, ", ", &Atom.to_string/1)

      hint =
        if Enum.all?(blocking, &(&1 in [:head_moved, :dirty_worktree])),
          do: " (re-run release.prepare or pass --allow-stale)",
          else: " (re-run release.prepare)"

      raise Error, "prepared release bundle is stale (#{formatted})#{hint}"
    end
  end

  defp run_publish_handoff!(prepared, opts) do
    if Map.get(prepared, :docs_path) && File.dir?(prepared.docs_path) do
      verify_docs_smoke!(prepared.docs_path)
    end

    project = prepared.project_path

    if File.regular?(Path.join(project, "mix.lock")) do
      run_checked_step!(
        opts[:deps_cmd] || default_mix_cmd(["deps.get", "--check-locked"]),
        project,
        "mix deps.get --check-locked"
      )
    end

    run_checked_step!(
      opts[:build_cmd] || default_mix_cmd(["hex.build"]),
      project,
      "mix hex.build"
    )

    rebuilt = Path.join(project, prepared.tarball_name)

    unless File.regular?(rebuilt) and Hash.sha256_file(rebuilt) == prepared.archive_sha256 do
      raise Error,
            "rebuilt Hex archive in #{project} does not match prepared SHA-256 #{prepared.archive_sha256}"
    end

    exit_status =
      run_interactive!(
        opts[:publish_cmd] || hex_publish_cmd(opts[:dry_run] == true),
        project
      )

    %{
      completed?: exit_status == 0,
      artifact: prepared.plan.artifact.id,
      exit_status: exit_status,
      identity: prepared.identity,
      package: prepared.package,
      version: prepared.version,
      archive_sha256: prepared.archive_sha256,
      project_path: project,
      warnings: prepared.warnings
    }
  end

  defp hex_publish_cmd(dry_run?) do
    shell_path = :code.which(Weld.ReleasePublishShell) |> Path.dirname()

    elixir =
      System.find_executable("elixir") || raise Error, "elixir executable not found on PATH"

    hex_args = if dry_run?, do: ["--dry-run", "--yes"], else: []

    {elixir, ["-pa", shell_path, "-S", "mix", "weld.hex_publish" | hex_args]}
  end

  defp default_mix_cmd(args) do
    executable = System.find_executable("mix") || raise Error, "mix executable not found on PATH"
    {executable, args}
  end

  defp verify_docs_smoke!(docs_path) do
    case DocsSmoke.check(docs_path) do
      {:ok, _summary} ->
        :ok

      {:error, errors} ->
        raise Error, "docs smoke check failed: " <> Enum.join(errors, "; ")
    end
  end

  defp publish_env do
    [
      {"MIX_ENV", "dev"},
      {"MIX_EXS", nil},
      {"MIX_LOCKFILE", nil},
      {"MIX_TARGET", nil},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil}
    ]
  end

  defp run_checked_step!({executable, args}, cd, label) do
    case System.cmd(executable, args, cd: cd, env: publish_env(), stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise Error, "#{label} failed (exit #{status}):\n#{String.trim(output)}"
    end
  end

  defp run_interactive!({executable, args}, cd) do
    env =
      Enum.map(publish_env(), fn {key, value} ->
        {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
      end)

    port =
      Port.open({:spawn_executable, executable}, [
        :nouse_stdio,
        :exit_status,
        {:cd, cd},
        {:env, env},
        {:args, args}
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  defp ensure_tarball_present!(metadata, bundle) do
    unless is_binary(metadata["tarball_path"]) do
      raise Error, "prepared release has no Hex archive: #{bundle}"
    end
  end

  defp write_publish_workspace!(root, bundle, project, metadata) do
    staging = Output.temporary!(root, "staging")

    try do
      copy = copy_publish_project!(staging, bundle, metadata)
      File.mkdir_p!(Path.dirname(project))
      File.rename!(copy, project)
    after
      File.rm_rf!(staging)
    end
  end

  defp replace_publish_workspace!(root, bundle, project, metadata) do
    staging = Output.temporary!(root, "staging")
    previous = Path.join(staging, "previous")

    try do
      copy = copy_publish_project!(staging, bundle, metadata)
      File.rename!(project, previous)

      try do
        File.rename!(copy, project)
      rescue
        error ->
          File.rename!(previous, project)
          reraise error, __STACKTRACE__
      end
    after
      File.rm_rf!(staging)
    end
  end

  defp copy_publish_project!(staging, bundle, metadata) do
    copy = Path.join(staging, "project")
    File.cp_r!(Path.join(bundle, "project"), copy)
    validate_publish_project!(copy, metadata)
    copy
  end

  defp validate_existing_publish_project!(project, metadata) do
    validate_publish_project!(project, metadata)
  rescue
    Error ->
      reraise Error,
              "publish workspace has changed: #{project}; re-run with --fresh to reset it",
              __STACKTRACE__
  end

  defp validate_publish_project!(project, metadata) do
    Output.reject_tree_links!(project)

    unless ReleaseStatus.valid_project?(
             project,
             metadata,
             metadata["integrity"] || metadata["handoff"]
           ) do
      raise Error, "publish workspace has changed: #{project}"
    end
  end

  @spec archive!(Plan.t(), keyword()) :: map()
  def archive!(%Plan{} = plan, opts \\ []) do
    Weld.Output.with_lock(plan.manifest.repo_root, fn -> archive_locked!(plan, opts) end)
  end

  defp archive_locked!(plan, opts) do
    prepared_bundle = bundle_path(plan, opts[:identity])

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

    %{archive_path: archive_path, source_bundle_path: prepared_bundle, identity: identity}
  end

  @spec track!(Plan.t(), keyword()) :: map()
  def track!(%Plan{} = plan, opts \\ []) do
    Weld.Output.with_lock(plan.manifest.repo_root, fn -> track_locked!(plan, opts) end)
  end

  defp track_locked!(plan, opts) do
    if opts[:tag] && opts[:tag_release] do
      raise Error, "pass either --tag or --tag-release, not both"
    end

    prepared_bundle = bundle_path(plan, opts[:identity])
    project_path = Path.join(prepared_bundle, "project")
    metadata = validate_bundle!(plan, prepared_bundle)
    track_opts = track_opts(plan, opts)

    {branch_created?, commit_sha, committed?} =
      track_projection!(plan, project_path, metadata, track_opts)

    %{
      artifact: plan.artifact.id,
      has_tarball: is_binary(metadata["tarball_path"]),
      branch: track_opts.branch,
      branch_created?: branch_created?,
      commit_sha: commit_sha,
      committed?: committed?,
      pushed?: track_opts.push?,
      tag: track_opts.tag,
      identity: metadata["identity"],
      warnings: ReleaseStatus.docs_source_ref_warnings(plan, track_opts.tag)
    }
  end

  @spec bundle_path(Plan.t(), String.t() | nil) :: Path.t()
  def bundle_path(plan, identity \\ nil)

  def bundle_path(%Plan{} = plan, nil) do
    current = current_path(plan)

    case File.read(current) do
      {:ok, bytes} -> release_path(plan, parse_pointer!(bytes))
      _ -> raise Error, "release bundle not prepared: #{current}"
    end
  end

  def bundle_path(%Plan{} = plan, identity) when is_binary(identity) do
    unless Regex.match?(~r/\A[0-9a-f]{64}\z/, identity) do
      raise Error, "invalid prepared identity: #{inspect(identity)}"
    end

    path = release_path(plan, identity)
    unless File.dir?(path), do: raise(Error, "release bundle not found: #{path}")
    path
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

  @doc false
  def default_tag(%Plan{artifact: %{package: package}}), do: "#{package.name}-v#{package.version}"

  defp track_opts(%Plan{} = plan, opts) do
    tag =
      if opts[:tag_release] do
        default_tag(plan)
      else
        opts[:tag]
      end

    %{
      branch: opts[:branch] || projection_branch(plan),
      remote: opts[:remote] || "origin",
      tag: tag,
      push?: Keyword.get(opts, :push, false),
      worktree_path: unique_worktree_path(plan)
    }
  end

  defp validate_bundle!(plan, bundle), do: validate_bundle!(plan, bundle, Path.basename(bundle))

  defp validate_bundle!(plan, bundle, expected_identity) do
    metadata = ReleaseStatus.validate_bundle_integrity!(bundle, expected_identity)
    package = metadata["package"]

    unless {package["name"], package["version"]} ==
             {plan.artifact.package.name, plan.artifact.package.version} and
             metadata["artifact"] == plan.artifact.id and
             metadata["manifest_digest"] == Hash.sha256_file(plan.manifest.manifest_path) do
      raise Error,
            "prepared release bundle is missing or failed integrity verification: #{bundle}"
    end

    metadata
  end

  defp unique_worktree_path(%Plan{} = plan) do
    path = Output.path(plan.manifest.repo_root, ["worktrees", Output.nonce()])
    File.mkdir_p!(Path.dirname(path))
    path
  end

  defp track_projection!(%Plan{} = plan, project_path, metadata, track_opts) do
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
      validate_tag_availability!(plan, metadata, track_opts, branch_created?)
      committed? = commit_projection!(plan, metadata, worktree_path, branch_created?)
      commit_sha = Git.revision(worktree_path)
      maybe_tag_projection!(plan, metadata, commit_sha, track_opts)
      maybe_push_projection!(track_opts)

      {branch_created?, commit_sha, committed?}
    after
      cleanup_worktree!(repo_root, worktree_path)
    end
  end

  defp commit_projection!(%Plan{} = plan, metadata, worktree_path, branch_created?) do
    message = ReleaseReceipt.format_commit_message(plan, metadata)

    cond do
      Git.staged_changes?(worktree_path) ->
        Git.commit_all!(worktree_path, message)
        true

      branch_created? ->
        Git.commit_all!(worktree_path, message, allow_empty: true)
        true

      tip_identity_matches?(worktree_path, metadata["identity"]) ->
        false

      true ->
        Git.commit_all!(worktree_path, message, allow_empty: true)
        true
    end
  end

  defp tip_identity_matches?(worktree_path, expected_identity) do
    case ReleaseReceipt.from_commit(worktree_path, "HEAD") do
      {:ok, %{identity: ^expected_identity}} -> true
      _ -> false
    end
  end

  defp validate_tag_availability!(_plan, _metadata, %{tag: nil}, _branch_created?), do: :ok

  defp validate_tag_availability!(plan, metadata, opts, branch_created?) do
    %{tag: tag, worktree_path: worktree} = opts
    Git.run!(worktree, ["check-ref-format", "refs/tags/#{tag}"])
    {:ok, expected} = ReleaseReceipt.parse(ReleaseReceipt.format_trailers(plan, metadata))

    case ReleaseReceipt.from_tag(worktree, tag) do
      :missing ->
        :ok

      {:ok, %{type: :annotated, target_sha: sha, receipt: ^expected}} ->
        unless reusable_tag?(worktree, sha, expected, branch_created?) do
          raise Error, "tag #{tag} already exists with a different commit or release identity"
        end

      {:ok, %{type: :lightweight}} ->
        raise Error,
              "legacy lightweight tag already exists: #{tag}; choose a new tag or inspect it manually"

      {:ok, _other} ->
        raise Error, "tag #{tag} already exists with a different commit or release identity"

      {:error, reason} ->
        raise Error, "existing tag #{tag} has invalid receipt metadata: #{reason}"
    end
  end

  defp reusable_tag?(_worktree, _sha, _receipt, true), do: false

  defp reusable_tag?(worktree, sha, receipt, false) do
    sha == Git.revision(worktree) and not Git.staged_changes?(worktree) and
      ReleaseReceipt.from_commit(worktree, sha) == {:ok, receipt}
  end

  defp maybe_tag_projection!(_plan, _metadata, _commit_sha, %{tag: nil}), do: :ok

  defp maybe_tag_projection!(plan, metadata, commit_sha, %{tag: tag, worktree_path: worktree_path}) do
    expected_identity = metadata["identity"]

    case ReleaseReceipt.from_tag(worktree_path, tag) do
      :missing ->
        tag_message = ReleaseReceipt.format_tag_message(plan, metadata, tag)
        Git.create_tag!(worktree_path, tag, tag_message)

      {:ok,
       %{type: :annotated, target_sha: ^commit_sha, receipt: %{identity: ^expected_identity}}} ->
        :ok

      {:ok, %{type: :lightweight}} ->
        raise Error,
              "legacy lightweight tag already exists: #{tag}; choose a new tag or inspect it manually"

      {:ok, _other} ->
        raise Error,
              "tag #{tag} already exists with a different commit or release identity"

      {:error, reason} ->
        raise Error, "existing tag #{tag} has invalid receipt metadata: #{reason}"
    end
  end

  defp maybe_push_projection!(%{push?: false}), do: :ok

  defp maybe_push_projection!(%{
         branch: branch,
         remote: remote,
         tag: tag,
         worktree_path: worktree_path
       }) do
    if tag do
      Git.push_release!(worktree_path, remote, branch, tag)
    else
      Git.push_branch!(worktree_path, remote, branch)
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
end
