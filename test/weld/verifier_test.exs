defmodule Weld.VerifierTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  @moduletag :integration

  @tag ci_build: "package"
  test "verifies a welded artifact and smoke consumer with isolated Mix settings" do
    repo = FixtureCase.copy_fixture("library_bundle")
    manifest = Path.join(repo, "packaging/weld/fixture_bundle.exs")
    legacy_cache = Path.join(repo, "dist/hex/.weld-build/fixture_bundle")
    File.mkdir_p!(legacy_cache)

    plan = Weld.Plan.build!(manifest)
    poison_mix_overrides!()
    result = Weld.Verifier.verify!(plan)

    assert File.exists?(legacy_cache)
    assert [_ | _] = Path.wildcard(Path.join(repo, ".weld/v2/cache/*/*/build/dev/lib/*/ebin"))

    assert File.regular?(result.lockfile_path)
    assert File.regular?(result.tarball_path)

    assert Enum.any?(
             result.verification_results,
             &(&1.task == "compile --warnings-as-errors --no-compile-deps")
           )

    assert Enum.any?(result.verification_results, &(&1.task == "hex.build" and &1.status == :ok))
    assert Enum.any?(result.verification_results, &(&1.task == "smoke"))
  end

  @tag ci_build: "runtime"
  test "starts the generated welded application before running package tests" do
    result =
      Weld.Commands.verify!(
        FixtureCase.copied_manifest_path("composite_runtime", "composite_bundle")
      )

    assert File.regular?(result.tarball_path)
    assert Enum.any?(result.verification_results, &(&1.task == "test --warnings-as-errors"))
  end

  @tag ci_build: "source_docs_output"
  test "prepares source-project docs at the canonical output despite a native output setting" do
    root = FixtureCase.copy_fixture("source_project")
    manifest = Path.join(root, "build_support/weld.exs")
    mixfile = Path.join(root, "mix.exs")

    File.write!(
      mixfile,
      String.replace(
        File.read!(mixfile),
        "app: :sprout,",
        "app: :sprout, docs: [output: \"html\"],"
      )
    )

    FixtureCase.init_git!(root)
    prepared = Weld.Commands.release_prepare!(manifest)

    assert File.regular?(Path.join(prepared.docs_path, "index.html"))
    assert File.regular?(Path.join(prepared.build_path, "doc/index.html"))
  end

  @tag ci_build: "monolith"
  test "verifies monolith artifacts with the real monolith gate and records test counts" do
    plan =
      "monolith_bundle"
      |> FixtureCase.copied_manifest_path("monolith_bundle")
      |> Weld.Plan.build!()

    poison_mix_overrides!()
    result = Weld.Verifier.verify!(plan)

    assert File.regular?(result.lockfile_path)
    assert File.regular?(result.tarball_path)

    {:ok, outer} = :erl_tar.extract(String.to_charlist(result.tarball_path), [:memory])
    {~c"contents.tar.gz", contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
    {:ok, files} = :erl_tar.extract({:binary, contents}, [:compressed, :memory])
    refute List.keymember?(files, ~c"projection.lock.json", 0)

    assert Enum.any?(result.verification_results, &(&1.task == "selected_tests_baseline"))
    assert Enum.any?(result.verification_results, &(&1.task == "deps.get"))
    assert Enum.any?(result.verification_results, &(&1.task == "compile --warnings-as-errors"))

    assert Enum.any?(
             result.verification_results,
             &(&1.task == "docs --warnings-as-errors --output doc")
           )

    assert Enum.any?(result.verification_results, &(&1.task == "hex.build"))

    assert Enum.any?(result.verification_results, fn result ->
             result.task == "hex.publish --dry-run --yes" and result.status == :skipped and
               result.reason == :artifact_opted_out
           end)

    baseline = Enum.find(result.verification_results, &(&1.task == "selected_tests_baseline"))

    monolith_test =
      Enum.find(result.verification_results, &(&1.task == "test --warnings-as-errors"))

    assert baseline.test_count == 2
    assert monolith_test.test_count == 2
    refute Enum.any?(result.verification_results, &(&1.task == "smoke"))
  end

  defp poison_mix_overrides! do
    for name <- ~w(MIX_EXS MIX_LOCKFILE MIX_TARGET) do
      previous = System.get_env(name)
      System.put_env(name, "unexpected-inherited-setting")

      on_exit(fn -> restore_env(name, previous) end)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
