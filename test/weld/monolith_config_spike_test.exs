defmodule Weld.MonolithConfigSpikeTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "stages package config files and imports shared config from the generated root config" do
    result = Weld.project!(FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle"))

    config = File.read!(Path.join(result.build_path, "config/config.exs"))
    test_config = File.read!(Path.join(result.build_path, "config/test.exs"))
    staged_runtime_api_config = File.read!(Path.join(result.build_path, "config/sources/runtime_api/config.exs"))
    assert config =~ "import Config"
    assert config =~ "import_config \"sources/core_store/config.exs\""
    assert config =~ "import_config \"sources/runtime_api/config.exs\""
    assert File.regular?(Path.join(result.build_path, "config/sources/core_store/config.exs"))
    assert File.regular?(Path.join(result.build_path, "config/sources/runtime_api/config.exs"))
    assert File.regular?(Path.join(result.build_path, "config/sources/runtime_api/test.exs"))
    refute staged_runtime_api_config =~ "import_config"
    refute test_config =~ "sources/runtime_api/test.exs"
    refute File.exists?(Path.join(result.build_path, "lib/monolith_bundle/config_bootstrap.ex"))
  end
end
