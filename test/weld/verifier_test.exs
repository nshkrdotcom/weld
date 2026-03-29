defmodule Weld.VerifierTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "verifies a welded artifact end to end" do
    result = Weld.verify!(FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle"))

    assert File.regular?(result.lockfile_path)
    assert File.regular?(result.tarball_path)

    assert Enum.any?(result.verification_results, &(&1.task == "compile --warnings-as-errors"))
    assert Enum.any?(result.verification_results, &(&1.task == "hex.publish --dry-run --yes"))
    assert Enum.any?(result.verification_results, &(&1.task == "smoke"))
  end

  test "starts the generated welded application before running package tests" do
    result =
      Weld.verify!(FixtureCase.copied_manifest_path("composite_runtime", "composite_bundle"))

    assert File.regular?(result.tarball_path)
    assert Enum.any?(result.verification_results, &(&1.task == "test"))
  end
end
