defmodule Weld.DependencySourcesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Weld.DependencySources
  alias Weld.FixtureCase

  test "verifies canonical helper, manifest shape, sources, and publish mode" do
    repo_root = valid_dependency_repo!()

    assert {:ok, report} = DependencySources.verify(repo_root, publish?: true)
    assert report.helper.status == :ok
    assert report.config.status == :ok
    assert report.publish.status == :ok
    assert report.deps[:shared_core].sources == [:path, :github, :hex]
  end

  test "reports helper drift, manifest shape errors, source errors, and publish blockers" do
    repo_root = FixtureCase.unique_tmp_dir("weld_bad_dependency_sources")
    File.mkdir_p!(Path.join(repo_root, "build_support"))
    File.write!(Path.join(repo_root, "build_support/dependency_sources.exs"), "# drift\n")

    File.write!(
      Path.join(repo_root, "build_support/dependency_sources.config.exs"),
      """
      %{
        deps: %{
          bad_dep: %{
            default_order: [:path, :github],
            publish_order: [:github]
          }
        }
      }
      """
    )

    assert {:error, report} = DependencySources.verify(repo_root, publish?: true)

    assert violation_codes(report) == [
             :github_source_missing,
             :helper_drift,
             :path_source_missing,
             :publish_requires_hex_source
           ]
  end

  test "treats empty or non-string path lists as unavailable sources" do
    repo_root = FixtureCase.unique_tmp_dir("weld_bad_path_sources")
    build_support = Path.join(repo_root, "build_support")
    File.mkdir_p!(build_support)

    File.write!(
      Path.join(build_support, "dependency_sources.exs"),
      DependencySources.canonical_helper()
    )

    File.write!(
      Path.join(build_support, "dependency_sources.config.exs"),
      """
      %{
        deps: %{
          empty_path: %{path: [], default_order: [:path], publish_order: []},
          bad_path: %{path: ["../valid", :not_a_path], default_order: [:path], publish_order: []}
        }
      }
      """
    )

    assert {:error, report} = DependencySources.verify(repo_root)

    assert violation_codes(report) == [
             :path_source_missing,
             :path_source_missing
           ]
  end

  test "mix weld.dependency_sources.verify emits JSON for valid repos" do
    repo_root = valid_dependency_repo!()

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          Mix.Task.rerun("weld.dependency_sources.verify", ["--format", "json", "--publish"])
        end)
      end)

    assert %{"ok" => true, "repo_root" => ^repo_root} = Jason.decode!(output)
  end

  defp valid_dependency_repo! do
    repo_root = FixtureCase.unique_tmp_dir("weld_dependency_sources")
    build_support = Path.join(repo_root, "build_support")
    File.mkdir_p!(build_support)
    File.mkdir_p!(Path.join(repo_root, "../shared_core"))

    File.write!(
      Path.join(build_support, "dependency_sources.exs"),
      DependencySources.canonical_helper()
    )

    File.write!(
      Path.join(build_support, "dependency_sources.config.exs"),
      """
      %{
        deps: %{
          shared_core: %{
            path: ["../shared_core"],
            github: %{repo: "nshkrdotcom/shared_core", branch: "main"},
            hex: "~> 0.1.0",
            default_order: [:path, :github, :hex],
            publish_order: [:hex]
          }
        }
      }
      """
    )

    File.write!(Path.join(repo_root, ".gitignore"), ".dependency_sources.local.exs\n")
    repo_root
  end

  defp violation_codes(report) do
    report.violations
    |> Enum.map(& &1.code)
    |> Enum.sort()
  end
end
