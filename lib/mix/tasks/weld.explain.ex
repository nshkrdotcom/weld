defmodule Mix.Tasks.Weld.Explain do
  use Mix.Task

  @moduledoc """
  Explain Weld's projection kinds, where each lives, and which task creates it.

  Pass `--format json` for machine-readable output.
  """

  @shortdoc "Explain Weld projection kinds and locations"

  @kinds [
    %{
      kind: "live",
      path: ".weld/live/<artifact>",
      purpose:
        "Development view that links the working tree's source files; point path deps here.",
      task: "mix weld.project --live"
    },
    %{
      kind: "full",
      path: ".weld/full/<artifact>/project",
      purpose: "Complete projected Mix project, including generated mix.exs and docs options.",
      task: "mix weld.project"
    },
    %{
      kind: "release",
      path: ".weld/releases/<artifact>/<identity>/project",
      purpose: "Immutable, content-addressed bundle prepared for release.",
      task: "mix weld.release.prepare"
    },
    %{
      kind: "publish",
      path: ".weld/publish/<artifact>/<hash>/run-*/project",
      purpose: "Workspace where docs are built and the package is published to Hex.",
      task: "mix weld.release.publish"
    },
    %{
      kind: "tracked",
      path: "git branch projection/<package>",
      purpose: "Exact-revision snapshot that others can depend on by Git.",
      task: "mix weld.release.track"
    }
  ]

  @doc false
  def kinds, do: @kinds

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: [format: :string])
    Weld.TaskSupport.reject_invalid!(invalid)

    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode_to_iodata!(@kinds, pretty: true))

      _ ->
        Mix.shell().info(
          Enum.map_join(@kinds, "\n", fn k ->
            "#{k.kind}: #{k.path}\n  #{k.purpose}\n  created by: #{k.task}"
          end)
        )
    end
  after
    Mix.Task.reenable("weld.explain")
  end
end
