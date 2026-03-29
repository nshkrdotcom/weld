defmodule Mix.Tasks.Weld.Affected do
  use Mix.Task

  @moduledoc """
  Show which selected projects are affected by a Git diff range.
  """

  @shortdoc "Show affected projects for a task"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(
        args,
        strict: [artifact: :string, task: :string, base: :string, head: :string]
      )

    manifest_path =
      case positional do
        [path] ->
          path

        _ ->
          Mix.raise(
            "Usage: mix weld.affected <manifest_path> --task verify.all --base main --head HEAD [--artifact name]"
          )
      end

    result =
      Weld.affected!(
        manifest_path,
        artifact: opts[:artifact],
        task: opts[:task] || "verify.all",
        base: opts[:base] || "main",
        head: opts[:head] || "HEAD"
      )

    Mix.shell().info(Jason.encode_to_iodata!(result, pretty: true))
  after
    Mix.Task.reenable("weld.affected")
  end
end
