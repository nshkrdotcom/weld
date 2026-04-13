defmodule Weld.Release do
  @moduledoc """
  Prepares and archives deterministic welded release bundles.
  """

  alias Weld.Error
  alias Weld.Git
  alias Weld.Hash
  alias Weld.Plan
  alias Weld.Verifier

  @spec prepare!(Plan.t()) :: map()
  def prepare!(%Plan{} = plan) do
    plan = Plan.ensure_valid!(plan)
    verification = Verifier.verify!(plan)
    bundle_path = bundle_path(plan)
    relative_manifest_path = manifest_path(plan)
    manifest_digest = Hash.sha256_file(plan.manifest.manifest_path)

    File.rm_rf!(bundle_path)
    File.mkdir_p!(bundle_path)

    project_target = Path.join(bundle_path, "project")
    File.cp_r!(verification.build_path, project_target)

    tarball_path = verification.tarball_path
    tarball_target = Path.join(bundle_path, Path.basename(tarball_path))
    File.cp!(tarball_path, tarball_target)

    release_json =
      %{
        artifact: plan.artifact.id,
        package: %{
          name: plan.artifact.package.name,
          version: plan.artifact.package.version,
          otp_app: plan.artifact.package.otp_app
        },
        source_revision: Git.revision(plan.manifest.repo_root),
        manifest_path: relative_manifest_path,
        manifest_digest: manifest_digest,
        weld_version: Weld.version(),
        elixir_version: System.version(),
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        prepared_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

    release_json_path = Path.join(bundle_path, "release.json")
    File.write!(release_json_path, Jason.encode_to_iodata!(release_json, pretty: true))

    %{
      bundle_path: bundle_path,
      tarball_path: tarball_target,
      release_metadata_path: release_json_path,
      build_path: verification.build_path
    }
  end

  @spec archive!(Plan.t()) :: map()
  def archive!(%Plan{} = plan) do
    prepared_bundle = bundle_path(plan)

    unless File.dir?(prepared_bundle) do
      raise Error, "release bundle not prepared: #{prepared_bundle}"
    end

    archive_root =
      Path.expand(
        Path.join([plan.artifact.output.dist_root, "archive", plan.artifact.package.name]),
        plan.manifest.repo_root
      )

    archive_path = Path.join(archive_root, bundle_slug(plan))

    File.rm_rf!(archive_path)
    File.mkdir_p!(archive_root)
    File.cp_r!(prepared_bundle, archive_path)

    %{archive_path: archive_path, source_bundle_path: prepared_bundle}
  end

  @spec track!(Plan.t(), keyword()) :: map()
  def track!(%Plan{} = plan, opts \\ []) do
    prepared_bundle = bundle_path(plan)
    project_path = Path.join(prepared_bundle, "project")
    metadata_path = Path.join(prepared_bundle, "release.json")

    ensure_track_inputs!(prepared_bundle, project_path, metadata_path)
    track_opts = track_opts(plan, opts)
    source_revision = source_revision!(metadata_path)

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
    Path.expand(
      Path.join([
        plan.artifact.output.dist_root,
        "release_bundles",
        plan.artifact.package.name,
        bundle_slug(plan)
      ]),
      plan.manifest.repo_root
    )
  end

  defp bundle_slug(plan) do
    manifest_path = manifest_path(plan)
    manifest_digest = Hash.sha256_file(plan.manifest.manifest_path)

    digest =
      Hash.sha256_binary(
        "#{plan.artifact.package.name}:#{plan.artifact.package.version}:#{plan.artifact.id}:#{manifest_path}:#{manifest_digest}"
      )
      |> binary_part(0, 12)

    "#{plan.artifact.package.version}-#{digest}"
  end

  defp manifest_path(plan) do
    Path.relative_to(plan.manifest.manifest_path, plan.manifest.repo_root)
  end

  defp projection_branch(%Plan{} = plan) do
    "projection/#{plan.artifact.package.name}"
  end

  defp track_opts(%Plan{} = plan, opts) do
    %{
      branch: opts[:branch] || projection_branch(plan),
      remote: opts[:remote] || "origin",
      tag: opts[:tag],
      push?: Keyword.get(opts, :push, false),
      worktree_path: unique_worktree_path(plan)
    }
  end

  defp ensure_track_inputs!(prepared_bundle, project_path, metadata_path) do
    unless File.dir?(project_path) do
      raise Error, "release bundle not prepared: #{prepared_bundle}"
    end

    unless File.regular?(metadata_path) do
      raise Error, "release metadata not found: #{metadata_path}"
    end
  end

  defp source_revision!(metadata_path) do
    metadata_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("source_revision", "unknown")
  end

  defp unique_worktree_path(%Plan{} = plan) do
    base =
      "weld_projection_#{plan.artifact.package.name}_#{System.unique_integer([:positive, :monotonic])}"

    Path.join(System.tmp_dir!(), base)
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
    File.rm_rf!(worktree_path)

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
