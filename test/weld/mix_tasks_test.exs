defmodule Weld.MixTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Weld.FixtureCase

  test "release tasks reject unknown flags before resolving a manifest" do
    for command <- ~w(project verify prepare archive track) do
      output =
        capture_io(fn ->
          assert catch_exit(Mix.Task.rerun("weld", [command, "--unknown", "--format", "json"])) ==
                   {:shutdown, 2}
        end)

      assert %{"ok" => false, "diagnostics" => [%{"code" => "invalid_arguments"}]} =
               Jason.decode!(output)
    end
  end

  test "nested explicit setup and project share the checkout-root output" do
    root = FixtureCase.copy_fixture("source_project")
    FixtureCase.init_git!(root)

    File.cd!(Path.join(root, "components/pure"), fn ->
      Mix.Task.rerun("weld", ["setup"])
      Mix.Task.rerun("weld", ["project", "--artifact", "sprout", "--kind", "live"])
    end)

    assert File.dir?(Path.join(root, ".weld/v2/live/sprout"))
    refute File.exists?(Path.join(root, "components/pure/.weld"))
  end

  test "mix weld plan prints json output" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    output =
      capture_io(fn ->
        Mix.Task.rerun("weld", ["plan", "--manifest", manifest_path, "--format", "json"])
      end)

    assert output =~ "\"selected_projects\""
    assert output =~ "\"fixture_bundle\""
  end

  test "mix weld project generates the welded artifact" do
    manifest_path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    output =
      capture_io(fn ->
        Mix.Task.rerun("weld", ["project", "--manifest", manifest_path, "--format", "json"])
      end)

    assert %{"ok" => true, "data" => %{"build_path" => path}} = Jason.decode!(output)
    assert File.dir?(path)
  end

  test "mix weld plan discovers a build_support manifest without explicit args" do
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
          Mix.Task.rerun("weld", ["plan", "--root", repo_root, "--format", "json"])
        end)
      end)

    assert output =~ "\"fixture_bundle\""
    assert output =~ "\"selected_projects\""
  end

  test "mix weld project requires an explicit override for packaging manifests" do
    repo_root = FixtureCase.copy_fixture("library_bundle")

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          assert catch_exit(
                   Mix.Task.rerun("weld", ["project", "--root", repo_root, "--format", "json"])
                 ) ==
                   {:shutdown, 3}
        end)
      end)

    assert %{"ok" => false, "diagnostics" => [%{"message" => "manifest not found:" <> _}]} =
             Jason.decode!(output)
  end

  test "mix weld.release.track updates the projection branch from a prepared bundle" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    FixtureCase.init_git!(repo_root)
    FixtureCase.write_tracking_fixture!(repo_root, manifest_path)

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          Mix.Task.rerun("weld", [
            "track",
            "--manifest",
            manifest_path,
            "--current",
            "--format",
            "json"
          ])
        end)
      end)

    assert %{"ok" => true, "data" => %{"branch" => "projection/fixture_bundle"}} =
             Jason.decode!(output)
  end

  @tag integration: true, ci_build: "prepare_cli"
  test "mix weld prepare qualifies a selected manifest" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(repo_root)

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          Mix.Task.rerun("weld", [
            "prepare",
            "--manifest",
            "packaging/weld/fixture_bundle.exs",
            "--format",
            "json"
          ])
        end)
      end)

    assert %{"ok" => true, "data" => %{"bundle_path" => path}} = Jason.decode!(output)
    assert File.regular?(Path.join(path, "bundle.json"))
  end
end
