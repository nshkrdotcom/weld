defmodule Weld.SourceProjectTest do
  use ExUnit.Case, async: false

  alias Weld.{Error, FixtureCase}

  setup do
    root = FixtureCase.copy_fixture("source_project")
    on_exit(fn -> File.rm_rf!(Path.dirname(root)) end)
    %{root: root, manifest: Path.join(root, "build_support/weld.exs")}
  end

  test "full projection contains portable root inputs, live points back to source", %{
    root: root,
    manifest: manifest
  } do
    full = Weld.project!(manifest)
    assert full.build_path == Path.join(root, ".weld/full/sprout/project")
    assert %{"kind" => "full", "artifact_id" => digest} = marker(full)
    assert digest =~ ~r/^[0-9a-f]{64}$/

    assert File.read!(Path.join(full.build_path, "mix.exs")) ==
             File.read!(Path.join(root, "mix.exs"))

    assert File.read!(Path.join(full.build_path, "VERSION")) == "0.1.0\n"
    assert File.lstat!(Path.join(full.build_path, "priv")).type == :directory
    refute File.exists?(Path.join(full.build_path, "extensions"))
    assert marker(Weld.project!(manifest)) == marker(full)

    live = Weld.project!(manifest, live: true)
    assert live.build_path == Path.join(root, ".weld/live/sprout")
    assert %{"kind" => "live"} = marker(live)
    refute Map.has_key?(marker(live), "artifact_id")
    assert File.read_link!(Path.join(live.build_path, "priv")) == Path.join(root, "priv")
    File.write!(Path.join(root, "priv/theme.txt"), "azure")
    assert File.read!(Path.join(live.build_path, "priv/theme.txt")) == "azure"
    assert File.read!(Path.join(full.build_path, "priv/theme.txt")) == "sage\n"
    refute marker(Weld.project!(manifest))["artifact_id"] == digest
  end

  test "duplicate modules and escaping links fail before candidate activation", %{
    root: root,
    manifest: manifest
  } do
    full = Weld.project!(manifest)
    previous = marker(full)
    duplicate = Path.join(root, "components/pure/lib/copy.ex")
    File.write!(duplicate, "if true do\n  defmodule Sprout.Runtime do\n  end\nend\n")
    assert_raise Error, ~r/duplicate module/, fn -> Weld.project!(manifest) end
    assert previous == marker(full)
    File.rm!(duplicate)
    File.ln_s!(manifest, Path.join(root, "priv/external"))
    assert_raise Error, fn -> Weld.project!(manifest) end
    assert previous == marker(full)
    File.rm!(Path.join(root, "priv/external"))
    File.rm!(Path.join(full.build_path, "weld.provenance.json"))
    assert_raise Error, ~r/unmanaged/, fn -> Weld.project!(manifest) end
    assert File.regular?(Path.join(full.build_path, "mix.exs"))
  end

  test "missing helper in the portable inventory cannot displace a good candidate", %{
    root: root,
    manifest: manifest
  } do
    full = Weld.project!(manifest)
    previous = marker(full)
    File.write!(Path.join(root, "build_support/metadata.exs"), ":ok\n")
    mix = Path.join(root, "mix.exs")

    File.write!(
      mix,
      "Code.require_file(\"build_support/metadata.exs\", __DIR__)\n" <> File.read!(mix)
    )

    assert_raise Error, ~r/staged source project failed validation/, fn ->
      Weld.project!(manifest)
    end

    assert previous == marker(full)
  end

  test "the live CLI flag keeps source-preserving projects available", %{
    root: root,
    manifest: manifest
  } do
    Mix.Task.rerun("weld.project", [manifest, "--artifact", "sprout", "--live"])
    assert File.regular?(Path.join(root, ".weld/live/sprout/mix.exs"))
  end

  test "a real transitive path dependency stays separate and needs its compiler inputs", ctx do
    %{root: root, manifest: manifest} = ctx
    mixfile = Path.join(root, "mix.exs")
    original = File.read!(mixfile)

    File.write!(
      mixfile,
      original
      |> String.replace(
        ~s(elixirc_paths: ["components/pure/lib", "components/runtime/lib"]),
        ~s(elixirc_paths: ["lib"])
      )
      |> String.replace(
        ~s(deps: [{:ex_doc, "~> 0.40", only: :dev, runtime: false}]),
        ~s(deps: [{:sprout_runtime, path: "components/runtime"}])
      )
      |> String.replace("components/pure/lib components/runtime/lib", "components lib")
    )

    text = File.read!(manifest)
    File.write!(
      manifest,
      String.replace(text, "components/pure/lib components/runtime/lib", "components lib")
    )
    File.mkdir!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/sprout.ex"), "defmodule Sprout do\nend\n")
    source_lock = Path.join(root, "components/pure/mix.lock")
    File.write!(source_lock, "%{}\n")

    %{build_path: candidate} = Weld.project!(manifest)
    mix!(candidate, ["deps.get"])

    mix!(candidate, [
      "run",
      "-e",
      """
      :seed = Sprout.Runtime.value()
      :sprout_runtime = Application.get_application(Sprout.Runtime)
      :sprout_pure = Application.get_application(Sprout.Pure)
      """
    ])

    %{build_path: live} = Weld.project!(manifest, live: true)
    projected_lock = Path.join(live, "components/pure/mix.lock")
    assert File.lstat!(projected_lock).type == :regular
    File.write!(projected_lock, "%{local: true}\n")
    assert File.read!(source_lock) == "%{}\n"

    File.write!(
      manifest,
      String.replace(
        text,
        "components/pure/lib components/runtime/lib",
        "components/pure/mix.exs components/runtime lib"
      )
    )

    assert_raise Error, ~r/source inventory missing components\/pure\/lib/, fn ->
      Weld.project!(manifest)
    end

    File.write!(
      manifest,
      String.replace(text, "components/pure/lib components/runtime/lib", "components lib")
    )

    helper = Path.join(root, "private_metadata.exs")
    File.write!(helper, ":ok\n")
    pure_mixfile = Path.join(root, "components/pure/mix.exs")

    File.write!(
      pure_mixfile,
      ~s(Code.require_file("../../private_metadata.exs", __DIR__)\n) <>
        File.read!(pure_mixfile)
    )

    assert_raise Error, ~r/staged source project failed validation/, fn ->
      Weld.project!(manifest)
    end
  end

  test "nested source preserves its native callbacks, tests and publication inventory" do
    root = FixtureCase.copy_fixture("nested_source_project")
    manifest = Path.join(root, "build_support/weld.exs")
    scratch = FixtureCase.unique_tmp_dir("nested_source_consumers")
    source = Path.join(root, "extensions/palette")

    full = Weld.project!(manifest)
    assert full.package_files == ~w(VERSION build_support mix.exs priv source)
    assert "checks/palette_test.exs" in full.verification_files
    refute File.exists?(Path.join(full.build_path, "extensions"))
    refute File.exists?(Path.join(full.build_path, "lib/workshop.ex"))

    mixfile = Path.join(source, "mix.exs")
    original = File.read!(mixfile)
    File.write!(mixfile, String.replace(original, ~s(["source"]), ~s(["missing"])))
    assert_raise Error, ~r/compiler input is missing: missing/, fn -> Weld.project!(manifest) end
    File.write!(mixfile, original)

    detached = Path.join(scratch, "palette")
    File.cp_r!(full.build_path, detached)
    base = Path.join(scratch, "base")
    File.mkdir!(base)
    File.cp!(Path.join(root, "mix.exs"), Path.join(base, "mix.exs"))
    File.cp_r!(Path.join(root, "lib"), Path.join(base, "lib"))

    live = Weld.project!(manifest, live: true)
    assert "source/palette.ex" in live.linked_files

    assert mix!(live.build_path, ["shade"]) =~ "jade"
    lock = Path.join(source, "mix.lock")
    File.write!(lock, "%{}\n")
    {message, code} = mix(live.build_path, ["shade"])
    assert code != 0
    assert message =~ manifest
    assert message =~ "--artifact workshop_palette --live"

    File.write!(
      manifest,
      String.replace(File.read!(manifest), "mix.exs VERSION", "mix.exs mix.lock VERSION")
    )
    refreshed = Weld.project!(manifest, live: true)
    projected_lock = Path.join(refreshed.build_path, "mix.lock")
    assert File.lstat!(projected_lock).type == :regular
    File.write!(projected_lock, "%{new: :entry}\n")
    assert File.read!(lock) == "%{}\n"
    assert mix!(refreshed.build_path, ["shade"]) =~ "jade"

    {message, code} = mix(refreshed.build_path, ["hex.publish", "--dry-run", "--yes"])
    assert code != 0
    assert message =~ "live projections cannot be packaged"

    File.rm_rf!(root)
    assert mix!(detached, ["shade"]) =~ "jade"

    consumer = Path.join(scratch, "consumer")
    File.mkdir!(consumer)
    deps = [{:workshop, path: base, override: true}, {:workshop_palette, path: detached}]

    File.write!(Path.join(consumer, "mix.exs"), """
    defmodule Workshop.Consumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :workshop_consumer,
          version: "0.0.0",
          test_paths: [#{inspect(Path.join(detached, "checks"))}],
          deps: #{inspect(deps)}
        ]
      end
    end
    """)

    mix!(consumer, ["deps.get"])
    assert mix!(consumer, ["test"]) =~ ~r/(?:1 test, 0 failures|Result: 1 passed)/
  end

  defp mix!(root, args) do
    {output, status} = mix(root, args)
    assert status == 0, "mix #{Enum.join(args, " ")} in #{root}:\n#{output}"
    output
  end

  defp mix(root, args) do
    System.cmd("mix", args,
      cd: root,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"MIX_DEPS_PATH", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_BUILD_ROOT", nil}
      ]
    )
  end

  defp marker(projection) do
    projection.build_path |> Path.join("weld.provenance.json") |> File.read!() |> Jason.decode!()
  end
end
