defmodule Weld.ReleasePlanTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Weld.Release.Plan, as: ReleasePlan
  alias Weld.{FixtureCase, Manifest}

  test "release plans use resolved dependencies and the manifest root outside Git" do
    manifest = coordinated_manifest!()

    report =
      capture_io(fn -> ReleasePlan.run([manifest, "--format", "json"]) end)
      |> Jason.decode!()

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

    assert_raise Mix.Error, ~r/Unsatisfied version constraints/, fn ->
      capture_io(fn -> ReleasePlan.run([manifest, "--format", "json"]) end)
    end

    json = capture_io(fn -> ReleasePlan.run([manifest, "--no-check", "--format", "json"]) end)
    assert [%{"satisfied" => false}] = Jason.decode!(json)["constraints"]
  end

  test "release ordering rejects cycles instead of reporting an impossible order" do
    artifacts = [%{package: "a"}, %{package: "b"}, %{package: "independent"}]

    constraints = [
      %{package: "a", dependency: "b"},
      %{package: "b", dependency: "a"}
    ]

    assert_raise Mix.Error, ~r/cycle/, fn -> ReleasePlan.order(artifacts, constraints) end
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
    assert_raise Mix.Error, ~r/duplicate.*package/i, fn ->
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
    assert_raise Mix.Error, ~r/cycle/, fn -> ReleasePlan.order(artifacts, constraints) end
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
      roots: ["core/contracts"],
      package: [name: "base_package", otp_app: :base_package, version: "0.2.1"],
      verify: [hex_publish: false]
    ]

    raw = Keyword.put(raw, :artifacts, extension: extension, base: base)
    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))
    manifest
  end
end
