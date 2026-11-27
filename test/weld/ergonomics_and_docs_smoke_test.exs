defmodule Weld.ErgonomicsAndDocsSmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Weld.{DocsSmoke, FixtureCase}
  alias Weld.Layout.Support
  alias Weld.Shell.{Diff, GC}

  @moduletag :tmp_dir

  test "generated docs options include the manifest-driven exdoc:loaded mermaid hook" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    {opts, []} =
      manifest |> Weld.Plan.build!() |> Support.render_docs_options() |> Code.eval_string()

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

  test "semantic diff reports modified and unexpected files", %{
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

    File.write!(Path.join(proj, "only.txt"), "unexpected")

    entries =
      for path <- ["same.txt", "mix.exs"] do
        file = Path.join(root, path)

        %{
          target: path,
          sha256: Weld.Hash.sha256_file(file),
          size: File.stat!(file).size,
          executable: false
        }
      end

    plan = %{artifact: %{id: "demo"}, manifest: %{repo_root: root}, output_inventory: entries}
    report = Diff.compare(plan, proj, :full)

    assert Map.new(report.entries, &{&1.target, &1.state}) ==
             %{
               "mix.exs" => :modified,
               "only.txt" => :unexpected,
               "same.txt" => :identical,
               "weld.provenance.json" => :unexpected
             }
  end

  test "GC.prune/2 keeps newest qualification runs and supports dry_run", %{tmp_dir: dir} do
    Weld.Git.run!(dir, ["init", "--quiet"])
    Weld.Output.setup!(dir)

    for idx <- 1..3 do
      Weld.Output.with_lease(dir, "verify", "demo", "verify", [], fn lease ->
        run = Weld.Output.run!(dir, "verify", "demo", lease)

        Weld.Output.update_run!(run, %{
          "phase" => "completed",
          "started_at" => "2026-11-25T10:00:00Z",
          "finished_at" => "2026-11-25T10:00:0#{idx}Z"
        })
      end)
    end

    dry = GC.prune(dir, keep: 1, dry_run: true)
    assert length(dry.kept) == 1
    assert length(dry.removed) == 2
    assert Enum.all?(dry.removed, &File.dir?/1)

    actual = GC.prune(dir, keep: 1, dry_run: false)
    assert length(actual.removed) == 2
    refute Enum.any?(actual.removed, &File.dir?/1)
    assert Enum.all?(actual.kept, &File.dir?/1)
  end

  test "mix weld doctor outputs valid JSON for a healthy isolated workspace" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    root = Weld.Manifest.load!(manifest).repo_root
    FixtureCase.init_git!(root)
    args = ["doctor", "--root", root, "--manifest", manifest, "--format", "json"]

    json = capture_io(fn -> Mix.Task.rerun("weld", args) end)
    assert %{"ok" => true, "data" => data, "diagnostics" => []} = Jason.decode!(json)
    checks = Map.new(data["checks"], &{&1["name"], &1})
    assert data["root"] == root
    assert is_binary(checks["elixir"]["value"])
    assert checks["git"]["state"] == "ok"
    assert data["errors"] == 0
    assert data["declarations"]["artifacts"] == ["fixture_bundle"]
  end

  test "mix weld doctor reports invalid managed state as JSON and exits nonzero" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    root = Weld.Manifest.load!(manifest).repo_root
    FixtureCase.init_git!(root)
    owner = Weld.Output.path(root, ["OWNER"])
    File.write!(owner, "invalid owner\n")
    args = ["doctor", "--root", root, "--manifest", manifest, "--format", "json"]

    json =
      capture_io(fn ->
        assert catch_exit(Mix.Task.rerun("weld", args)) == {:shutdown, 3}
      end)

    assert %{"ok" => false, "data" => data, "diagnostics" => [_ | _]} = Jason.decode!(json)
    assert data["errors"] > 0
    assert data["state"] == nil
    assert File.read!(owner) == "invalid owner\n"
  end

  test "mix weld.status adds a next command to each artifact" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    json =
      capture_io(fn ->
        Mix.Task.rerun("weld", ["status", "--manifest", manifest, "--format", "json"])
      end)

    assert %{"data" => [%{"next_command" => "mix weld prepare" <> _}]} = Jason.decode!(json)
  end

  test "docs.hook_file is the single owner of the hook text and a missing file fails" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    plan = Weld.Plan.build!(manifest)
    repo_root = plan.manifest.repo_root

    assert Support.mermaid_hook(plan) == Support.mermaid_hook()

    File.mkdir_p!(Path.join(repo_root, "build_support"))
    File.write!(Path.join(repo_root, "build_support/hook.html"), "<!-- custom -->\n")
    plan = Weld.Plan.build!(manifest)

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

    assert Support.mermaid_hook(with_file.("build_support/hook.html")) ==
             "<!-- custom -->\n"

    assert_raise Weld.Error, ~r/missing_fact/, fn ->
      Support.mermaid_hook(with_file.("build_support/missing.html"))
    end
  end
end
