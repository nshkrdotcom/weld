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

  test "new CLI flag is explicit and legacy modes report its applicability", %{
    root: root,
    manifest: manifest
  } do
    Mix.Task.rerun("weld.project", [manifest, "--artifact", "sprout", "--live"])
    assert File.regular?(Path.join(root, ".weld/live/sprout/mix.exs"))
    legacy = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    assert_raise Error, ~r/source_project/, fn -> Weld.project!(legacy, live: true) end
  end

  defp marker(projection) do
    projection.build_path |> Path.join("weld.provenance.json") |> File.read!() |> Jason.decode!()
  end
end
