defmodule Weld.AffectedTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "maps a changed dependency project to its reverse dependents" do
    repo_root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(repo_root)

    contracts_file =
      Path.join([repo_root, "core", "contracts", "lib", "weld_fixture", "contracts.ex"])

    File.write!(contracts_file, File.read!(contracts_file) <> "\n# changed\n")
    FixtureCase.commit_all!(repo_root, "change contracts")

    manifest_path = Path.join([repo_root, "packaging", "weld", "fixture_bundle.exs"])

    result =
      Weld.Commands.affected!(
        manifest_path,
        artifact: "fixture_bundle",
        task: "verify",
        base: "HEAD~1",
        head: "HEAD"
      )

    assert result.changed_files == ["core/contracts/lib/weld_fixture/contracts.ex"]
    assert result.direct_projects == ["core/contracts"]
    assert result.affected_projects == ["core/contracts", "runtime/local"]
  end

  test "unsupported portable metadata produces an affected unknown result" do
    root = FixtureCase.copy_fixture("library_bundle")
    mixfile = Path.join(root, "runtime/local/mix.exs")

    File.write!(
      mixfile,
      String.replace(
        File.read!(mixfile),
        "  def project do",
        "  def application, do: [env: [ratio: 0.5]]\n\n  def project do"
      )
    )

    FixtureCase.init_git!(root)
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    plan = manifest |> Weld.Plan.build!() |> Weld.Plan.ensure_valid!()
    assert plan.workspace.projects["runtime/local"].application_by_env.dev[:env] == [ratio: 0.5]

    assert_raise Weld.Error, ~r/unsupported portable metadata value/, fn ->
      Weld.Plan.Inventory.portable(plan)
    end

    report =
      Weld.Affected.compare!(manifest,
        artifact: "fixture_bundle",
        base: "HEAD",
        head: "HEAD",
        task: "package"
      )

    assert report.affected?
    assert report.unknown?
    assert report.changed_files == []
    assert report.reasons != []
    assert Enum.all?(report.reasons, &(&1 == "unsupported portable metadata value"))
  end
end
