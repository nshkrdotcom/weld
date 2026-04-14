defmodule Mix.Tasks.Weld.Release.Track do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Track a prepared welded release bundle on a projection branch.
  """

  @shortdoc "Track a welded release bundle on a projection branch"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          artifact: :string,
          branch: :string,
          remote: :string,
          tag: :string,
          push: :boolean
        ]
      )

    usage =
      "Usage: mix weld.release.track [manifest_path] [--artifact name] [--branch name] [--remote origin] [--tag tag] [--push]"

    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

    result =
      Weld.release_track!(manifest_path,
        artifact: opts[:artifact],
        branch: opts[:branch],
        remote: opts[:remote],
        tag: opts[:tag],
        push: opts[:push] || false
      )

    message =
      [
        "Tracked projection branch #{result.branch}",
        if(result.branch_created?, do: "created", else: "updated"),
        "at #{result.commit_sha}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    Mix.shell().info(message)
  after
    Mix.Task.reenable("weld.release.track")
  end
end
