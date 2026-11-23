defmodule Weld.VerifierTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  @moduletag :integration

  @tag ci_build: "package"
  test "verifies a welded artifact end to end" do
    repo = FixtureCase.copy_fixture("library_bundle")
    manifest = Path.join(repo, "packaging/weld/fixture_bundle.exs")
    legacy_cache = Path.join(repo, "dist/hex/.weld-build/fixture_bundle")
    File.mkdir_p!(legacy_cache)

    result = Weld.verify!(manifest)

    refute File.exists?(legacy_cache)
    assert [_ | _] = Path.wildcard(Path.join(repo, "_build/weld/*/*/build/dev/lib/*/ebin"))

    assert File.regular?(result.lockfile_path)
    assert File.regular?(result.tarball_path)

    assert Enum.any?(
             result.verification_results,
             &(&1.task == "compile --warnings-as-errors --no-compile-deps")
           )

    assert Enum.any?(result.verification_results, &(&1.task == "hex.publish --dry-run --yes"))
    assert Enum.any?(result.verification_results, &(&1.task == "smoke"))
  end

  @tag ci_build: "runtime"
  test "starts the generated welded application before running package tests" do
    result =
      Weld.verify!(FixtureCase.copied_manifest_path("composite_runtime", "composite_bundle"))

    assert File.regular?(result.tarball_path)
    assert Enum.any?(result.verification_results, &(&1.task == "test"))
  end

  @tag ci_build: "monolith"
  test "verifies monolith artifacts with the real monolith gate and records test counts" do
    result = Weld.verify!(FixtureCase.copied_manifest_path("monolith_bundle", "monolith_bundle"))

    assert File.regular?(result.lockfile_path)
    assert File.regular?(result.tarball_path)

    {:ok, outer} = :erl_tar.extract(String.to_charlist(result.tarball_path), [:memory])
    {~c"contents.tar.gz", contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
    {:ok, files} = :erl_tar.extract({:binary, contents}, [:compressed, :memory])
    refute List.keymember?(files, ~c"projection.lock.json", 0)

    assert Enum.any?(result.verification_results, &(&1.task == "selected_tests_baseline"))
    assert Enum.any?(result.verification_results, &(&1.task == "deps.get"))
    assert Enum.any?(result.verification_results, &(&1.task == "compile --warnings-as-errors"))
    assert Enum.any?(result.verification_results, &(&1.task == "docs --warnings-as-errors"))
    assert Enum.any?(result.verification_results, &(&1.task == "hex.build"))

    assert Enum.any?(result.verification_results, fn result ->
             result.task == "hex.publish --dry-run --yes" and result.status == :ok
           end)

    baseline = Enum.find(result.verification_results, &(&1.task == "selected_tests_baseline"))
    monolith_test = Enum.find(result.verification_results, &(&1.task == "test"))

    assert baseline.test_count == 2
    assert monolith_test.test_count == 2
    refute Enum.any?(result.verification_results, &(&1.task == "smoke"))
  end
end
