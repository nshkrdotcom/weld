defmodule Weld.VerifierTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "verifies a welded artifact end to end" do
    result = Weld.verify!(FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle"))

    assert File.regular?(result.lockfile_path)
    assert File.regular?(result.tarball_path)

    assert Enum.any?(
             result.verification_results,
             &(&1.task == "compile --warnings-as-errors --no-compile-deps")
           )

    assert Enum.any?(result.verification_results, &(&1.task == "hex.publish --dry-run --yes"))
    assert Enum.any?(result.verification_results, &(&1.task == "smoke"))
  end

  test "starts the generated welded application before running package tests" do
    result =
      Weld.verify!(FixtureCase.copied_manifest_path("composite_runtime", "composite_bundle"))

    assert File.regular?(result.tarball_path)
    assert Enum.any?(result.verification_results, &(&1.task == "test"))
  end

  test "verifies monolith artifacts with the real monolith gate and records test counts" do
    result = Weld.verify!(FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle"))

    assert File.regular?(result.lockfile_path)
    assert File.regular?(result.tarball_path)

    assert Enum.any?(result.verification_results, &(&1.task == "selected_tests_baseline"))
    assert Enum.any?(result.verification_results, &(&1.task == "deps.get"))
    assert Enum.any?(result.verification_results, &(&1.task == "compile --warnings-as-errors"))
    assert Enum.any?(result.verification_results, &(&1.task == "docs --warnings-as-errors"))
    assert Enum.any?(result.verification_results, &(&1.task == "hex.build"))

    baseline = Enum.find(result.verification_results, &(&1.task == "selected_tests_baseline"))
    monolith_test = Enum.find(result.verification_results, &(&1.task == "test"))

    assert baseline.test_count == 2
    assert monolith_test.test_count == 2
    refute Enum.any?(result.verification_results, &(&1.task == "smoke"))
  end
end
