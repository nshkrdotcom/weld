defmodule Weld.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase
  alias Weld.Manifest
  alias Weld.Workspace

  test "discovers projects from manifest globs when the repo root has no mix.exs" do
    manifest = Manifest.load!(FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle"))
    workspace = Workspace.load!(manifest)

    assert workspace.discovery.source == :manifest
    refute workspace.discovery.root_project?
    assert Map.keys(workspace.projects) == ["core/contracts", "runtime/local"]
  end

  test "loads each project's declared test paths" do
    manifest = Manifest.load!(FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle"))
    workspace = Workspace.load!(manifest)

    assert workspace.projects["core/store"].test_paths == ["test"]
    assert workspace.projects["runtime/api"].test_paths == ["test/fixture"]
  end

  test "discovers projects from explicit manifest globs when the root has a mix.exs" do
    manifest = Manifest.load!(FixtureCase.copied_manifest_path("root_workspace", "artifacts"))
    workspace = Workspace.load!(manifest)

    assert workspace.discovery.source == :manifest
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
    purge_module(RootWorkspace.MixProject)

    Mix.Project.in_project(:weld_workspace_current_root, repo_root, [], fn _module ->
      manifest = Manifest.load!(manifest_path)
      workspace = Workspace.load!(manifest)

      assert workspace.discovery.source == :manifest
      assert Map.has_key?(workspace.projects, ".")
    end)
  end

  test "does not duplicate the root project when blitz_workspace already includes dot" do
    repo_root = FixtureCase.copy_fixture("root_workspace")
    manifest_path = Path.join([repo_root, "packaging", "weld", "artifacts.exs"])
    mix_path = Path.join(repo_root, "mix.exs")

    mix_path
    |> File.read!()
    |> String.replace(
      ~s(projects: ["apps/*", "proofs/*", "tooling/*"]),
      ~s(projects: [".", "apps/*", "proofs/*", "tooling/*"])
    )
    |> then(&File.write!(mix_path, &1))

    purge_module(RootWorkspace.MixProject)

    Mix.Project.in_project(:weld_workspace_with_dot_root, repo_root, [], fn _module ->
      manifest = Manifest.load!(manifest_path)
      workspace = Workspace.load!(manifest)

      assert workspace.discovery.project_ids == [
               ".",
               "apps/core",
               "apps/web",
               "proofs/demo",
               "tooling/test_support"
             ]
    end)
  end

  test "explicit dot directories and overlapping globs are detected before probing" do
    root = FixtureCase.copy_fixture("root_workspace")
    manifest = Manifest.load!(Path.join(root, "packaging/weld/artifacts.exs"))
    hidden = Path.join(root, ".nested/hidden")
    File.mkdir_p!(hidden)
    File.write!(Path.join(hidden, "mix.exs"), "# discovery only")
    globs = manifest.workspace.project_globs ++ [".nested/*"]
    manifest = put_in(manifest.workspace.project_globs, globs)

    assert ".nested/hidden" in Workspace.Discovery.discover(manifest).project_ids

    manifest = put_in(manifest.workspace.project_globs, globs ++ [".nested/hidden"])

    assert_raise Weld.Error, ~r/globs overlap at .nested\/hidden/, fn ->
      Workspace.Discovery.discover(manifest)
    end
  end

  test "Mix probes isolate same-named projects and evaluate the test environment" do
    path = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    manifest = Manifest.load!(path)

    for {dir, app} <- [
          {"core/contracts", :fixture_contracts},
          {"runtime/local", :fixture_runtime}
        ] do
      File.write!(Path.join([manifest.repo_root, dir, "mix.exs"]), """
      defmodule WeldFixture.IsolatedProject do
        use Mix.Project
        @env Mix.env()
        def project do
          [app: #{inspect(app)}, version: "0.1.0",
           test_paths: if(@env == :test, do: ["test/isolated"], else: ["wrong-env"])]
        end
      end
      """)
    end

    parent_project = Mix.Project.get()
    parent_env = Mix.env()
    workspace = Workspace.load!(manifest)

    assert workspace.projects["core/contracts"].app == :fixture_contracts
    assert workspace.projects["runtime/local"].app == :fixture_runtime
    assert workspace.projects["runtime/local"].test_paths == ["test/isolated"]
    assert Mix.Project.get() == parent_project
    assert Mix.env() == parent_env
    refute Code.ensure_loaded?(WeldFixture.IsolatedProject)
  end

  defp purge_module(module) do
    :code.purge(module)
    :code.delete(module)
  end
end
