defmodule Weld.ErgonomicsContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Weld.{Error, FixtureCase, Hash}
  alias Weld.Shell.{Diff, GC}

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

    plan = diff_plan(root, [".formatter.exs", "dropped.ex"])

    assert diff_states(plan, projection, :full) ==
             %{".formatter.exs" => :modified, "dropped.ex" => :missing, "added.ex" => :unexpected}
  end

  test "diff reports a source mix.exs missing from the projection", %{tmp_dir: dir} do
    root = Path.join(dir, "source")
    projection = Path.join(dir, "projection")
    File.mkdir_p!(root)
    File.mkdir_p!(projection)
    File.write!(Path.join(root, "mix.exs"), "source")

    assert diff_states(diff_plan(root, ["mix.exs"]), projection, :full) == %{
             "mix.exs" => :missing
           }
  end

  test "diff follows live directory links while rejecting link cycles", %{tmp_dir: dir} do
    root = Path.join(dir, "source")
    projection = Path.join(dir, "projection")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(projection)
    File.write!(Path.join(root, "lib/example.ex"), "source")
    File.ln_s!(Path.join(root, "lib"), Path.join(projection, "lib"))

    plan = diff_plan(root, ["lib/example.ex"])
    assert diff_states(plan, projection, :live) == %{"lib/example.ex" => :identical}

    File.ln_s!(root, Path.join(root, "lib/loop"))

    assert_raise Error, ~r/unexpected projection symlink: lib\/loop/, fn ->
      Diff.compare(plan, projection, :live)
    end
  end

  test "diff refuses to follow an unplanned dangling link", %{tmp_dir: dir} do
    root = Path.join(dir, "source")
    projection = Path.join(dir, "projection")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(projection)
    File.write!(Path.join(root, "lib/example.ex"), "source")
    File.ln_s!(Path.join(root, "lib"), Path.join(projection, "lib"))
    File.ln_s!("missing-dir", Path.join(root, "docs-latest"))
    File.ln_s!("missing-file", Path.join(projection, "optional.txt"))
    File.ln_s!("lib/example.ex/child", Path.join(root, "not-a-directory"))

    assert_raise Error, ~r/unexpected projection symlink: optional.txt/, fn ->
      Diff.compare(diff_plan(root, ["lib/example.ex"]), projection, :live)
    end
  end

  test "gc preserves active runs independently of completed-run retention", %{tmp_dir: dir} do
    Weld.Git.run!(dir, ["init", "--quiet"])
    Weld.Output.setup!(dir)

    completed =
      Weld.Output.with_lease(dir, "stage", "demo", "review", [], fn lease ->
        run = Weld.Output.run!(dir, "stage", "demo", lease)
        Weld.Output.finish_run!(run, "completed")
        run.path
      end)

    lease = Weld.Output.reserve!(dir, "verify", "demo", "verify", [])

    try do
      active = Weld.Output.run!(dir, "verify", "demo", lease).path
      report = GC.prune(dir, keep: 0, dry_run: false)
      assert report.active == [active]
      assert active in report.kept
      assert report.removed == [completed]
      assert File.dir?(active)
      refute File.exists?(completed)
    after
      Weld.Output.release!(lease)
    end
  end

  test "gc rejects symlinked run parents without deleting their targets", %{tmp_dir: dir} do
    Weld.Git.run!(dir, ["init", "--quiet"])
    Weld.Output.setup!(dir)
    outside = FixtureCase.unique_tmp_dir("weld_gc_outside")
    run = Path.join(outside, "verify-outside")
    File.mkdir_p!(run)
    File.mkdir_p!(Path.join(dir, ".weld/v2/runs"))
    File.ln_s!(outside, Path.join(dir, ".weld/v2/runs/linked"))

    assert_raise Weld.Error, ~r/symlink/, fn -> GC.prune(dir, keep: 0) end
    assert File.dir?(run)
  end

  test "gc dry-run does not create output state", %{tmp_dir: dir} do
    Weld.Git.run!(dir, ["init", "--quiet"])
    assert %{removed: [], kept: []} = GC.prune(dir, dry_run: true)
    refute File.exists?(Path.join(dir, ".weld"))
    refute File.exists?(Path.join(dir, ".gitignore"))
  end

  test "gc rejects a negative retention count", %{tmp_dir: dir} do
    assert_raise Error, ~r/non-negative/, fn -> GC.prune(dir, keep: -1) end
  end

  test "status commands preserve an explicit manifest path from another working directory" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    json =
      capture_io(fn ->
        Mix.Task.rerun("weld", ["status", "--manifest", manifest, "--format", "json"])
      end)

    assert %{"data" => [entry]} = Jason.decode!(json)

    assert entry["next_command"] ==
             "mix weld prepare --manifest '#{manifest}' --artifact 'fixture_bundle'"
  end

  defp diff_plan(root, paths) do
    entries =
      for path <- paths do
        file = Path.join(root, path)

        %{
          target: path,
          sha256: Hash.sha256_file(file),
          size: File.stat!(file).size,
          executable: false,
          inputs: [%{source: path}],
          operation: :link_or_copy
        }
      end

    %{
      artifact: %{id: "demo", mode: :source_project},
      manifest: %{repo_root: root},
      layout: %{
        live: Enum.map(entries, &%{target: &1.target, content: nil}),
        live_roots: [%{target: "lib", source: "lib"}]
      },
      output_inventory: entries
    }
  end

  defp diff_states(plan, projection, kind) do
    plan
    |> Diff.compare(projection, kind)
    |> Map.fetch!(:entries)
    |> Map.new(&{&1.target, &1.state})
  end
end
