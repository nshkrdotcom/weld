defmodule Weld.MixTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Weld.FixtureCase

  test "mix weld.inspect prints json output" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    output =
      capture_io(fn ->
        Mix.Task.rerun("weld.inspect", [manifest_path, "--format", "json"])
      end)

    assert output =~ "\"selected_projects\""
    assert output =~ "\"fixture_bundle\""
  end

  test "mix weld.project generates the welded artifact" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    output =
      capture_io(fn ->
        Mix.Task.rerun("weld.project", [manifest_path])
      end)

    assert output =~ "Projected artifact"
  end
end
