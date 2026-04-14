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

  test "mix weld.inspect discovers a build_support manifest without explicit args" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])
    build_support_path = Path.join([repo_root, "build_support", "weld.exs"])

    manifest =
      manifest_path
      |> File.read!()
      |> String.replace(~s(root: "../.."), ~s(root: ".."))

    File.mkdir_p!(Path.dirname(build_support_path))
    File.write!(build_support_path, manifest)

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          Mix.Task.rerun("weld.inspect", ["--format", "json"])
        end)
      end)

    assert output =~ "\"fixture_bundle\""
    assert output =~ "\"selected_projects\""
  end

  test "mix weld.project discovers a packaging manifest without explicit args" do
    repo_root = FixtureCase.copy_fixture("library_bundle")

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          Mix.Task.rerun("weld.project", [])
        end)
      end)

    assert output =~ "Projected artifact"
  end

  test "mix weld.release.track updates the projection branch from a prepared bundle" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    FixtureCase.init_git!(repo_root)
    Weld.release_prepare!(manifest_path)

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          Mix.Task.rerun("weld.release.track", [manifest_path])
        end)
      end)

    assert output =~ "Tracked projection branch"
    assert output =~ "projection/fixture_bundle"
  end

  test "mix release.prepare delegates to weld release autodiscovery" do
    repo_root = FixtureCase.copy_fixture("library_bundle")

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          Mix.Task.rerun("release.prepare", [])
        end)
      end)

    assert output =~ "Prepared release bundle in"
  end
end
