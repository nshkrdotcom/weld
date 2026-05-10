defmodule Weld.AgentsVerifierTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Weld.AgentsVerifier
  alias Weld.FixtureCase

  test "verifies root and nested AGENTS dependency and runtime env guidance" do
    repo_root = FixtureCase.unique_tmp_dir("weld_agents")
    write_agents!(repo_root)
    nested_dir = Path.join([repo_root, "apps", "web"])
    File.mkdir_p!(nested_dir)
    write_agents!(nested_dir)

    assert {:ok, report} = AgentsVerifier.verify(repo_root)

    assert Enum.map(report.files, &Path.relative_to(&1.path, repo_root)) == [
             "AGENTS.md",
             "apps/web/AGENTS.md"
           ]
  end

  test "reports missing required guidance" do
    repo_root = FixtureCase.unique_tmp_dir("weld_agents_missing")
    File.write!(Path.join(repo_root, "AGENTS.md"), "# Agents\n")

    assert {:error, report} = AgentsVerifier.verify(repo_root)

    assert Enum.map(report.violations, & &1.code) == [
             :missing_dependency_sources_guidance,
             :missing_local_override_guidance,
             :missing_no_env_dependency_selection_guidance,
             :missing_runtime_env_guidance,
             :missing_weld_guidance
           ]
  end

  test "mix weld.agents.verify emits JSON for valid repos" do
    repo_root = FixtureCase.unique_tmp_dir("weld_agents_task")
    write_agents!(repo_root)

    output =
      capture_io(fn ->
        File.cd!(repo_root, fn ->
          Mix.Task.rerun("weld.agents.verify", ["--format", "json"])
        end)
      end)

    assert %{"ok" => true, "repo_root" => ^repo_root} = Jason.decode!(output)
  end

  defp write_agents!(dir) do
    File.write!(Path.join(dir, "AGENTS.md"), """
    # Agents

    Dependency source selection is handled by build_support/dependency_sources.exs
    and build_support/dependency_sources.config.exs. Local overrides use
    .dependency_sources.local.exs. Dependency source selection must not use
    environment variables. Weld maintains and verifies helper drift, manifests,
    clone checks, publish checks, and publish order. Runtime application code
    under lib/** must not call direct OS env APIs. Runtime env reads belong in
    config/runtime.exs or a Config.Provider.
    """)
  end
end
