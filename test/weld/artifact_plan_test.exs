defmodule Weld.ArtifactPlanTest do
  use ExUnit.Case, async: false

  alias Weld.{Affected, FixtureCase, Graph, Plan}

  setup do
    root = FixtureCase.copy_fixture("source_project")
    %{root: root, manifest: Path.join(root, "build_support/weld.exs")}
  end

  test "source compilation ownership follows the compiler roots", %{manifest: manifest} do
    plan = Plan.build!(manifest)

    assert plan.dependency_ids == ["."]
    assert plan.source_member_ids == ["components/pure", "components/runtime"]
    assert plan.selected_ids == [".", "components/pure", "components/runtime"]
    assert plan.excluded_ids == ["extensions/color", "extensions/layout"]

    assert Enum.any?(plan.source_inventory, fn entry ->
             entry.source == "components/pure/lib/pure.ex" and entry.owner == "components/pure" and
               entry.kind == :compiled
           end)

    refute Enum.any?(Graph.edges(plan.graph), &(&1.from == "."))
  end

  test "a contained path dependency remains a distinct project", %{
    root: root,
    manifest: manifest
  } do
    mixfile = Path.join(root, "mix.exs")

    mixfile
    |> File.read!()
    |> String.replace(~s("components/pure/lib", ), "")
    |> String.replace("deps: [", ~s(deps: [{:sprout_pure, path: "components/pure"}, ))
    |> then(&File.write!(mixfile, &1))

    {raw, _binding} = Code.eval_file(manifest)
    files = [:artifacts, :sprout, :preserve, :files]
    raw = update_in(raw, files, &["components/pure" | List.delete(&1, "components/pure/lib")])
    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))

    plan = manifest |> Plan.build!() |> Plan.ensure_valid!()
    assert plan.dependency_ids == [".", "components/pure"]
    assert plan.source_member_ids == ["components/runtime"]

    assert Enum.any?(plan.source_inventory, fn entry ->
             entry.source == "components/pure/lib/pure.ex" and entry.kind == :compiled
           end)
  end

  test "affected reports include additions and deletions in compiled source members", %{
    root: root,
    manifest: manifest
  } do
    FixtureCase.init_git!(root)

    File.rm!(Path.join(root, "components/pure/lib/pure.ex"))

    File.write!(
      Path.join(root, "components/runtime/lib/added.ex"),
      "defmodule Sprout.Added do\nend\n"
    )

    FixtureCase.commit_all!(root, "change embedded sources")

    plan = Plan.build!(manifest)
    result = Affected.run!(plan, base: "HEAD~1", head: "HEAD", task: "verify.all")

    assert result.direct_projects == ["components/pure", "components/runtime"]
    assert result.affected_projects == [".", "components/pure", "components/runtime"]

    File.write!(Path.join(root, "extensions/layout/lib/unused.ex"), "# unrelated\n")
    FixtureCase.commit_all!(root, "change unrelated extension")

    result = Affected.run!(plan, base: "HEAD~1", head: "HEAD", task: "verify.all")
    assert result.affected_projects == []
  end

  test "a nested source artifact keeps a native package dependency at its boundary", %{
    root: root,
    manifest: manifest
  } do
    File.write!(Path.join(root, "extensions/color/VERSION"), "0.1.0\n")
    write_color_artifact!(manifest, external: ["."])

    plan = Plan.build!(manifest, artifact: :sprout_color) |> Plan.ensure_valid!()

    assert plan.source_root == Path.join(root, "extensions/color")
    assert plan.selected_ids == ["extensions/color"]
    assert Enum.map(plan.source_inventory, & &1.target) == ["VERSION", "lib/color.ex", "mix.exs"]
    assert [%{app: :sprout, requirement: "~> 0.1.0"}] = plan.external_deps
    assert [%{from: "extensions/color", to: ".", app: :sprout}] = plan.externalized_edges

    assert Graph.path(plan.graph, "extensions/color", ".", :package) ==
             {:ok, ["extensions/color", "."]}

    assert Graph.path(plan.artifact_graph, "extensions/color", ".", :package) == :no_path
  end

  test "a source artifact cannot externalize its native sibling path dependency", %{
    root: root,
    manifest: manifest
  } do
    File.write!(Path.join(root, "extensions/color/VERSION"), "0.1.0\n")
    mixfile = Path.join(root, "extensions/color/mix.exs")
    original = File.read!(mixfile)
    packaged = ~s|@packaged File.regular?(Path.join(__DIR__, "VERSION"))|
    assert original =~ packaged
    File.write!(mixfile, String.replace(original, packaged, "@packaged false"))
    write_color_artifact!(manifest, external: ["."])

    assert_raise Weld.Error,
                 ~r/source_project external boundary requires its native versioned Hex dependency/,
                 fn ->
                   manifest |> Plan.build!(artifact: :sprout_color) |> Plan.ensure_valid!()
                 end
  end

  test "graph artifacts require a canonical version when cutting local edges", %{
    manifest: manifest
  } do
    write_color_artifact!(manifest, layout: :components, external: ["."])

    assert_raise Weld.Error, ~r/canonical/, fn ->
      manifest |> Plan.build!(artifact: :sprout_color) |> Plan.ensure_valid!()
    end

    {raw, _binding} = Code.eval_file(manifest)
    raw = Keyword.put(raw, :dependencies, sprout: [requirement: "~> 0.1.0"])
    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))

    plan = manifest |> Plan.build!(artifact: :sprout_color) |> Plan.ensure_valid!()
    assert plan.dependency_ids == ["extensions/color"]
    assert [%{original: {:sprout, "~> 0.1.0"}}] = Plan.external_deps_for_view(plan, :runtime)
  end

  test "a boundary respects native test scope", %{root: root, manifest: manifest} do
    mixfile = Path.join(root, "extensions/color/mix.exs")

    mixfile
    |> File.read!()
    |> String.replace(~s(path: "../.."), ~s(path: "../..", only: :test, runtime: false))
    |> then(&File.write!(mixfile, &1))

    write_color_artifact!(manifest, layout: :components, external: ["."])
    {raw, _binding} = Code.eval_file(manifest)
    raw = Keyword.put(raw, :dependencies, sprout: [requirement: "~> 0.1.0"])
    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))

    plan = manifest |> Plan.build!(artifact: :sprout_color) |> Plan.ensure_valid!()
    assert plan.external_deps == []
    refute Enum.any?(Plan.projects_for_view(plan, :test), &(&1.id == "."))

    assert [%{app: :sprout, opts: opts}] = Plan.external_deps_for_view(plan, :test)
    assert opts[:only] == :test
    assert opts[:runtime] == false
  end

  defp write_color_artifact!(manifest, overrides) do
    {raw, _binding} = Code.eval_file(manifest)

    artifact =
      Keyword.merge(
        [
          layout: :preserve,
          roots: ["extensions/color"],
          package: [name: "sprout_color", otp_app: :sprout_color, version: "0.1.0"],
          verify: [hex_publish_check: false]
        ],
        overrides
      )

    artifact =
      if artifact[:layout] == :preserve do
        Keyword.put(Keyword.delete(artifact, :package), :preserve, files: ~w(mix.exs VERSION lib))
      else
        artifact
      end

    raw = Keyword.update!(raw, :artifacts, &Keyword.put(&1, :sprout_color, artifact))
    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))
  end
end
