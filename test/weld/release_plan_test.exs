defmodule Weld.ReleasePlanTest do
  use ExUnit.Case, async: false

  alias Weld.{CLI, Error, FixtureCase, Manifest}
  alias Weld.Core.ReleaseOrder, as: ReleasePlan

  test "release plans use resolved dependencies and the manifest root outside Git" do
    manifest = coordinated_manifest!()

    assert {:ok, report} = Weld.run(CLI.parse!("release-plan", ["--manifest", manifest]))
    report = CLI.json_value(report)

    assert Enum.map(report["order"], & &1["package"]) == ["base_package", "extension"]

    assert [
             %{
               "package" => "extension",
               "dependency" => "base_package",
               "requirement" => "~> 0.2.0",
               "dependency_version" => "0.2.1",
               "satisfied" => true
             }
           ] = report["constraints"]
  end

  test "--no-check reports incompatible release versions without failing" do
    manifest = coordinated_manifest!()
    {raw, _binding} = Code.eval_file(manifest)
    raw = put_in(raw, [:artifacts, :base, :package, :version], "0.3.0")
    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))

    assert {:error, [%{message: "unsatisfied release version constraints"}]} =
             Weld.run(CLI.parse!("release-plan", ["--manifest", manifest]))

    assert {:ok, %{constraints: [%{satisfied: false}]}} =
             Weld.run(CLI.parse!("release-plan", ["--manifest", manifest, "--no-check"]))
  end

  test "release ordering rejects cycles instead of reporting an impossible order" do
    artifacts = [%{package: "a"}, %{package: "b"}, %{package: "independent"}]

    constraints = [
      %{package: "a", dependency: "b"},
      %{package: "b", dependency: "a"}
    ]

    assert_raise Error, ~r/cycle/, fn -> ReleasePlan.order(artifacts, constraints) end
  end

  test "release ordering is deterministic across diamonds and independent packages" do
    artifacts = Enum.map(["z", "d", "b", "a", "c"], &%{package: &1})

    constraints = [
      %{package: "d", dependency: "b"},
      %{package: "d", dependency: "c"},
      %{package: "b", dependency: "a"},
      %{package: "c", dependency: "a"}
    ]

    assert Enum.map(ReleasePlan.order(artifacts, constraints), & &1.package) ==
             ["a", "z", "b", "c", "d"]
  end

  test "duplicate publication package identities are rejected" do
    assert_raise Error, ~r/duplicate.*package/i, fn ->
      ReleasePlan.order([%{package: "same"}, %{package: "same"}], [])
    end
  end

  test "an external dependency on the artifact's own package is a release cycle" do
    artifacts = [
      %{
        package: "self_package",
        version: "1.0.0",
        dependencies: [%{app: :self_package, requirement: "~> 1.0", opts: []}]
      }
    ]

    constraints = ReleasePlan.constraints(artifacts)
    assert_raise Error, ~r/cycle/, fn -> ReleasePlan.order(artifacts, constraints) end
  end

  defp coordinated_manifest! do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    root = Manifest.load!(manifest).repo_root

    File.write!(
      Path.join(root, "runtime/local/mix.exs"),
      """
      defmodule Fixture.Runtime.MixProject do
        use Mix.Project
        @requirement "~> 0.2.0"

        def project do
          [app: :fixture_runtime, version: "0.1.0", elixir: "~> 1.18",
           description: inspect({:base_package, "~> 99.0"}),
           deps: [{:fixture_contracts, path: "../../core/contracts"},
                  {:base_alias, @requirement, hex: :base_package}]]
        end
      end
      """
    )

    {raw, _binding} = Code.eval_file(manifest)
    extension = raw[:artifacts][:fixture_bundle]

    extension =
      update_in(extension, [:package], fn package ->
        Keyword.merge(package, name: "extension", otp_app: :extension)
      end)

    base = [
      layout: :components,
      roots: ["core/contracts"],
      package: [name: "base_package", otp_app: :base_package, version: "0.2.1"],
      verify: [hex_publish_check: false]
    ]

    raw = Keyword.put(raw, :artifacts, extension: extension, base: base)
    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))
    manifest
  end
end
