defmodule Weld.ExplainTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "help exposes all lifecycle commands without a manifest" do
    help = capture_io(fn -> Mix.Task.rerun("weld", ["help"]) end)

    for command <- ~w(project verify prepare stage track publish reconcile archive path) do
      assert help =~ command

      assert capture_io(fn -> Mix.Task.rerun("weld", ["help", command]) end) =~
               "mix weld #{command}"
    end
  end
end
