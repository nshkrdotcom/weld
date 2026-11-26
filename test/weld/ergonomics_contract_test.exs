defmodule Weld.ErgonomicsContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Weld.{Diff, Gc, Status}
  alias Weld.{FixtureCase, Output}

  @moduletag :tmp_dir

  test "diff includes dropped files and hidden project configuration while excluding generated trees",
       %{
         tmp_dir: dir
       } do
    root = Path.join(dir, "source")
    projection = Path.join(root, ".weld/v2/full/demo/project")
    File.mkdir_p!(projection)
    File.write!(Path.join(root, ".formatter.exs"), "[inputs: []]")
    File.write!(Path.join(projection, ".formatter.exs"), "[inputs: [\"lib/**/*.ex\"]]")
    File.write!(Path.join(root, "dropped.ex"), "source")
    File.write!(Path.join(projection, "added.ex"), "projection")

    for base <- [root, projection],
        relative <- ["deps/dep.ex", "_build/compiled.beam", "doc/index.html"] do
      path = Path.join(base, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "generated")
    end

    report = Diff.diff_trees(root, projection, "demo", :full)

    assert report.root_only == ["dropped.ex"]
    assert report.modified == [".formatter.exs"]
    assert report.projection_only == ["added.ex"]
  end

  test "diff reports a source mix.exs missing from the projection", %{tmp_dir: dir} do
    root = Path.join(dir, "source")
    projection = Path.join(dir, "projection")
    File.mkdir_p!(root)
    File.mkdir_p!(projection)
    File.write!(Path.join(root, "mix.exs"), "source")

    assert Diff.diff_trees(root, projection, "demo", :full).mix_exs_differs
  end

  test "diff follows live directory links while rejecting link cycles", %{tmp_dir: dir} do
    root = Path.join(dir, "source")
    projection = Path.join(dir, "projection")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(projection)
    File.write!(Path.join(root, "lib/example.ex"), "source")
    File.ln_s!(Path.join(root, "lib"), Path.join(projection, "lib"))

    report = Diff.diff_trees(root, projection, "demo", :live)
    assert report.identical_count == 1
    assert report.root_only == []
    assert report.projection_only == []

    File.ln_s!(root, Path.join(root, "lib/loop"))
    assert_raise Weld.Error, ~r/cycle/, fn -> Diff.diff_trees(root, projection, "demo", :live) end
  end

  test "diff ignores dangling links alongside live linked files", %{tmp_dir: dir} do
    root = Path.join(dir, "source")
    projection = Path.join(dir, "projection")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(projection)
    File.write!(Path.join(root, "lib/example.ex"), "source")
    File.ln_s!(Path.join(root, "lib"), Path.join(projection, "lib"))
    File.ln_s!("missing-dir", Path.join(root, "docs-latest"))
    File.ln_s!("missing-file", Path.join(projection, "optional.txt"))
    File.ln_s!("lib/example.ex/child", Path.join(root, "not-a-directory"))

    report = Diff.diff_trees(root, projection, "demo", :live)

    assert report.identical_count == 1
    assert report.root_only == []
    assert report.projection_only == []
    assert report.modified == []
  end

  test "gc preserves active runs independently of completed-run retention", %{tmp_dir: dir} do
    Weld.Git.run!(dir, ["init", "--quiet"])
    Weld.Output.setup!(dir)
    active = Path.join(dir, ".weld/v2/publish/demo/identity/run-active")
    completed = Path.join(dir, ".weld/v2/publish/demo/identity/run-completed")
    File.mkdir_p!(active)
    File.mkdir_p!(completed)
    File.write!(Path.join(active, "ACTIVE"), "publisher active")

    report = Gc.prune(dir, keep: 0)

    assert report.active == [active]
    assert active in report.kept
    assert report.removed == [completed]
    assert File.dir?(active)
    refute File.exists?(completed)
  end

  test "gc rejects symlinked publish parents without deleting their targets", %{tmp_dir: dir} do
    Weld.Git.run!(dir, ["init", "--quiet"])
    Weld.Output.setup!(dir)
    outside = FixtureCase.unique_tmp_dir("weld_gc_outside")
    run = Path.join(outside, "identity/run-outside")
    File.mkdir_p!(run)
    File.mkdir_p!(Path.join(dir, ".weld/v2/publish"))
    File.ln_s!(outside, Path.join(dir, ".weld/v2/publish/linked"))

    assert_raise Weld.Error, ~r/symlink/, fn -> Gc.prune(dir, keep: 0) end
    assert File.dir?(run)
  end

  test "gc dry-run does not create output state", %{tmp_dir: dir} do
    Weld.Git.run!(dir, ["init", "--quiet"])
    assert %{removed: [], kept: []} = Gc.prune(dir, dry_run: true)
    refute File.exists?(Path.join(dir, ".weld"))
    refute File.exists?(Path.join(dir, ".gitignore"))
  end

  test "gc rejects a negative retention count", %{tmp_dir: dir} do
    assert_raise Mix.Error, ~r/non-negative/, fn -> Gc.prune(dir, keep: -1) end
  end

  test "status commands preserve an explicit manifest path from another working directory" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    json = capture_io(fn -> Status.run([manifest, "--format", "json"]) end)
    assert [entry] = Jason.decode!(json)

    assert entry["next_command"] ==
             "mix release.prepare #{Weld.TaskSupport.shell_arg(manifest)} --artifact 'fixture_bundle'"
  end
end
