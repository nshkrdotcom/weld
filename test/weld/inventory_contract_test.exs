defmodule Weld.InventoryContractTest do
  use ExUnit.Case, async: true
  @moduletag :pure
  alias Weld.{Error, LiteralPlan, Plan}
  alias Weld.Core.Identity

  defp inventory, do: LiteralPlan.build() |> Plan.Inventory.portable()

  defp resign(value) do
    value = Map.put(value, "input_id", Plan.Inventory.input_id(value))
    Map.put(value, "plan_id", Plan.Inventory.plan_id(value))
  end

  test "structural file declarations do not require project-only role fields" do
    plan = LiteralPlan.build("/unavailable/structural", %{"VERSION" => "1.0.0"})
    declaration = [path: "VERSION", type: :file, required: true]

    watch =
      Weld.Core.Inputs.observe!(plan.facts, plan.facts.root, declaration)
      |> Map.merge(%{owner: ".", declaration: declaration})

    plan = %{
      plan
      | input_watches: [watch],
        structural_inputs: Enum.sort(["VERSION" | plan.structural_inputs])
    }

    value = Plan.Inventory.portable(plan)
    input = Enum.find(value["inputs"], &(&1["id"] == "file:VERSION"))
    assert "structure" in input["roles"]
    assert input["fact"]["sha256"] == Identity.raw("1.0.0")
  end

  test "canonical external path overrides retain source semantics without portable absolute locators" do
    path = "/outside-the-checkout/vendor/source"
    plan = external_dependency_plan(path: path)
    assert plan.violations == []

    source_path =
      plan.workspace.projects["apps/a"].deps |> hd() |> Map.fetch!(:opts) |> Keyword.fetch!(:path)

    assert source_path == path
    assert [%{app: :external_library, requirement: "~> 1.0", opts: []}] = plan.external_deps
    value = Plan.Inventory.portable(plan)

    assert [opaque] =
             Enum.filter(value["inputs"], &(&1["kind"] == "external" and &1["fact"]["opaque"]))

    assert opaque["owners"] == ["apps/a"]
    assert opaque["fact"]["value_digest"] == Identity.raw(path)
    refute Identity.canonical(value) =~ path
    [metadata] = value["normalized_metadata"]["projects"]

    for field <- ~w(deps deps_by_env config_by_env) do
      assert Identity.canonical(metadata[field]) =~ opaque["id"]
    end

    assert Plan.Inventory.validate_portable!(Identity.decode!(Identity.canonical(value))) == value

    other =
      external_dependency_plan(path: "/different-provider/source") |> Plan.Inventory.portable()

    refute value["input_id"] == other["input_id"]
  end

  test "canonical local Git overrides replace filesystem locators with opaque input references" do
    for locator <- [
          "/outside-the-checkout/provider.git",
          "file:///outside-the-checkout/provider.git",
          "file://localhost/outside-the-checkout/provider.git",
          "../provider.git",
          "vendor/provider.git"
        ] do
      source_options = [git: locator, ref: "pinned"]
      plan = external_dependency_plan(source_options)
      assert plan.violations == []
      assert hd(plan.workspace.projects["apps/a"].deps).opts == source_options
      assert [%{app: :external_library, requirement: "~> 1.0", opts: []}] = plan.external_deps

      value = Plan.Inventory.portable(plan)

      assert [opaque] =
               Enum.filter(value["inputs"], &(&1["kind"] == "external" and &1["fact"]["opaque"]))

      assert opaque["owners"] == ["apps/a"]
      assert opaque["fact"]["value_digest"] == Identity.raw(locator)
      refute Identity.canonical(value) =~ locator
      [metadata] = value["normalized_metadata"]["projects"]

      for field <- ~w(deps deps_by_env config_by_env) do
        assert Identity.canonical(metadata[field]) =~ opaque["id"]
      end

      assert Plan.Inventory.validate_portable!(Identity.decode!(Identity.canonical(value))) ==
               value
    end
  end

  test "canonical Git overrides retain ordinary remote URL declarations in portable metadata" do
    for remote <- [
          "https://example.test/provider.git",
          "ssh://git@example.test/provider.git",
          "git@example.test:provider.git",
          "file:provider.git"
        ] do
      source_options = [git: remote, ref: "pinned"]
      plan = external_dependency_plan(source_options)
      assert hd(plan.workspace.projects["apps/a"].deps).opts == source_options
      value = Plan.Inventory.portable(plan)
      refute Enum.any?(value["inputs"], &(&1["kind"] == "external" and &1["fact"]["opaque"]))
      [metadata] = value["normalized_metadata"]["projects"]

      for field <- ~w(deps deps_by_env config_by_env) do
        assert Identity.canonical(metadata[field]) =~ remote
      end
    end
  end

  test "opaque checkout Git locators retain portable identities after relocation" do
    for locator <- [
          fn root -> Path.join(root, "vendor/provider.git") end,
          fn root -> "file://" <> Path.join(root, "vendor/provider.git") end,
          fn root -> "file://localhost" <> Path.join(root, "vendor/provider.git") end
        ] do
      [left, right] =
        for root <- ["/checkout/one", "/relocated/two"] do
          source = locator.(root)
          plan = external_dependency_plan([git: source, ref: "pinned"], root)
          assert hd(plan.workspace.projects["apps/a"].deps).opts[:git] == source
          value = Plan.Inventory.portable(plan)
          refute Identity.canonical(value) =~ root
          value
        end

      assert left["input_id"] == right["input_id"]
      assert left["plan_id"] == right["plan_id"]
    end
  end

  test "canonical reader refuses duplicate keys, noncanonical bytes and floats" do
    for bytes <- [~s({"x":1,"x":1}), ~s({ "x":1}), ~s({"x":1.0}), ~s({"z":1,"a":2})] do
      assert_raise ArgumentError, fn -> Identity.decode!(bytes) end
    end

    assert Identity.decode!(Identity.canonical(%{"a:\nλ" => 2, "z" => [true, nil]})) ==
             %{"a:\nλ" => 2, "z" => [true, nil]}
  end

  test "recomputed outer identities cannot authorize malformed closed input facts" do
    source = inventory()
    [entry | rest] = source["inputs"]

    for bad <- [
          Map.put(entry, "extra", true),
          Map.put(entry, "id", "file:unrelated"),
          Map.put(entry, "roles", ["not_a_role"])
        ] do
      changed = %{source | "inputs" => Enum.sort_by([bad | rest], & &1["id"])} |> resign()
      assert_raise Error, fn -> Plan.Inventory.validate_portable!(changed) end
    end
  end

  test "generated references are closed and acyclic" do
    source = inventory()
    generated = Enum.find(source["inputs"], &(&1["kind"] == "generated"))
    bad = put_in(generated, ["fact", "inputs"], [generated["id"]])
    inputs = Enum.map(source["inputs"], &if(&1["id"] == generated["id"], do: bad, else: &1))

    assert_raise Error, ~r/cyclic/, fn ->
      Plan.Inventory.validate_portable!(resign(%{source | "inputs" => inputs}))
    end
  end

  test "write provenance and full link restrictions survive identity recomputation" do
    source = inventory()

    entries =
      Enum.map(source["entries"], fn entry ->
        if entry["target"] == "mix.exs",
          do: put_in(entry, ["full", "strategy"], "link"),
          else: entry
      end)

    assert_raise Error, ~r/full output cannot link/, fn ->
      Plan.Inventory.validate_portable!(resign(%{source | "entries" => entries}))
    end
  end

  defp external_dependency_plan(opts, root \\ "/nonexistent/weld-literal") do
    plan = LiteralPlan.build(root)

    dep = %{
      app: :external_library,
      requirement: nil,
      opts: opts,
      original: {:external_library, opts}
    }

    envs = [:dev, :test, :prod]

    project = %{
      plan.workspace.projects["apps/a"]
      | deps: [dep],
        deps_by_env: Map.new(envs, &{&1, [dep]}),
        config_by_env: Map.new(envs, &{&1, [deps: [dep.original]]})
    }

    projects = %{project.id => project}

    manifest = %{
      plan.manifest
      | dependencies: %{external_library: %{requirement: "~> 1.0", opts: []}}
    }

    workspace = %{
      plan.workspace
      | manifest: manifest,
        projects: projects,
        graph: Weld.Graph.build(manifest, projects)
    }

    struct!(Plan, Weld.Core.Compiler.compile!(manifest, workspace, plan.artifact, []))
  end
end
