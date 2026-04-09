defmodule Weld.ConfigGeneratorTest do
  use ExUnit.Case, async: false

  alias Weld.Config.Generator
  alias Weld.Workspace.Project

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

  test "bootstrapped_apps only includes projects that stage runtime bootstrap sources" do
    build_path =
      Path.join(
        System.tmp_dir!(),
        "weld_config_generator_#{System.unique_integer([:positive, :monotonic])}"
      )

    project_root =
      Path.join(
        System.tmp_dir!(),
        "weld_config_project_#{System.unique_integer([:positive, :monotonic])}"
      )

    support_root =
      Path.join(
        System.tmp_dir!(),
        "weld_config_support_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(build_path)
    File.rm_rf!(project_root)
    File.rm_rf!(support_root)
    File.mkdir_p!(Path.join(project_root, "config"))
    File.mkdir_p!(support_root)

    File.write!(
      Path.join(project_root, "config/config.exs"),
      """
      import Config

      config :demo_project, :source, :project
      """
    )

    migration_layout = %{case: :single, repo_count: 0, repo_paths: %{}}

    result =
      Generator.generate!(
        [
          project("apps/demo_project", project_root, :demo_project),
          project("tooling/test_support", support_root, :demo_support)
        ],
        build_path,
        [],
        migration_layout
      )

    assert result.bootstrapped_apps == [:demo_project]
  end

  defp project(id, abs_path, app) do
    %Project{
      id: id,
      abs_path: abs_path,
      app: app,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [],
      application: %{extra_applications: [], included_applications: [], registered: [], mod: nil},
      elixirc_paths: ["lib"],
      erlc_paths: [],
      copy_dirs: [],
      classification: :runtime,
      publication_role: :default
    }
  end
end
