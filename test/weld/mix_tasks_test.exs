defmodule Weld.MixTasksTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Weld.FixtureCase

  test "mix weld.build builds a projection from a manifest path" do
    manifest_path = FixtureCase.manifest_path("library_bundle", "sample")
    dist_root = FixtureCase.unique_tmp_dir("weld_mix_task")

    output =
      capture_io(fn ->
        Mix.Task.rerun("weld.build", [manifest_path, "--dist-root", dist_root])
      end)

    assert output =~ "Built projection"
    assert File.exists?(Path.join([dist_root, "hex", "fixture_bundle", "mix.exs"]))
  end
end
