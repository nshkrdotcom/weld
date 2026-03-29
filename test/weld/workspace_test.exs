defmodule Weld.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase
  alias Weld.Manifest
  alias Weld.Workspace

  test "discovers projects from manifest globs when the repo root has no mix.exs" do
    manifest = Manifest.load!(FixtureCase.manifest_path("library_bundle", "fixture_bundle"))
    workspace = Workspace.load!(manifest)

    assert workspace.discovery.source == :manifest
    refute workspace.discovery.root_project?
    assert Map.keys(workspace.projects) == ["core/contracts", "runtime/local"]
  end

  test "discovers projects from blitz_workspace when the root has a mix.exs" do
    manifest = Manifest.load!(FixtureCase.manifest_path("root_workspace", "artifacts"))
    workspace = Workspace.load!(manifest)

    assert workspace.discovery.source == :blitz_workspace
    assert workspace.discovery.root_project?

    assert Map.keys(workspace.projects) == [
             ".",
             "apps/core",
             "apps/web",
             "proofs/demo",
             "tooling/test_support"
           ]
  end

  test "reuses the already loaded root project when the manifest repo is the current project" do
    repo_root = FixtureCase.copy_fixture("root_workspace")
    manifest_path = Path.join([repo_root, "packaging", "weld", "artifacts.exs"])

    Mix.Project.in_project(:weld_workspace_current_root, repo_root, [], fn _module ->
      manifest = Manifest.load!(manifest_path)
      workspace = Workspace.load!(manifest)

      assert workspace.discovery.source == :blitz_workspace
      assert Map.has_key?(workspace.projects, ".")
    end)
  end
end
