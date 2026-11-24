defmodule Weld.VerificationIntegrityTest do
  use ExUnit.Case, async: false

  alias Weld.{Error, FixtureCase, Hash}

  test "verification identity detects changes to existing files and executable bits" do
    root = FixtureCase.unique_tmp_dir("verification_identity")
    file = Path.join(root, "fixture.txt")
    File.write!(file, "before\n")
    before = Hash.verification_identity(root, ["fixture.txt", "mix.lock"])
    File.write!(Path.join(root, "mix.lock"), "%{}\n")
    assert before == Hash.verification_identity(root, ["fixture.txt", "mix.lock"])
    File.write!(file, "after\n")
    refute before == Hash.verification_identity(root, ["fixture.txt", "mix.lock"])
    File.write!(file, "before\n")
    File.chmod!(file, 0o755)
    refute before == Hash.verification_identity(root, ["fixture.txt", "mix.lock"])
  end

  test "mutable graph output destinations cannot link into source" do
    for fixture <- ["library_bundle", "monolith_bundle"], path <- ["mix.lock", "doc"] do
      root = FixtureCase.copy_fixture(fixture)
      artifact = if fixture == "library_bundle", do: :fixture_bundle, else: :monolith_bundle
      manifest = Path.join(root, "packaging/weld/#{artifact}.exs")
      {raw, _} = Code.eval_file(manifest)

      raw =
        update_in(
          raw,
          [:artifacts, artifact, :output, :assets],
          &Enum.uniq([path | List.wrap(&1)])
        )

      File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))
      File.write!(Path.join(root, path), "source must remain untouched\n")

      assert_raise Error, ~r/output path overlaps/, fn ->
        Weld.project!(manifest, live: true)
      end

      assert File.read!(Path.join(root, path)) == "source must remain untouched\n"
    end
  end

  test "publication identity observes newly created package files" do
    root = FixtureCase.unique_tmp_dir("package_identity")
    File.mkdir!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/original.ex"), "# original\n")
    before = Hash.package_identity(root, ["lib"])
    File.write!(Path.join(root, "lib/generated.ex"), "# unverified generated input\n")
    refute before == Hash.package_identity(root, ["lib"])
  end

  test "migration copies cannot replace linked root assets" do
    root = FixtureCase.copy_fixture("monolith_bundle")
    manifest = Path.join(root, "packaging/weld/monolith_bundle.exs")
    relative = "priv/repo/migrations/20260101000000_create_store.exs"
    source = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "root asset\n")
    {raw, _} = Code.eval_file(manifest)
    raw = update_in(raw, [:artifacts, :monolith_bundle, :output, :assets], &["priv" | &1])
    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))

    assert_raise Error, ~r/migration path collision/, fn ->
      Weld.project!(manifest, live: true)
    end

    assert File.read!(source) == "root asset\n"
  end

  test "native package directories cannot silently lose declared files" do
    root = FixtureCase.copy_fixture("nested_source_project")
    source = Path.join(root, "extensions/palette")
    manifest = Path.join(root, "build_support/weld.exs")
    File.mkdir!(Path.join(source, "guides"))
    File.write!(Path.join(source, "guides/a.md"), "included\n")
    File.write!(Path.join(source, "guides/b.md"), "also native package content\n")
    mixfile = Path.join(source, "mix.exs")

    File.write!(
      mixfile,
      String.replace(
        File.read!(mixfile),
        "files: Workshop.Palette.Package.files()",
        "files: [\"guides\" | Workshop.Palette.Package.files()]"
      )
    )

    {raw, _} = Code.eval_file(manifest)

    raw =
      update_in(
        raw,
        [:artifacts, :workshop_palette, :source_project, :files],
        &["guides/a.md" | &1]
      )

    File.write!(manifest, inspect(raw, pretty: true, limit: :infinity))

    assert_raise Error, ~r/source inventory missing native package path guides\/b.md/, fn ->
      Weld.project!(manifest)
    end
  end

  test "native live mutable outputs cannot target authoritative source" do
    for field <- ["build_path", "deps_path", "lockfile"] do
      root = FixtureCase.copy_fixture("nested_source_project")
      source = Path.join(root, "extensions/palette")
      manifest = Path.join(root, "build_support/weld.exs")
      mixfile = Path.join(source, "mix.exs")
      original = File.read!(mixfile)

      File.write!(
        mixfile,
        String.replace(
          original,
          "app: :workshop_palette,",
          "app: :workshop_palette, #{field}: Path.join(__DIR__, \"mutable\"),"
        )
      )

      assert_raise Error, ~r/mutable path escapes/, fn ->
        Weld.project!(manifest, live: true)
      end

      refute File.exists?(Path.join(source, "mutable"))
    end
  end

  test "native publication wildcards cannot include generated provenance" do
    root = FixtureCase.copy_fixture("nested_source_project")
    mixfile = Path.join(root, "extensions/palette/mix.exs")

    File.write!(
      mixfile,
      String.replace(
        File.read!(mixfile),
        "files: Workshop.Palette.Package.files()",
        "files: [\"*\"]"
      )
    )

    assert_raise Error, ~r/allowlist includes generated publication metadata/, fn ->
      Weld.project!(Path.join(root, "build_support/weld.exs"))
    end
  end
end
