defmodule Weld.ConfigGeneratorTest do
  use ExUnit.Case, async: false

  alias Weld.Config.Generator
  alias Weld.FixtureCase
  alias Weld.Shell.{Materializer, Snapshot}
  alias Weld.Workspace.Project

  test "does not emit repo priv overlays when the merged repo path is the default priv/repo" do
    build_path =
      FixtureCase.unique_tmp_dir("weld_config_generator")

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

    generate!([], build_path, repo_infos, migration_layout)

    refute File.read!(Path.join(build_path, "config/dev.exs")) =~ "demo_store_postgres"
    refute File.read!(Path.join(build_path, "config/test.exs")) =~ "demo_store_postgres"
    refute File.read!(Path.join(build_path, "config/prod.exs")) =~ "demo_store_postgres"
  end

  test "bootstrapped_apps only includes projects that stage runtime bootstrap sources" do
    build_path =
      FixtureCase.unique_tmp_dir("weld_config_generator")

    project_root =
      FixtureCase.unique_tmp_dir("weld_config_project")

    support_root =
      FixtureCase.unique_tmp_dir("weld_config_support")

    File.mkdir_p!(Path.join(project_root, "config"))

    File.write!(
      Path.join(project_root, "config/config.exs"),
      """
      import Config

      config :demo_project, :source, :project
      """
    )

    migration_layout = %{case: :single, repo_count: 0, repo_paths: %{}}

    result =
      generate!(
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

  test "staged static config retains selected project app config" do
    build_path =
      FixtureCase.unique_tmp_dir("weld_config_generator")

    project_root =
      FixtureCase.unique_tmp_dir("weld_config_project")

    File.mkdir_p!(Path.join(project_root, "config"))

    File.write!(
      Path.join(project_root, "config/config.exs"),
      """
      import Config

      config :demo_project, Demo.Repo, database: "demo_test"
      """
    )

    migration_layout = %{case: :single, repo_count: 0, repo_paths: %{}}

    generate!(
      [project("apps/demo_project", project_root, :demo_project)],
      build_path,
      [],
      migration_layout
    )

    staged_config =
      File.read!(Path.join(build_path, "config/sources/apps_demo_project/config.exs"))

    assert staged_config =~ "config :demo_project, Demo.Repo, database: \"demo_test\""
  end

  test "generated config/runtime.exs evaluates multiple components via Config.Reader with isolated bindings and accurate __DIR__" do
    build_path = FixtureCase.unique_tmp_dir("weld_runtime_config")
    app_a = FixtureCase.unique_tmp_dir("weld_runtime_app_a")
    app_b = FixtureCase.unique_tmp_dir("weld_runtime_app_b")

    File.mkdir_p!(Path.join(app_a, "config"))
    File.mkdir_p!(Path.join(app_b, "config"))

    File.write!(
      Path.join(app_a, "config/runtime.exs"),
      """
      import Config

      shared_var = :from_a
      config :app_a, value: shared_var, dir: __DIR__
      """
    )

    File.write!(
      Path.join(app_b, "config/runtime.exs"),
      """
      import Config

      config :app_b,
        dir: __DIR__,
        leaked?: binding()[:shared_var]
      """
    )

    migration_layout = %{case: :single, repo_count: 0, repo_paths: %{}}

    generate!(
      [
        project("apps/a", app_a, :app_a),
        project("apps/b", app_b, :app_b)
      ],
      build_path,
      [],
      migration_layout
    )

    runtime_path = Path.join(build_path, "config/runtime.exs")
    runtime_source = File.read!(runtime_path)
    refute runtime_source =~ "import_config"

    loaded = Config.Reader.read!(runtime_path, env: :test, target: :host)

    assert loaded[:app_a][:value] == :from_a
    assert loaded[:app_a][:dir] == Path.join(build_path, "config/runtime_sources/apps_a")
    assert loaded[:app_b][:dir] == Path.join(build_path, "config/runtime_sources/apps_b")
    assert loaded[:app_b][:leaked?] == nil
  end

  defp generate!(projects, build_path, repo_infos, migration_layout, opts \\ []) do
    projects =
      Enum.map(projects, fn project ->
        Map.put(project, :facts, Snapshot.observe!(project.abs_path))
      end)

    result = Generator.plan!(projects, repo_infos, migration_layout, opts)
    nodes = Enum.reduce(projects, %{}, &Map.merge(&2, &1.facts.nodes))
    facts = %{root: build_path, nodes: nodes}

    Materializer.execute!(
      %{full: result.operations, empty_dirs: []},
      facts,
      build_path,
      :full
    )

    result
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
