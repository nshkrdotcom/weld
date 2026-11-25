defmodule Weld.ReleasePublishShell do
  @moduledoc false
  @behaviour Mix.Shell

  @impl Mix.Shell
  defdelegate print_app(), to: Mix.Shell.IO
  @impl Mix.Shell
  defdelegate info(message), to: Mix.Shell.IO
  @impl Mix.Shell
  defdelegate error(message), to: Mix.Shell.IO
  @impl Mix.Shell
  defdelegate prompt(message), to: Mix.Shell.IO
  @impl Mix.Shell
  defdelegate cmd(command), to: Mix.Shell.IO
  @impl Mix.Shell
  defdelegate cmd(command, opts), to: Mix.Shell.IO

  @impl Mix.Shell
  def yes?(message, opts \\ []) do
    if Mix.Shell.IO.yes?(message, opts) do
      true
    else
      Mix.raise("Hex publication cancelled")
    end
  end
end

defmodule Mix.Tasks.Weld.HexPublish do
  @moduledoc false
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.shell(Weld.ReleasePublishShell)
    Mix.Task.run("hex.publish", args)
  end
end
