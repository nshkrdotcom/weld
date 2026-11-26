defmodule Weld.ExplainTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Weld.Explain

  test "json output lists every projection kind with an existing creating task" do
    json = capture_io(fn -> Explain.run(["--format", "json"]) end)
    kinds = Jason.decode!(json)

    assert Enum.map(kinds, & &1["kind"]) == ~w(live full release publish tracked)

    for %{"task" => "mix " <> command} <- kinds do
      task = command |> String.split() |> hd()
      assert Mix.Task.get(task), "#{task} is not a Mix task"
    end
  end
end
