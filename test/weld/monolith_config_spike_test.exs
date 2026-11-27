defmodule Weld.MonolithConfigSpikeTest do
  use ExUnit.Case, async: true

  alias Weld.FixtureCase

  test "stages package config files and imports shared config from the generated root config" do
    result =
      Weld.Commands.project!(
        FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle")
      )

    config = File.read!(Path.join(result.build_path, "config/config.exs"))
    test_config = File.read!(Path.join(result.build_path, "config/test.exs"))

    staged_core_store_config =
      File.read!(Path.join(result.build_path, "config/sources/core_store/config.exs"))

    staged_runtime_api_config =
      File.read!(Path.join(result.build_path, "config/sources/runtime_api/config.exs"))

    runtime_core_store_config =
      File.read!(Path.join(result.build_path, "config/runtime_sources/core_store/config.exs"))

    application = File.read!(Path.join(result.build_path, "lib/monolith_bundle/application.ex"))
    assert config =~ "import Config"
    assert config =~ "import_config \"sources/core_store/config.exs\""
    assert config =~ "import_config \"sources/runtime_api/config.exs\""
    assert File.regular?(Path.join(result.build_path, "config/sources/core_store/config.exs"))
    assert File.regular?(Path.join(result.build_path, "config/sources/runtime_api/config.exs"))

    assert File.regular?(
             Path.join(result.build_path, "config/runtime_sources/core_store/config.exs")
           )

    assert File.regular?(Path.join(result.build_path, "config/sources/runtime_api/test.exs"))
    assert staged_core_store_config =~ "config :fixture_store, :source, :store"
    assert staged_core_store_config =~ "config :fixture_store, :mode, :test"
    refute staged_runtime_api_config =~ "import_config"
    assert staged_runtime_api_config =~ "config :fixture_api, :source, :api"
    assert runtime_core_store_config =~ "config :fixture_store"

    installed_config =
      Path.join(result.build_path, "priv/weld/config/runtime_sources/runtime_api/config.exs")

    prod_config = Config.Reader.read!(installed_config, env: :prod)
    test_config_values = Config.Reader.read!(installed_config, env: :test)

    assert prod_config[:fixture_api][:source] == :api
    refute prod_config[:fixture_api][:env_only]
    assert test_config_values[:fixture_api][:env_only] == :runtime_api_test

    refute test_config =~ "sources/runtime_api/test.exs"
    refute File.exists?(Path.join(result.build_path, "lib/monolith_bundle/config_bootstrap.ex"))
    assert application =~ "Config.Reader.read_imports!"
    assert application =~ "config/runtime_sources/core_store/config.exs"
  end
end
