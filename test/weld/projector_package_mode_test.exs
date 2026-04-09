defmodule Weld.ProjectorPackageModeTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "package mode verification succeeds when selected projects need projected config" do
    manifest_path =
      FixtureCase.copied_manifest_path("package_bootstrap_bundle", "package_bootstrap_bundle")

    result = Weld.verify!(manifest_path)

    assert File.regular?(Path.join(result.build_path, "config/config.exs"))

    application =
      File.read!(Path.join(result.build_path, "lib/package_bootstrap_bundle/application.ex"))

    assert application =~ "bootstrap_workspace_app_env!()"
    assert application =~ "@bootstrapped_apps [:fixture_bootstrap]"
  end

  test "package mode projects root ecto repo discovery and repo priv overlays" do
    manifest_path = FixtureCase.copied_manifest_path("package_repo_bundle", "package_repo_bundle")
    result = Weld.project!(manifest_path)

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

  test "projecting a monolith artifact removes stale package-mode output" do
    repo_root = FixtureCase.copy_fixture("monolith_bundle")
    manifest_path = Path.join(repo_root, "packaging/weld/monolith_bundle.exs")
    stale_path = Path.join(repo_root, "dist/hex/monolith_bundle/STALE")

    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale")

    result = Weld.project!(manifest_path)

    refute File.exists?(stale_path)
    assert result.build_path == Path.join(repo_root, "dist/monolith/monolith_bundle")
  end
end
