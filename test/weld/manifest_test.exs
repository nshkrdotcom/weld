defmodule Weld.ManifestTest do
  use ExUnit.Case, async: true

  alias Weld.FixtureCase
  alias Weld.Manifest

  test "loads a single-artifact manifest" do
    manifest = Manifest.load!(FixtureCase.manifest_path("library_bundle", "fixture_bundle"))
    artifact = Manifest.artifact!(manifest, nil)

    assert manifest.workspace.project_globs == ["core/*", "runtime/*"]
    assert manifest.dependencies == %{}
    assert artifact.id == "fixture_bundle"
    assert artifact.roots == ["runtime/local"]
    assert artifact.verify.smoke.enabled
  end

  test "requires an explicit artifact when the manifest defines more than one" do
    manifest = Manifest.load!(FixtureCase.manifest_path("root_workspace", "artifacts"))

    assert_raise Weld.Error, ~r/multiple artifacts/, fn ->
      Manifest.artifact!(manifest, nil)
    end

    assert Manifest.artifact!(manifest, "web_bundle").id == "web_bundle"
  end

  test "loads monolith mode artifacts and canonical git dependency opts" do
    manifest = Manifest.load!(FixtureCase.manifest_path("monolith_bundle", "monolith_bundle"))
    artifact = Manifest.artifact!(manifest, nil)

    assert artifact.mode == :monolith
    assert artifact.monolith_opts == []
    assert manifest.dependencies[:git_dep].requirement == nil
    assert manifest.dependencies[:git_dep].opts[:git] == "https://example.test/git_dep.git"
    assert manifest.dependencies[:git_dep].opts[:branch] == "main"
  end

  test "normalizes monolith-specific test support project ids" do
    repo_root = FixtureCase.copy_fixture("root_workspace")
    manifest_path = Path.join([repo_root, "packaging", "weld", "web_monolith.exs"])

    File.write!(
      manifest_path,
      """
      [
        workspace: [
          root: "../.."
        ],
        classify: [
          tooling: [".", "tooling/test_support"],
          proofs: ["proofs/demo"]
        ],
        publication: [
          internal_only: ["tooling/test_support"]
        ],
        artifacts: [
          web_monolith: [
            mode: :monolith,
            monolith_opts: [
              shared_test_configs: [:apps_web],
              test_support_projects: [:tooling_test_support, "tooling/test_support"]
            ],
            roots: ["apps/web"],
            package: [
              name: "root_web_monolith",
              otp_app: :root_web_monolith,
              version: "0.1.0"
            ],
            output: [
              docs: ["README.md"]
            ]
          ]
        ]
      ]
      """
    )

    manifest = Manifest.load!(manifest_path)
    artifact = Manifest.artifact!(manifest, nil)

    assert artifact.monolith_opts[:shared_test_configs] == ["apps_web"]

    assert artifact.monolith_opts[:test_support_projects] == [
             "tooling/test_support",
             "tooling_test_support"
           ]
  end
end
