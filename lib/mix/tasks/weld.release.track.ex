defmodule Mix.Tasks.Weld.Release.Track do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Track a prepared welded release bundle on a projection branch with
  `weld.receipt/v1` trailers and optional annotated release tags.
  """

  @shortdoc "Track a welded release bundle on a projection branch"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          artifact: :string,
          identity: :string,
          branch: :string,
          remote: :string,
          tag: :string,
          tag_release: :boolean,
          push: :boolean
        ]
      )

    usage =
      "Usage: mix weld.release.track [manifest_path] [--artifact name] [--identity sha] [--branch name] [--remote origin] [--tag tag | --tag-release] [--push]"

    TaskSupport.reject_invalid!(invalid)

    if opts[:tag] && opts[:tag_release],
      do: Mix.raise("Pass either --tag or --tag-release, not both")

    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result =
      Weld.release_track!(manifest_path,
        artifact: opts[:artifact],
        identity: opts[:identity],
        branch: opts[:branch],
        remote: opts[:remote],
        tag: opts[:tag],
        tag_release: opts[:tag_release] == true,
        push: opts[:push] || false
      )

    message =
      [
        "Tracked projection branch #{result.branch}",
        if(result.branch_created?, do: "created", else: "updated"),
        "at #{result.commit_sha}",
        "(identity #{result.identity})"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    Mix.shell().info(message)
    if result.tag, do: Mix.shell().info("Tagged #{result.tag}")

    Enum.each(result.warnings, fn warning ->
      Mix.shell().error("Warning: #{warning}")
    end)
  after
    Mix.Task.reenable("weld.release.track")
  end
end
