defmodule Weld.EcosystemReportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Weld.DependencySources
  alias Weld.EcosystemReport
  alias Weld.FixtureCase

  test "builds dependency graph, publish order, clean-clone, and publish-readiness reports" do
    root = FixtureCase.unique_tmp_dir("weld_ecosystem")
    shared = write_repo!(root, "shared_core", %{})

    app =
      write_repo!(root, "app", %{
        shared_core: %{
          path: ["../shared_core"],
          github: %{repo: "nshkrdotcom/shared_core", branch: "main"},
          hex: "~> 0.1.0",
          default_order: [:path, :github, :hex],
          publish_order: [:hex]
        }
      })

    repos_path = Path.join(root, "repos.exs")

    File.write!(
      repos_path,
      inspect([%{name: "shared_core", path: shared}, %{name: "app", path: app}])
    )

    assert {:ok, report} = EcosystemReport.build(repos_path)
    assert report.graph.nodes == ["app", "shared_core"]
    assert report.graph.edges == [%{from: "app", to: "shared_core", source: :hex}]
    assert report.publish_order == ["shared_core", "app"]
    assert report.clean_clone["app"].helper? == true
    assert report.publish_readiness["app"].ready? == true
  end

  test "mix weld.ecosystem.report emits JSON" do
    root = FixtureCase.unique_tmp_dir("weld_ecosystem_task")
    repo = write_repo!(root, "shared_core", %{})
    repos_path = Path.join(root, "repos.exs")
    File.write!(repos_path, inspect([%{name: "shared_core", path: repo}]))

    output =
      capture_io(fn ->
        Mix.Task.rerun("weld.ecosystem.report", [repos_path, "--format", "json"])
      end)

    assert %{"ok" => true, "graph" => %{"nodes" => ["shared_core"]}} = Jason.decode!(output)
  end

  defp write_repo!(root, name, deps) do
    repo_root = Path.join(root, name)
    build_support = Path.join(repo_root, "build_support")
    File.mkdir_p!(build_support)

    File.write!(
      Path.join(repo_root, "mix.exs"),
      "defmodule #{Macro.camelize(name)}.MixProject do\nend\n"
    )

    File.write!(Path.join(repo_root, ".gitignore"), ".dependency_sources.local.exs\n")

    File.write!(
      Path.join(build_support, "dependency_sources.exs"),
      DependencySources.canonical_helper()
    )

    File.write!(
      Path.join(build_support, "dependency_sources.config.exs"),
      "%{deps: #{inspect(deps, pretty: true)}}\n"
    )

    File.write!(Path.join(repo_root, "AGENTS.md"), "placeholder\n")
    repo_root
  end
end
