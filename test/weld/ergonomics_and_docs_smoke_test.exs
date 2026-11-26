defmodule Weld.ErgonomicsAndDocsSmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Weld.{DocsSmoke, FixtureCase}

  @moduletag :tmp_dir

  test "Weld.docs_options!/2 returns manifest-driven options with the exdoc:loaded mermaid hook" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    opts = Weld.docs_options!(manifest)

    assert opts[:main] == "readme"
    hook_fn = Keyword.fetch!(opts, :before_closing_body_tag)
    html = hook_fn.(:html)
    assert html =~ "mermaid@11.12.2"
    assert html =~ "exdoc:loaded"
    assert hook_fn.(:epub) == ""
  end

  test "Weld.DocsSmoke.check/2 passes valid HTML and rejects missing exdoc:loaded hook", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "index.html"), "<html></html>")

    File.write!(
      Path.join(dir, "arch.html"),
      ~s|<pre><code class="mermaid">graph TD</code></pre><script src="mermaid.min.js"></script><script>window.addEventListener("exdoc:loaded", () => {})</script>|
    )

    assert {:ok, summary} = DocsSmoke.check(dir)
    assert summary.html_count == 2
    assert summary.mermaid_pages == ["arch.html"]

    File.write!(
      Path.join(dir, "broken.html"),
      ~s(<pre><code class="mermaid">graph TD</code></pre><script>DOMContentLoaded</script>)
    )

    assert {:error, errors} = DocsSmoke.check(dir)
    assert Enum.any?(errors, &(&1 =~ "broken.html" and &1 =~ "exdoc:loaded"))
  end

  test "Mix.Tasks.Weld.Diff.diff_trees/4 reports modified and projection-only files", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "root")
    proj = Path.join(dir, "proj")
    File.mkdir_p!(root)
    File.mkdir_p!(proj)

    File.write!(Path.join(root, "same.txt"), "ok")
    File.write!(Path.join(proj, "same.txt"), "ok")
    File.write!(Path.join(root, "mix.exs"), "root")
    File.write!(Path.join(proj, "mix.exs"), "proj")
    File.write!(Path.join(proj, "weld.provenance.json"), "{}")

    report = Mix.Tasks.Weld.Diff.diff_trees(root, proj, "demo", :full)
    assert report.mix_exs_differs
    assert report.identical_count == 1
    assert report.modified == ["mix.exs"]
    assert report.projection_only == ["weld.provenance.json"]
  end

  test "Mix.Tasks.Weld.Gc.prune/2 keeps newest publish runs and supports dry_run", %{tmp_dir: dir} do
    for idx <- 1..3 do
      run_dir = Path.join([dir, ".weld", "publish", "demo", "abc", "run-#{idx}"])
      File.mkdir_p!(run_dir)
      File.touch!(run_dir, {{2026, 11, 25}, {10, 0, idx}})
    end

    dry = Mix.Tasks.Weld.Gc.prune(dir, keep: 1, dry_run: true)
    assert length(dry.kept) == 1
    assert length(dry.removed) == 2
    assert Enum.all?(dry.removed, &File.dir?/1)

    actual = Mix.Tasks.Weld.Gc.prune(dir, keep: 1, dry_run: false)
    assert length(actual.removed) == 2
    refute Enum.any?(actual.removed, &File.dir?/1)
    assert Enum.all?(actual.kept, &File.dir?/1)
  end

  test "Mix.Tasks.Weld.Doctor outputs valid JSON" do
    json = capture_io(fn -> Mix.Tasks.Weld.Doctor.run(["--format", "json"]) end)
    data = Jason.decode!(json)
    assert is_binary(data["elixir"])
    assert is_boolean(data["git"])
  end

  test "Weld.Release.Plan checks sibling version requirements and orders dependencies first", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "ext"))

    File.write!(
      Path.join(dir, "ext/mix.exs"),
      ~s([{:base, "~> 0.2.0"}, {:other, "~> 9.0", optional: true}])
    )

    artifacts = [
      %{package: "ext", version: "0.1.0", roots: ["ext"]},
      %{package: "base", version: "0.2.1", roots: ["base"]}
    ]

    constraints = Mix.Tasks.Weld.Release.Plan.constraints(artifacts, dir)
    assert [%{dependency: "base", satisfied: true}] = constraints

    assert ["base", "ext"] ==
             artifacts |> Mix.Tasks.Weld.Release.Plan.order(constraints) |> Enum.map(& &1.package)

    bad =
      Mix.Tasks.Weld.Release.Plan.constraints(
        [%{hd(artifacts) | version: "0.1.0"}, %{package: "base", version: "0.3.0", roots: []}],
        dir
      )

    assert [%{satisfied: false}] = bad
  end

  test "mix weld.status adds a next command to each artifact" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    json = capture_io(fn -> Mix.Tasks.Weld.Status.run([manifest, "--format", "json"]) end)
    assert [%{"next_command" => "mix weld.release." <> _}] = Jason.decode!(json)
  end

  test "docs.hook_file is the single owner of the hook text and a missing file fails" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    plan = Weld.Plan.build!(manifest)
    repo_root = plan.manifest.repo_root

    assert Weld.Projector.mermaid_hook(plan) == Weld.Projector.mermaid_hook()

    File.mkdir_p!(Path.join(repo_root, "build_support"))
    File.write!(Path.join(repo_root, "build_support/hook.html"), "<!-- custom -->\n")

    with_file = fn file ->
      %{
        plan
        | artifact: %{
            plan.artifact
            | package: %{
                plan.artifact.package
                | docs: %{plan.artifact.package.docs | hook_file: file}
              }
          }
      }
    end

    assert Weld.Projector.mermaid_hook(with_file.("build_support/hook.html")) ==
             "<!-- custom -->\n"

    assert_raise Weld.Error, ~r/hook_file not found/, fn ->
      Weld.Projector.mermaid_hook(with_file.("build_support/missing.html"))
    end
  end
end
