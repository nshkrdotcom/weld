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
      Weld.affected!(
        manifest_path,
        artifact: "fixture_bundle",
        task: "verify.all",
        base: "HEAD~1",
        head: "HEAD"
      )

    assert result.changed_files == ["core/contracts/lib/weld_fixture/contracts.ex"]
    assert result.direct_projects == ["core/contracts"]
    assert result.affected_projects == ["core/contracts", "runtime/local"]
  end
end
