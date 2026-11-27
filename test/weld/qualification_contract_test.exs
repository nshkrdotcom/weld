defmodule Weld.QualificationContractTest do
  use ExUnit.Case, async: false
  alias Weld.{Error, FixtureCase, Plan}
  alias Weld.Shell.GC
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

  @tag integration: true, ci_build: "qualification_faults", timeout: 1_800_000
  test "the shared post-freeze guard rejects bytes, modes, lock and membership mutations" do
    for mutation <- [:bytes, :mode, :permissions, :lock, :extra] do
      root = FixtureCase.copy_fixture("library_bundle")
      Weld.Output.setup!(root)
      plan = Plan.build!(Path.join(root, "packaging/weld/fixture_bundle.exs"))

      callback = fn
        "G02", project ->
          case mutation do
            :bytes -> File.write!(Path.join(project, "mix.exs"), "# tampered", [:append])
            :mode -> File.chmod!(Path.join(project, "mix.exs"), 0o755)
            :permissions -> File.chmod!(Path.join(project, "mix.exs"), 0o600)
            :lock -> File.write!(Path.join(project, "mix.lock"), "%{}\n")
            :extra -> File.write!(Path.join(project, "unplanned.ex"), "# unplanned\n")
          end

        _, _ ->
          :ok
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
  end

  @tag integration: true, ci_build: "qualification_faults", timeout: 1_800_000
  test "GC cannot delete the qualified verifier run before prepare seals it" do
    root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(root)
    plan = Plan.build!(Path.join(root, "packaging/weld/fixture_bundle.exs"))
    owner = self()

    barrier = fn
      :prepare_qualified ->
        [record] = Path.wildcard(Path.join(root, ".weld/v2/runs/verify/*/*/run.json"))
        run = Path.dirname(record)
        proof_run = Weld.Output.read_run!(run)
        assert proof_run["phase"] == "completed"

        assert Enum.any?(Weld.Output.leases(root), fn {_path, lease} ->
                 lease["operation"] == "prepare" and lease["id"] == proof_run["lease_id"]
               end)

        collected =
          Task.async(fn -> GC.prune(root, keep: 0, dry_run: false) end)
          |> Task.await(30_000)

        assert run in collected.active
        refute run in collected.removed
        assert File.regular?(Path.join(run, "project/mix.exs"))
        send(owner, :qualified_run_retained)

      _ ->
        :ok
    end

    prepared = Weld.Release.prepare!(plan, failpoint: barrier)
    assert_receive :qualified_run_retained
    assert File.regular?(Path.join(prepared.project_path, "mix.exs"))
  end
end
