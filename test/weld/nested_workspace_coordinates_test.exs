defmodule Weld.NestedWorkspaceCoordinatesTest do
  use ExUnit.Case, async: false
  setup do
    %{tmp_dir: Weld.FixtureCase.unique_tmp_dir("weld_nested_coordinates")}
  end

  alias Weld.{Affected, Error, FixtureCase, Graph, LiteralPlan, Manifest, Plan, Projector, Workspace}
  alias Weld.Core.{Compiler, Identity}
  alias Weld.Plan.Inventory
  alias Weld.Shell.Snapshot

  @tag :pure
  test "nested source coordinates survive relocation and canonical readback" do
    left = nested_plan("/not-a-checkout/one") |> Inventory.portable()
    right = nested_plan("/another-checkout/two") |> Inventory.portable()
    assert left["input_id"] == right["input_id"]
    assert left["plan_id"] == right["plan_id"]
    assert Inventory.validate_portable!(Identity.decode!(Identity.canonical(left))) == left
    assert Enum.any?(left["inputs"], &(&1["id"] == "file:packages/sdk/build_support/weld.exs"))
    assert Enum.any?(left["inputs"], &(&1["id"] == "glob:.:packages/sdk/apps/*/mix.exs"))
    assert [%{"origins" => ["packages/sdk/apps/a/mix.exs"]}] = left["dependencies"]
    assert [%{"id" => "packages/sdk/apps/a", "probe_inputs" => ["packages/sdk/apps/a/mix.exs"]}] = left["normalized_metadata"]["projects"]
    assert Enum.all?(left["entries"], fn entry ->
      not String.starts_with?(entry["target"], "packages/sdk/") and
        (is_nil(entry["full"]["source"]) or String.starts_with?(entry["full"]["source"], "file:packages/sdk/"))
    end)
    refute Identity.canonical(left) =~ "/not-a-checkout/one"
  end

  test "nested portable rechecks resolve canonical paths and retain checkout confinement", %{tmp_dir: checkout} do
    plan = nested_plan(checkout)
    write_facts!(plan.facts)
    original = Inventory.portable(plan)
    assert :ok == Projector.recheck_inputs!(plan, original["input_id"])
    File.write!(Path.join(checkout, "outside.txt"), "outside the discovery area")
    assert :ok == Projector.recheck_inputs!(plan, original["input_id"])
    assert_raise Error, ~r/unsafe source path/, fn ->
      Snapshot.refresh!(plan.facts, [%{"kind" => "file", "fact" => %{"path" => "../outside.txt"}}])
    end
    new_project = Path.join(plan.manifest.workspace.root, "apps/new")
    File.mkdir_p!(new_project)
    File.write!(Path.join(new_project, "mix.exs"), "# new discovery match\n")
    error = assert_raise Error, fn ->
      Projector.recheck_inputs!(plan, original["input_id"])
    end
    assert error.code == :inputs_changed
  end

  test "nested Git snapshots retain manifest provenance and structural affected paths", %{tmp_dir: checkout} do
    workspace = Path.join(checkout, "packages/sdk")
    File.mkdir_p!(Path.join(checkout, "build_support"))
    File.mkdir_p!(Path.join(workspace, "apps/a/lib"))
    File.write!(Path.join(workspace, "apps/a/mix.exs"), """
    defmodule NestedCoordinates.MixProject do
      use Mix.Project
      def project, do: [app: :nested_coordinates, version: "1.0.0"]
    end
    """)
    File.write!(Path.join(workspace, "apps/a/lib/a.ex"), "defmodule NestedCoordinates, do: def(value, do: :ok)\n")
    File.write!(Path.join(workspace, "VERSION"), "first")
    manifest = Path.join(checkout, "build_support/weld.exs")
    File.write!(manifest, inspect([schema: 2, workspace: [root: "../packages/sdk", projects: ["apps/*"]],
      artifacts: [sdk: [layout: :components, roots: ["packages/sdk/apps/a"],
        package: [name: "nested_coordinates", otp_app: :nested_coordinates, version: "1.0.0"],
        inputs: [[path: "packages/sdk/VERSION", type: :file]], verify: [hex_build: false, hex_publish_check: false]]]],
      pretty: true, limit: :infinity))
    FixtureCase.init_git!(checkout)
    plan = Plan.build!(manifest)
    assert plan.facts.checkout_root == checkout
    assert plan.manifest.repo_root == checkout
    assert plan.manifest.workspace.root == workspace
    assert plan.selected_ids == ["packages/sdk/apps/a"]
    assert plan.workspace.discovery.globs == ["packages/sdk/apps/*"]
    portable = Inventory.portable(plan)
    manifest_path = Path.relative_to(manifest, checkout)
    source = Enum.find(portable["inputs"], &(&1["id"] == "file:" <> manifest_path))
    assert source["fact"]["sha256"] == Identity.raw(File.read!(manifest))

    File.write!(Path.join(workspace, "VERSION"), "second")
    FixtureCase.commit_all!(checkout, "change only nested structural input")
    report = Affected.compare!(manifest, artifact: "sdk", base: "HEAD~1", head: "HEAD", task: "package")
    assert report.affected?
    assert report.structural_changed?
    refute report.unknown?
    assert report.changed_files == ["packages/sdk/VERSION"]
  end

  test "explicit non-Git checkout contains a nested discovery area and an outer manifest", %{tmp_dir: checkout} do
    workspace = Path.join(checkout, "packages/sdk")
    File.mkdir_p!(Path.join(workspace, "apps/a"))
    File.mkdir_p!(Path.join(checkout, "build_support"))
    File.write!(Path.join(workspace, "apps/a/mix.exs"), "# discovery observation only\n")
    manifest_path = Path.join(checkout, "build_support/weld.exs")
    File.write!(manifest_path, inspect([schema: 2,
      workspace: [root: "../packages/sdk", projects: ["apps/*"]],
      artifacts: [sdk: [layout: :components, roots: ["packages/sdk/apps/a"],
        package: [name: "nested_coordinates", otp_app: :nested_coordinates, version: "1.0.0"]]]],
      pretty: true, limit: :infinity))
    manifest = Manifest.load!(manifest_path, checkout_root: checkout)
    assert manifest.repo_root == checkout
    assert manifest.workspace.root == workspace
    assert Workspace.Discovery.discover(manifest).project_ids == ["packages/sdk/apps/a"]
  end

  test "operational directories are excluded and cannot satisfy required source inputs", %{tmp_dir: checkout} do
    for name <- ["doc", "dist", "tmp"] do
      File.mkdir_p!(Path.join(checkout, name))
      File.write!(Path.join([checkout, name, "helper.txt"]), "generated state")
    end
    facts = Snapshot.observe!(checkout)
    for name <- ["doc", "dist", "tmp"] do
      refute Map.has_key?(facts.nodes, Path.join(checkout, name))
      assert_raise Error, ~r/missing declared input/, fn ->
        Weld.Core.Inputs.observe!(facts, checkout,
          [path: name <> "/helper.txt", type: :file, required: true])
      end
    end
  end

  defp nested_plan(checkout) do
    plan = LiteralPlan.build(Path.join(checkout, "packages/sdk"))
    nodes = plan.facts.nodes |> Map.put(checkout, %{type: :directory, mode: 0o755})
      |> Map.put(Path.join(checkout, "packages"), %{type: :directory, mode: 0o755})
    facts = plan.facts |> Map.put(:root, checkout) |> Map.put(:checkout_root, checkout) |> Map.put(:nodes, nodes)
    canonical = "packages/sdk/apps/a"
    dependency = %{app: :external_library, requirement: "~> 1.0", opts: [], original: {:external_library, "~> 1.0"}}
    project = plan.workspace.projects["apps/a"]
    project = %{project | id: canonical, facts: facts, probe_inputs: [canonical <> "/mix.exs"], deps: [dependency],
      deps_by_env: %{dev: [dependency], test: [dependency], prod: [dependency]}}
    projects = %{canonical => project}
    artifact = %{plan.artifact | roots: [canonical]}
    manifest = %{plan.manifest | repo_root: checkout, artifacts: %{artifact.id => artifact}}
    discovery = %{plan.workspace.discovery | project_ids: [canonical], globs: ["packages/sdk/apps/*"]}
    workspace = %{plan.workspace | manifest: manifest, facts: facts, projects: projects,
      discovery: discovery, graph: Graph.build(manifest, projects)}
    struct!(Plan, Compiler.compile!(manifest, workspace, artifact, []))
  end

  defp write_facts!(facts) do
    for {path, %{type: :regular, content: contents}} <- facts.nodes do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end
  end
end
