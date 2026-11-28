defmodule Weld.QualificationContractTest do
  use ExUnit.Case, async: true
  alias Weld.Core.Identity
  alias Weld.{Error, FixtureCase, Hash, Plan}
  alias Weld.Verifier

  test "every gate has an explicit spec and mandatory gates cannot be skipped" do
    plan = Plan.build!(FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle"))
    specs = Verifier.gate_specs(plan)

    assert Enum.map(specs, & &1.id) ==
             Enum.map(1..12, &("G" <> String.pad_leading(to_string(&1), 2, "0")))

    gates =
      Enum.map(specs, fn spec ->
        %{
          "id" => spec.id,
          "status" => if(spec.required, do: "pass", else: "skip"),
          "facts" => %{},
          "skip_reason" => spec.skip_reason
        }
      end)

    assert :ok = Verifier.validate_gates!(gates, specs)

    bad =
      List.update_at(
        gates,
        9,
        &Map.merge(&1, %{"status" => "skip", "skip_reason" => "runtime_unavailable"})
      )

    assert_raise Error, ~r/mandatory/, fn -> Verifier.validate_gates!(bad, specs) end
    assert_raise Error, fn -> Verifier.validate_gates!(tl(gates), specs) end
  end

  test "a different executed test with the same count cannot satisfy source identity mapping" do
    plan = %{
      output_inventory: [
        %{target: "test/core_test.exs", inputs: [%{source: "core/test/core_test.exs"}]}
      ]
    }

    original = %{
      "file" => "core/test/core_test.exs",
      "module" => "CoreTest",
      "name" => "test original",
      "state" => "pass"
    }

    projected = %{original | "file" => "test/core_test.exs"}
    assert :ok = Verifier.validate_test_mapping!(plan, [original], [projected])

    for replacement <- [
          %{projected | "name" => "test substituted"},
          %{projected | "state" => "skip"}
        ] do
      assert_raise Error, ~r/test identity/, fn ->
        Verifier.validate_test_mapping!(plan, [original], [replacement])
      end
    end
  end

  test "the shared post-freeze guard rejects bytes, modes, lock and membership mutations" do
    for mutation <- [:bytes, :mode, :permissions, :lock, :extra, :delete, :empty_dir] do
      project = FixtureCase.unique_tmp_dir("frozen-project")
      File.write!(Path.join(project, "mix.exs"), "# frozen source\n")
      File.write!(Path.join(project, "mix.lock"), "%{}\n")
      File.chmod!(Path.join(project, "mix.exs"), 0o644)
      File.chmod!(Path.join(project, "mix.lock"), 0o644)
      observed = Hash.observation(project)
      frozen = %{entries: observed["entries"], empty_dirs: observed["empty_dirs"]}
      lock = Hash.sha256_file(Path.join(project, "mix.lock"))
      excluded = ["doc", "fixture_bundle-0.1.0.tar"]

      assert :ok = Verifier.assert_frozen_project!(project, excluded, frozen, lock, "G02")

      case mutation do
        :bytes -> File.write!(Path.join(project, "mix.exs"), "# tampered", [:append])
        :mode -> File.chmod!(Path.join(project, "mix.exs"), 0o755)
        :permissions -> File.chmod!(Path.join(project, "mix.exs"), 0o600)
        :lock -> File.write!(Path.join(project, "mix.lock"), "%{changed: true}\n")
        :extra -> File.write!(Path.join(project, "unplanned.ex"), "# unplanned\n")
        :delete -> File.rm!(Path.join(project, "mix.exs"))
        :empty_dir -> File.mkdir!(Path.join(project, "unplanned"))
      end

      assert_raise Error, ~r/frozen project|lock/, fn ->
        Verifier.assert_frozen_project!(project, excluded, frozen, lock, "G02")
      end
    end
  end

  @tag integration: true, ci_build: "qualification_faults", timeout: 180_000
  @tag ci_case: "qualification_faults-g02"
  test "a real G02 mutation records failure and blocks all downstream gates" do
    root = FixtureCase.copy_fixture("library_bundle")
    plan = Plan.build!(Path.join(root, "packaging/weld/fixture_bundle.exs"))

    callback = fn
      "G02", project -> File.write!(Path.join(project, "mix.lock"), "\n# changed\n", [:append])
      _, _ -> :ok
    end

    assert_raise Error, ~r/frozen project|lock/, fn ->
      Verifier.verify!(plan, after_gate: callback)
    end

    [gate_file] = Path.wildcard(Path.join(root, ".weld/v2/runs/verify/*/*/gates.json"))
    failed = Jason.decode!(File.read!(gate_file))["gates"]

    assert Enum.map(failed, & &1["id"]) ==
             Enum.map(1..12, &("G" <> String.pad_leading(to_string(&1), 2, "0")))

    assert Enum.at(failed, 1)["status"] == "fail"
    assert Enum.at(failed, 2)["facts"]["blocked_by"] == "G02"
  end

  @tag integration: true, ci_build: "qualification_faults", timeout: 180_000
  @tag ci_case: "qualification_faults-include"
  test "Erlang include options do not bind the G02 digest to the qualification directory" do
    root = FixtureCase.copy_fixture("library_bundle")
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    {config, _binding} = Code.eval_file(manifest)

    config =
      put_in(config, [:artifacts, :fixture_bundle, :verify],
        hex_build: false,
        hex_publish_check: false
      )

    File.write!(manifest, inspect(config, limit: :infinity))
    write_erl_include_fixture!(Path.join(root, "core/contracts"))
    plan = Plan.build!(manifest)
    first = Verifier.verify!(plan)

    assert Enum.find(first.gates, &(&1["id"] == "G04"))["status"] == "pass"

    assert File.regular?(
             Path.join([
               Path.dirname(first.build_path),
               "cache/build/dev/lib/fixture_bundle/ebin",
               "weld_qualification_include.beam"
             ])
           )

    # Run a second independent G01–G02 qualification in a distinct build
    # directory and stop at the skipped G03 boundary after G02 gates.json is
    # persisted, avoiding a redundant second G04–G12 build.
    assert_raise RuntimeError, "stop_after_g02", fn ->
      Verifier.verify!(plan,
        after_gate: fn
          "G03", _project -> raise "stop_after_g02"
          _, _ -> :ok
        end
      )
    end

    gate_files = Path.wildcard(Path.join(root, ".weld/v2/runs/verify/*/*/gates.json"))
    first_run = Path.dirname(first.build_path)
    [second_gate_file] = Enum.reject(gate_files, &(Path.dirname(&1) == first_run))
    assert Path.dirname(second_gate_file) != first_run
    second_gates = Jason.decode!(File.read!(second_gate_file))["gates"]

    assert metadata_sha256(first.gates) == metadata_sha256(second_gates)
  end

  defp metadata_sha256(gates) do
    assert %{"status" => "pass", "facts" => %{"metadata_sha256" => digest}} =
             Enum.find(gates, &(&1["id"] == "G02"))

    assert Identity.valid?(digest)
    digest
  end

  defp write_erl_include_fixture!(project) do
    File.mkdir_p!(Path.join(project, "include"))
    File.mkdir_p!(Path.join(project, "src"))

    File.write!(
      Path.join(project, "include/weld_qualification_header.hrl"),
      "-define(WELD_TEST_VALUE, 42).\n"
    )

    File.write!(Path.join(project, "src/weld_qualification_include.erl"), """
    -module(weld_qualification_include).
    -include("weld_qualification_header.hrl").
    -export([value/0]).
    value() -> ?WELD_TEST_VALUE.
    """)
  end
end
