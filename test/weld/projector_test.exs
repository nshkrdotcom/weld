defmodule Weld.ProjectorTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase

  test "projects a standalone artifact without embedded proof reports or path deps" do
    result =
      Weld.Commands.project!(FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle"))

    assert File.regular?(Path.join(result.build_path, "mix.exs"))
    refute File.exists?(Path.join(result.build_path, "projection.lock.json"))
    refute "projection.lock.json" in result.package_files

    assert File.regular?(
             Path.join(
               result.build_path,
               "components/core/contracts/lib/weld_fixture/contracts.ex"
             )
           )

    assert File.regular?(
             Path.join(result.build_path, "components/runtime/local/lib/weld_fixture/runtime.ex")
           )

    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))
    refute mixfile =~ ", path:"
    assert mixfile =~ "components/core/contracts/lib"
    assert mixfile =~ "components/runtime/local/lib"
  end

  test "reuses identical outputs and refreshes same-size edits and tampering" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")

    source =
      Path.expand("../../core/contracts/lib/weld_fixture/contracts.ex", Path.dirname(manifest))

    for options <- [[], [live: true]] do
      projection = Weld.Commands.project!(manifest, options)
      refute projection.reused?
      assert Weld.Commands.project!(manifest, options).reused?
      plan = Weld.Plan.build!(manifest)
      kind = if options[:live], do: "live", else: "full"
      marker = Weld.Output.path(plan.manifest.repo_root, ["views", plan.artifact.id, kind <> ".json"])
      original = File.read!(marker)
      File.write!(marker, original <> "\n")
      refute Weld.Commands.project!(manifest, options).reused?
      assert File.read!(marker) == original

      bytes = File.read!(source)
      time = File.stat!(source).mtime
      File.write!(source, String.replace(bytes, "Contracts", "Contractx"))
      File.touch!(source, time)
      refreshed = Weld.Commands.project!(manifest, options)
      assert refreshed.reused? == !!options[:live]
      File.write!(source, bytes)
    end
  end

  test "projects canonicalized external deps instead of local path or scm transport" do
    manifest_path = FixtureCase.copied_manifest_path("external_dependencies", "app_bundle")
    result = Weld.Commands.project!(manifest_path)
    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))

    refute mixfile =~ ", path:"
    refute mixfile =~ "github:"
    assert mixfile =~ "{:external_lib, \"~> 1.2.0\"}"
    assert mixfile =~ "{:git_only, \"~> 0.5.0\"}"
  end

  test "projects a generated application module when selected projects have supervision roots" do
    result =
      Weld.Commands.project!(
        FixtureCase.copied_manifest_path("composite_runtime", "composite_bundle")
      )

    mixfile = File.read!(Path.join(result.build_path, "mix.exs"))
    application_file = Path.join(result.build_path, "lib/composite_bundle/application.ex")

    assert File.regular?(application_file)
    assert mixfile =~ "mod: {CompositeBundle.Application, []}"
    assert mixfile =~ "lib"
    assert File.read!(application_file) =~ "Fixture.State.Application"
    assert File.read!(application_file) =~ "@moduledoc false"
  end
  test "full cache validates empty directories and normalized output permissions" do
    manifest = FixtureCase.copied_manifest_path("library_bundle", "fixture_bundle")
    root = Weld.Manifest.load!(manifest).repo_root
    for directory <- ["empty", "a/x", "a-foo"] do
      File.mkdir_p!(Path.join(root, "core/contracts/lib/" <> directory))
    end
    projection = Weld.Commands.project!(manifest)
    empty = Path.join(projection.build_path, "components/core/contracts/lib/empty")
    assert File.dir?(empty)
    assert Weld.Commands.project!(manifest).reused?

    File.rmdir!(empty)
    refute Weld.Commands.project!(manifest).reused?
    assert File.dir?(empty)

    extra = Path.join(projection.build_path, "unplanned-empty")
    File.mkdir!(extra)
    refute Weld.Commands.project!(manifest).reused?
    refute File.exists?(extra)

    target = Path.join(projection.build_path, "mix.exs")
    File.chmod!(target, 0o600)
    refute Weld.Commands.project!(manifest).reused?
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o644
  end

end
