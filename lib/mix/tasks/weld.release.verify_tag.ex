defmodule Mix.Tasks.Weld.Release.VerifyTag do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Verify a Git tag's `weld.receipt/v1` trailers against its target commit and
  optional local bundle or tarball.
  """

  @shortdoc "Verify a Weld release tag receipt"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [artifact: :string, identity: :string, tarball: :string, format: :string]
      )

    usage =
      "Usage: mix weld.release.verify_tag <tag> [manifest_path] [--artifact name] [--identity sha] [--tarball path] [--format json]"

    TaskSupport.reject_invalid!(invalid)

    {tag, manifest_positional} =
      case positional do
        [tag] -> {tag, []}
        [tag, manifest] -> {tag, [manifest]}
        _ -> Mix.raise(usage)
      end

    manifest_path = TaskSupport.resolve_manifest_path!(manifest_positional, usage)
    result = Weld.release_verify_tag!(manifest_path, tag, opts)

    case opts[:format] do
      "json" -> Mix.shell().info(Jason.encode_to_iodata!(result, pretty: true))
      _ -> Mix.shell().info(result.message)
    end

    if result.status in [:mismatch, :missing_tag] do
      Mix.raise(result.message)
    end
  after
    Mix.Task.reenable("weld.release.verify_tag")
  end
end
