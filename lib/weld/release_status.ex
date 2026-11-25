defmodule Weld.ReleaseStatus do
  @moduledoc """
  Read-only release-state classification, bundle integrity checking, and Git
  receipt verification.
  """

  alias Weld.{Error, Git, Hash, Output, Plan, Release, ReleaseReceipt}

  @type bundle_state ::
          :ready
          | :stale
          | :unprepared
          | :malformed_pointer
          | :missing_bundle
          | :corrupt_bundle

  @spec status(Plan.t(), keyword()) :: map()
  def status(%Plan{} = plan, opts \\ []) do
    repo_root = plan.manifest.repo_root
    current_revision = Git.revision(repo_root)
    warnings = docs_source_ref_warnings(plan, opts[:tag])

    case resolve_target(plan, opts[:identity]) do
      {:error, state, reason} ->
        empty_status(plan, state, [reason], current_revision, warnings)

      {:ok, identity, bundle} ->
        inspect_bundle(plan, identity, bundle, current_revision, warnings)
    end
  end

  @spec validate_bundle_integrity!(Path.t(), String.t()) :: map()
  def validate_bundle_integrity!(bundle, expected_identity) do
    Output.reject_tree_links!(bundle)
    metadata_path = Path.join(bundle, "release.json")

    with {:ok, json} <- File.read(metadata_path),
         {:ok, %{} = metadata} <- Jason.decode(json),
         true <-
           metadata["identity"] == expected_identity and
             Release.identity(metadata) == expected_identity,
         %{"name" => name, "version" => version} <- metadata["package"],
         true <- valid_inventory?(bundle, metadata),
         true <- valid_bundle_contents?(bundle, metadata, "#{name}-#{version}.tar") do
      metadata
    else
      _ ->
        raise Error,
              "prepared release bundle is missing or failed integrity verification: #{bundle}"
    end
  end

  @spec freshness_reasons(Plan.t(), map(), String.t() | nil) :: [atom()]
  def freshness_reasons(%Plan{} = plan, metadata, current_revision) do
    repo_root = plan.manifest.repo_root
    pkg = metadata["package"] || %{}
    manifest_digest = Hash.sha256_file(plan.manifest.manifest_path)

    []
    |> add_if(
      {pkg["name"], pkg["version"]} != {plan.artifact.package.name, plan.artifact.package.version} or
        metadata["artifact"] != plan.artifact.id,
      :package_mismatch
    )
    |> add_if(metadata["manifest_digest"] != manifest_digest, :manifest_changed)
    |> add_if(metadata["weld_version"] != Weld.version(), :weld_version_changed)
    |> add_if(
      is_nil(metadata["source_revision"]) and not is_nil(current_revision),
      :no_git_revision
    )
    |> add_if(
      is_binary(metadata["source_revision"]) and is_binary(current_revision) and
        metadata["source_revision"] != current_revision,
      :head_moved
    )
    |> add_if(not is_nil(current_revision) and Git.dirty?(repo_root), :dirty_worktree)
    |> Enum.reverse()
  end

  @spec docs_source_ref_warnings(Plan.t(), String.t() | nil) :: [String.t()]
  def docs_source_ref_warnings(%Plan{} = plan, tag \\ nil) do
    docs = plan.artifact.package.docs
    mutable_refs = ["main", "master", "HEAD"]

    []
    |> add_if(
      plan.artifact.mode in [:package_projection, :monolith] and is_binary(docs.source_url) and
        (is_nil(docs.source_ref) or docs.source_ref in mutable_refs),
      "docs.source_ref is #{inspect(docs.source_ref)} for #{plan.artifact.id}; set an immutable projection tag for accurate ExDoc source links"
    )
    |> add_if(
      is_binary(tag) and is_binary(docs.source_ref) and docs.source_ref != tag,
      "docs.source_ref (#{docs.source_ref}) differs from tracked tag (#{tag}) for #{plan.artifact.id}"
    )
    |> Enum.reverse()
  end

  @spec verify_tag(Path.t(), String.t(), keyword()) :: map()
  def verify_tag(repo_root, tag, opts \\ []) do
    case ReleaseReceipt.from_tag(repo_root, tag) do
      :missing ->
        %{tag: tag, status: :missing_tag, message: "Git tag not found: #{tag}"}

      {:error, reason} ->
        %{tag: tag, status: :mismatch, message: reason}

      {:ok, %{type: :lightweight, target_sha: target_sha}} ->
        verify_lightweight_tag(repo_root, tag, target_sha)

      {:ok, %{type: :annotated, target_sha: target_sha, receipt: nil}} ->
        %{
          tag: tag,
          status: :legacy_tag,
          target_sha: target_sha,
          message: "annotated tag has no Weld receipt trailers: #{tag}"
        }

      {:ok, %{type: :annotated, target_sha: target_sha, receipt: tag_receipt}} ->
        verify_annotated_tag(repo_root, tag, target_sha, tag_receipt, opts)
    end
  end

  defp verify_lightweight_tag(repo_root, tag, target_sha) do
    commit_receipt =
      case ReleaseReceipt.from_commit(repo_root, target_sha) do
        {:ok, receipt} -> receipt
        _ -> nil
      end

    %{
      tag: tag,
      status: :legacy_tag,
      target_sha: target_sha,
      tag_receipt: nil,
      commit_receipt: commit_receipt,
      message: "lightweight tag predates weld.receipt/v1: #{tag}"
    }
  end

  defp verify_annotated_tag(repo_root, tag, target_sha, tag_receipt, opts) do
    commit_result = ReleaseReceipt.from_commit(repo_root, target_sha)

    case commit_result do
      {:ok, commit_receipt} when commit_receipt == tag_receipt ->
        compare_local_evidence(tag, target_sha, tag_receipt, commit_receipt, opts)

      {:ok, commit_receipt} ->
        %{
          tag: tag,
          status: :mismatch,
          target_sha: target_sha,
          tag_receipt: tag_receipt,
          commit_receipt: commit_receipt,
          message: "tag receipt disagrees with target commit receipt"
        }

      _ ->
        %{
          tag: tag,
          status: :mismatch,
          target_sha: target_sha,
          tag_receipt: tag_receipt,
          commit_receipt: nil,
          message: "target commit #{target_sha} is missing a matching Weld receipt"
        }
    end
  end

  defp compare_local_evidence(tag, target_sha, tag_receipt, commit_receipt, opts) do
    bundle_check = check_bundle_evidence(tag_receipt, opts[:plan], opts[:identity])
    tarball_check = check_tarball_evidence(tag_receipt, opts[:tarball])

    status =
      cond do
        :mismatch in [bundle_check, tarball_check] -> :mismatch
        bundle_check == :missing_local and is_nil(opts[:tarball]) -> :missing_local
        tarball_check == :missing_local -> :missing_local
        true -> :match
      end

    %{
      tag: tag,
      status: status,
      target_sha: target_sha,
      tag_receipt: tag_receipt,
      commit_receipt: commit_receipt,
      local_bundle: bundle_check,
      local_tarball: tarball_check,
      message: status_message(status, tag, tag_receipt[:identity])
    }
  end

  defp check_bundle_evidence(_receipt, nil, _identity), do: :not_checked

  defp check_bundle_evidence(receipt, %Plan{} = plan, identity_opt) do
    expected = identity_opt || receipt[:identity]
    bundle = Output.path(plan.manifest.repo_root, ["releases", plan.artifact.id, expected])

    if File.dir?(bundle) do
      try do
        metadata = validate_bundle_integrity!(bundle, expected)
        integrity = metadata["integrity"] || %{}

        if metadata["identity"] == receipt[:identity] and
             integrity["archive_sha256"] == receipt[:archive_sha256] and
             integrity["project_sha256"] == receipt[:project_sha256] do
          :match
        else
          :mismatch
        end
      rescue
        Error -> :mismatch
      end
    else
      :missing_local
    end
  end

  defp check_tarball_evidence(_receipt, nil), do: :not_checked

  defp check_tarball_evidence(receipt, path) do
    cond do
      not File.regular?(path) -> :missing_local
      is_nil(receipt[:archive_sha256]) -> :mismatch
      Hash.sha256_file(path) == receipt[:archive_sha256] -> :match
      true -> :mismatch
    end
  end

  defp status_message(:match, tag, id),
    do: "Tag #{tag} matches commit receipt and local evidence (#{String.slice(id, 0, 12)})"

  defp status_message(:missing_local, tag, id),
    do:
      "Tag #{tag} and commit receipt agree (#{String.slice(id, 0, 12)}), but local bundle/tarball is absent"

  defp status_message(:mismatch, tag, _id),
    do: "Tag #{tag} failed receipt or local evidence verification"

  defp resolve_target(plan, nil) do
    current = Output.path(plan.manifest.repo_root, ["releases", plan.artifact.id, "CURRENT"])

    case File.read(current) do
      {:error, :enoent} ->
        {:error, :unprepared, :missing_current}

      {:error, _reason} ->
        {:error, :malformed_pointer, :unreadable_current}

      {:ok, bytes} ->
        resolve_pointer(plan, bytes)
    end
  end

  defp resolve_target(plan, identity) when is_binary(identity) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, identity) do
      bundle = Output.path(plan.manifest.repo_root, ["releases", plan.artifact.id, identity])

      if File.dir?(bundle),
        do: {:ok, identity, bundle},
        else: {:error, :missing_bundle, :missing_bundle}
    else
      {:error, :malformed_pointer, :invalid_identity}
    end
  end

  defp resolve_pointer(plan, "weld.release/v1 " <> rest) do
    identity = String.trim_trailing(rest, "\n")
    resolve_target(plan, identity)
  end

  defp resolve_pointer(_plan, _other), do: {:error, :malformed_pointer, :unmanaged_pointer}

  defp inspect_bundle(plan, identity, bundle, current_revision, warnings) do
    metadata = validate_bundle_integrity!(bundle, identity)
    reasons = freshness_reasons(plan, metadata, current_revision)
    integrity = metadata["integrity"] || metadata["handoff"] || %{}
    state = if reasons == [], do: :ready, else: :stale

    %{
      artifact: plan.artifact.id,
      package: plan.artifact.package.name,
      version: plan.artifact.package.version,
      state: state,
      reasons: reasons,
      identity: identity,
      short_identity: String.slice(identity, 0, 12),
      source_revision: metadata["source_revision"],
      current_revision: current_revision,
      has_tarball: is_binary(metadata["tarball_path"]),
      archive_sha256: integrity["archive_sha256"],
      project_sha256: integrity["project_sha256"],
      docs_sha256: integrity["docs_sha256"],
      publish_workspace: publish_workspace_state(plan, identity, metadata),
      archived: archived?(plan, identity),
      projection: projection_status(plan, identity),
      warnings: warnings
    }
  rescue
    Error ->
      empty_status(plan, :corrupt_bundle, [:corrupt_bundle], current_revision, warnings, identity)
  end

  defp empty_status(plan, state, reasons, current_revision, warnings, identity \\ nil) do
    %{
      artifact: plan.artifact.id,
      package: plan.artifact.package.name,
      version: plan.artifact.package.version,
      state: state,
      reasons: reasons,
      identity: identity,
      short_identity: identity && String.slice(identity, 0, 12),
      source_revision: nil,
      current_revision: current_revision,
      has_tarball: false,
      archive_sha256: nil,
      project_sha256: nil,
      docs_sha256: nil,
      publish_workspace: :none,
      archived: false,
      projection: projection_status(plan, identity),
      warnings: warnings
    }
  end

  defp publish_workspace_state(plan, identity, metadata) do
    project =
      Output.path(plan.manifest.repo_root, ["publish", plan.artifact.id, identity, "project"])

    if File.dir?(project) do
      integrity = metadata["integrity"] || metadata["handoff"] || %{}

      try do
        Output.reject_tree_links!(project)

        if valid_project?(project, metadata, integrity) do
          :clean
        else
          :dirty
        end
      rescue
        Error -> :dirty
      end
    else
      :none
    end
  end

  defp archived?(plan, identity) do
    archive = Output.path(plan.manifest.repo_root, ["archive", plan.artifact.id, identity])

    if File.dir?(archive) do
      try do
        _ = validate_bundle_integrity!(archive, identity)
        true
      rescue
        Error -> false
      end
    else
      false
    end
  end

  defp projection_status(plan, identity) do
    repo_root = plan.manifest.repo_root
    branch = "projection/#{plan.artifact.package.name}"

    if Git.branch_exists?(repo_root, branch) do
      tip_sha =
        case Git.rev_parse(repo_root, "refs/heads/#{branch}") do
          {:ok, sha} -> sha
          {:error, _} -> nil
        end

      receipt_id =
        case ReleaseReceipt.from_commit(repo_root, "refs/heads/#{branch}") do
          {:ok, receipt} -> receipt[:identity]
          _ -> nil
        end

      %{
        branch: branch,
        scope: :local,
        exists: true,
        tip_sha: tip_sha,
        receipt_identity: receipt_id,
        matches_identity: is_binary(identity) and receipt_id == identity
      }
    else
      %{
        branch: branch,
        scope: :local,
        exists: false,
        tip_sha: nil,
        receipt_identity: nil,
        matches_identity: false
      }
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
      valid_project?(project, metadata, integrity) and
      valid_docs?(docs, metadata["integrity"]) and
      match_identity?(docs, integrity["docs_identity"])
  end

  defp valid_project?(project, metadata, integrity) do
    File.dir?(project) and Hash.sha256_tree(project) == integrity["project_sha256"] and
      valid_lock?(project, metadata) and match_identity?(project, integrity["project_identity"])
  end

  defp valid_lock?(project, %{"lock_sha256" => digest}) do
    lock_path = Path.join(project, "mix.lock")
    actual = if File.regular?(lock_path), do: Hash.sha256_file(lock_path), else: nil
    digest == actual
  end

  defp valid_lock?(_project, _metadata), do: true

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

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list
end
