defmodule Weld.CredoNoRuntimeOsEnvTest do
  use ExUnit.Case, async: true

  alias Weld.Credo.Check.NoRuntimeOsEnv

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "flags direct OS env calls under lib" do
    source_file =
      Credo.SourceFile.parse(
        """
        defmodule Fixture.Cli do
          def read do
            System.get_env("TOKEN")
            System.fetch_env("TOKEN")
            System.fetch_env!("TOKEN")
            System.put_env("TOKEN", "value")
            System.delete_env("TOKEN")
          end
        end
        """,
        "lib/fixture/cli.ex"
      )

    issues = NoRuntimeOsEnv.run(source_file, [])

    assert Enum.map(issues, & &1.trigger) == [
             "System.get_env",
             "System.fetch_env",
             "System.fetch_env!",
             "System.put_env",
             "System.delete_env"
           ]
  end

  test "ignores env calls outside runtime lib files" do
    config_file =
      Credo.SourceFile.parse(
        """
        import Config
        config :fixture, token: System.fetch_env!("TOKEN")
        """,
        "config/runtime.exs"
      )

    test_file =
      Credo.SourceFile.parse(
        """
        defmodule FixtureTest do
          use ExUnit.Case

          test "compat" do
            System.put_env("TOKEN", "value")
          end
        end
        """,
        "test/fixture_test.exs"
      )

    assert NoRuntimeOsEnv.run(config_file, []) == []
    assert NoRuntimeOsEnv.run(test_file, []) == []
  end
end
