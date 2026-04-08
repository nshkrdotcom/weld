defmodule Weld.ConfigGeneratorTest do
  use ExUnit.Case, async: false

  alias Weld.Config.Generator

  test "does not emit repo priv overlays when the merged repo path is the default priv/repo" do
    build_path =
      Path.join(
        System.tmp_dir!(),
        "weld_config_generator_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(build_path)
    File.mkdir_p!(build_path)

    repo_infos = [
      %{
        project_id: "core_store_postgres",
        module: Demo.StorePostgres.Repo,
        otp_app: :demo_store_postgres
      }
    ]

    migration_layout = %{
      case: :single,
      repo_count: 1,
      repo_paths: %{"core_store_postgres" => "priv/repo"}
    }

    Generator.generate!([], build_path, repo_infos, migration_layout)

    refute File.read!(Path.join(build_path, "config/dev.exs")) =~ "demo_store_postgres"
    refute File.read!(Path.join(build_path, "config/test.exs")) =~ "demo_store_postgres"
    refute File.read!(Path.join(build_path, "config/prod.exs")) =~ "demo_store_postgres"
  end
end
