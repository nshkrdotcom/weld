defmodule Weld.VerifierTest do
  use ExUnit.Case, async: true

  alias Weld.FixtureCase

  @moduletag :integration

  @tag ci_build: "runtime"
  test "starts the generated welded application and excludes manifest dev_deps from Hex metadata" do
    manifest = FixtureCase.copied_manifest_path("composite_runtime", "composite_bundle")

    File.write!(
      manifest,
      String.replace(
        File.read!(manifest),
        ~s(description: "Composite runtime fixture"),
        ~s(description: "Composite runtime fixture",\n        dev_deps: [{:nimble_options, "~> 1.1", only: [:dev, :test], runtime: false}])
      )
    )

    result = Weld.Commands.verify!(manifest)

    assert File.regular?(result.tarball_path)
    assert Enum.any?(result.verification_results, &(&1.task == "test --warnings-as-errors"))

    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))
    assert mixfile =~ "{:nimble_options, \"~> 1.1\", [only: [:dev, :test], runtime: false]}"
    refute Map.has_key?(result.package_metadata["requirements"] || %{}, "nimble_options")
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
    refute File.exists?(Path.join(prepared.project_path, "doc"))
    refute File.exists?(Path.join(prepared.project_path, "html"))
  end
end
