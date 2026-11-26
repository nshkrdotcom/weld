defmodule Weld.ProjectorMonolithTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "projects a monolith artifact into a real root project tree" do
    result =
      Weld.Commands.project!(
        FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle")
      )

    assert result.build_path =~ "/.weld/v2/full/monolith_bundle/project"
    assert File.regular?(Path.join(result.build_path, "mix.exs"))
    assert File.regular?(Path.join(result.build_path, "projection.lock.json"))
    refute "projection.lock.json" in result.package_files
    assert File.regular?(Path.join(result.build_path, "lib/fixture/store.ex"))
    assert File.regular?(Path.join(result.build_path, "lib/fixture/api.ex"))
    assert File.regular?(Path.join(result.build_path, "config/config.exs"))
    assert File.regular?(Path.join(result.build_path, "config/test.exs"))
    assert File.regular?(Path.join(result.build_path, "config/sources/core_store/config.exs"))
    assert File.regular?(Path.join(result.build_path, "config/sources/runtime_api/config.exs"))
    assert File.regular?(Path.join(result.build_path, ".formatter.exs"))
    assert File.regular?(Path.join(result.build_path, "CHANGELOG.md"))
    assert File.regular?(Path.join(result.build_path, "assets/monolith_bundle.svg"))
    assert File.regular?(Path.join(result.build_path, "test/test_helper.exs"))
    assert File.regular?(Path.join(result.build_path, "test/core_store/fixture/store_test.exs"))
    assert File.regular?(Path.join(result.build_path, "test/runtime_api/fixture/api_test.exs"))
    assert File.regular?(Path.join(result.build_path, "test/support/core_store/store_case.exs"))

    refute File.exists?(Path.join(result.build_path, "test/runtime_api/dormant/dormant_test.exs"))

    assert File.read!(Path.join(result.build_path, "lib/monolith_bundle/application.ex")) =~
             "@moduledoc false"

    assert File.regular?(
             Path.join(result.build_path, "test/support/weld_helpers/core_store_test_helper.exs")
           )

    assert File.regular?(
             Path.join(result.build_path, "priv/repo/migrations/20260101000000_create_store.exs")
           )

    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))
    assert ".formatter.exs" in result.package_files
    assert "CHANGELOG.md" in result.package_files
    assert "assets/monolith_bundle.svg" in result.package_files
    assert "guides/release.md" in result.package_files
    refute "guides" in result.package_files
    assert mixfile =~ "\".formatter.exs\""
    assert mixfile =~ "\"CHANGELOG.md\""
    assert mixfile =~ "\"assets/monolith_bundle.svg\""
    assert mixfile =~ "build_path: \"_build\""
    assert mixfile =~ "logo: \"assets/monolith_bundle.svg\""
    assert mixfile =~ "homepage_url: \"https://example.test/monolith_bundle\""
    assert mixfile =~ "source_url: \"https://example.test/monolith_bundle\""
    assert mixfile =~ "source_ref: \"v0.1.0\""
    assert mixfile =~ "assets: %{\"assets\" => \"assets\"}"
    assert mixfile =~ "{\"README.md\", [title: \"Overview\"]}"
    assert mixfile =~ "{\"CHANGELOG.md\", [title: \"Changelog\"]}"
    assert mixfile =~ "{\"Start Here\", [\"README.md\"]}"
    assert mixfile =~ "{\"Release\", [\"CHANGELOG.md\"]}"
    refute mixfile =~ "components/"
    refute mixfile =~ ", path:"
  end

  test "uses the configured monolith README at the package root" do
    manifest = FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle")
    root = Path.expand("../..", Path.dirname(manifest))
    readme = "# Fixture API\n\nREADME from the selected app.\n"
    File.write!(Path.join(root, "runtime/api/README.md"), readme)

    contents =
      manifest
      |> File.read!()
      |> String.replace("layout: :flat,", """
      layout: :flat,
      flat: [readme: "runtime/api/README.md"],
      """)
      |> String.replace(~s(docs: ["README.md", "CHANGELOG.md",), ~s(docs: ["CHANGELOG.md",))

    File.write!(manifest, contents)

    for opts <- [[], [live: true]] do
      result = Weld.Commands.project!(manifest, opts)
      assert File.read!(Path.join(result.build_path, "README.md")) == readme
      assert "README.md" in result.package_files

      assert File.read!(Path.join(result.build_path, "mix.exs")) =~
               ~s({"README.md", [title: "Overview"]})
    end
  end

  test "rejects colliding private assets in a monolith" do
    manifest = FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle")
    root = Path.expand("../..", Path.dirname(manifest))

    for component <- ["core/store", "runtime/api"] do
      path = Path.join([root, component, "priv", "shared.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, component)
    end

    assert_raise Weld.Error, ~r/priv path collision at priv\/shared.txt/, fn ->
      Weld.Commands.project!(manifest)
    end
  end

  @tag integration: true, ci_build: "monolith_tests"
  test "the generated monolith compiles and runs real package tests" do
    result =
      Weld.Commands.project!(
        FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle")
      )

    {output, status} =
      System.cmd("mix", ["test"],
        cd: result.build_path,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert status == 0, output
    refute output =~ "configured but not available", output
    assert output =~ ~r/(?:2 tests, 0 failures|Result: 2 passed)/

    {format_output, format_status} =
      System.cmd("mix", ["format", "--check-formatted"],
        cd: result.build_path,
        stderr_to_stdout: true
      )

    assert format_status == 0, format_output
  end

  @tag integration: true, ci_build: "monolith_tests", timeout: 600_000
  test "the live monolith compiles and runs its selected test suites" do
    manifest = FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle")
    result = Weld.Commands.project!(manifest, live: true)

    {output, status} =
      System.cmd("mix", ["test"],
        cd: result.build_path,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_PATH", nil},
          {"MIX_BUILD_ROOT", nil},
          {"MIX_DEPS_PATH", nil}
        ]
      )

    assert status == 0, output
    refute output =~ "configured but not available", output
    assert output =~ ~r/(?:2 tests, 0 failures|Result: 2 passed)/
  end

  test "allows explicit non-selected monolith test support projects" do
    manifest_path = explicit_test_support_manifest_path!(["tooling/test_support"])
    result = Weld.Commands.project!(manifest_path)

    assert result.test_support_projects == ["tooling/test_support"]

    assert File.regular?(
             Path.join(
               result.build_path,
               "test/support/weld_projects/tooling_test_support/lib/root_workspace/test_support.ex"
             )
           )
  end

  test "fails closed when discovered monolith test support projects are not declared" do
    manifest_path = explicit_test_support_manifest_path!(["apps/core"])

    assert_raise Weld.Error, ~r/test_support_projects/, fn ->
      Weld.Commands.project!(manifest_path)
    end
  end

  defp explicit_test_support_manifest_path!(test_support_projects) do
    repo_root = FixtureCase.copy_fixture("root_workspace")
    manifest_path = Path.join([repo_root, "packaging", "weld", "web_monolith.exs"])

    File.write!(
      manifest_path,
      """
      [
        schema: 2,
        workspace: [
          root: "../..",
      projects: [".", "apps/*", "proofs/*", "tooling/*"]
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
            layout: :flat,
            flat: [
              test_support: #{inspect(test_support_projects)}
            ],
            roots: ["apps/web"],
            package: [
              name: "root_web_monolith",
              otp_app: :root_web_monolith,
              version: "0.1.0",
              description: "Root web monolith"
            ],
            files: [
              docs: ["README.md"]
            ]
          ]
        ]
      ]
      """
    )

    manifest_path
  end
end
