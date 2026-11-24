defmodule Mix.Tasks.Weld.Affected do
  use Mix.Task

  alias Weld.TaskSupport

  @moduledoc """
  Show affected projects and artifacts for a Git diff range.

  Uses artifact source ownership as well as Mix dependency relationships.
  """

  @shortdoc "Show affected projects for a task"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(
        args,
        strict: [artifact: :string, task: :string, base: :string, head: :string]
      )

    usage =
      "Usage: mix weld.affected [manifest_path] --task verify.all --base main --head HEAD [--artifact name]"

    manifest_path = TaskSupport.resolve_manifest_path!(positional, usage)

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
