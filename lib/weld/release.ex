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
end
