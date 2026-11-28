defmodule Weld.ProjectorPackageModeTest do
  use ExUnit.Case, async: true

  alias Weld.FixtureCase

  test "package mode renders the same professional HexDocs metadata contract" do
    result =
      Weld.Commands.project!(FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle"))

    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))

    assert mixfile =~ "source_url: \"https://example.test/fixture_bundle\""
    assert mixfile =~ "before_closing_body_tag"
    assert mixfile =~ "mermaid@11.12.2"
    assert mixfile =~ "exdoc:loaded"
    refute mixfile =~ "DOMContentLoaded"
    assert mixfile =~ "source_ref: \"v0.1.0\""
    assert mixfile =~ "{\"README.md\", [title: \"Overview\"]}"

    assert mixfile =~
             "{\"Start Here\", [\"README.md\", \"guides/getting_started.md\"]}"

    assert mixfile =~
             "{\"Reference\", [\"guides/architecture.md\", \"CHANGELOG.md\"]}"
  end

  test "package mode renders declared dev_deps into the generated mixfile" do
    root = FixtureCase.copy_fixture("library_bundle")
    manifest_path = Path.join(root, "packaging/weld/dev_deps_bundle.exs")

    File.write!(
      manifest_path,
      String.replace(
        File.read!(Path.join(root, "packaging/weld/fixture_bundle.exs")),
        ~s(links: %{"Source" => "https://example.test/fixture_bundle"}),
        ~s(links: %{"Source" => "https://example.test/fixture_bundle"},\n        dev_deps: [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}, {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}])
      )
    )

    result = Weld.Commands.project!(manifest_path)
    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))

    assert mixfile =~ "{:credo, \"~> 1.7\", [only: [:dev, :test], runtime: false]}"
    assert mixfile =~ "{:dialyxir, \"~> 1.4\", [only: [:dev, :test], runtime: false]}"
  end

  @tag integration: true, ci_build: "package_config"
  test "package mode verification succeeds when selected projects need projected config" do
    manifest_path =
      FixtureCase.copied_manifest_path("package_bootstrap_bundle", "package_bootstrap_bundle")

    result = Weld.Commands.verify!(manifest_path)

    assert File.regular?(Path.join(result.build_path, "config/config.exs"))

    application =
      File.read!(Path.join(result.build_path, "lib/package_bootstrap_bundle/application.ex"))

    assert application =~ "bootstrap_workspace_app_env!()"
    assert application =~ "@bootstrapped_apps [:fixture_bootstrap]"
    assert application =~ "@moduledoc false"
  end

  test "package mode projects root ecto repo discovery and repo priv overlays" do
    manifest_path = FixtureCase.copied_manifest_path("package_repo_bundle", "package_repo_bundle")
    result = Weld.Commands.project!(manifest_path)

    config = File.read!(Path.join(result.build_path, "config/config.exs"))

    store_config =
      File.read!(Path.join(result.build_path, "config/sources/core_store/config.exs"))

    dev_config = File.read!(Path.join(result.build_path, "config/dev.exs"))
    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))

    assert config =~ "import_config \"sources/core_store/config.exs\""
    assert config =~ "config :package_repo_bundle,"
    assert config =~ "ecto_repos: [Fixture.Store.Repo]"
    assert store_config =~ "database: \"fixture_store_test\""
    assert store_config =~ "username: \"postgres\""
    assert File.regular?(Path.join(result.build_path, ".formatter.exs"))
    assert ".formatter.exs" in result.package_files

    assert dev_config =~
             "config :fixture_store, Fixture.Store.Repo,\n  priv: Path.expand(\"../components/core/store/priv/repo\", __DIR__)"

    assert mixfile =~ "\"config\""
    assert mixfile =~ "\".formatter.exs\""
    assert mixfile =~ "build_path: \"_build\""
  end

  test "projecting a monolith artifact preserves historical package-mode output" do
    repo_root = FixtureCase.copy_fixture("monolith_bundle")
    manifest_path = Path.join(repo_root, "packaging/weld/monolith_bundle.exs")
    stale_path = Path.join(repo_root, "dist/hex/monolith_bundle/STALE")

    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale")

    result = Weld.Commands.project!(manifest_path)

    assert File.exists?(stale_path)
    assert result.build_path == Path.join(repo_root, ".weld/v2/full/monolith_bundle/project")
  end
end
