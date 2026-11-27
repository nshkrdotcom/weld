defmodule Weld.NativePackageMetadataTest do
  use ExUnit.Case, async: true

  alias Weld.{Commands, Error, FixtureCase, Plan}
  alias Weld.Plan.Inventory

  setup do
    root = FixtureCase.copy_fixture("source_project")
    on_exit(fn -> File.rm_rf!(Path.dirname(root)) end)

    %{
      root: root,
      mixfile: Path.join(root, "mix.exs"),
      manifest: Path.join(root, "build_support/weld.exs")
    }
  end

  @tag :slow
  test "native staging preserves supported Hex package options", %{
    mixfile: mixfile,
    manifest: manifest
  } do
    mix =
      put_package_options(mixfile, ~s(organization: "test_org", executables: ["priv/theme.txt"],))

    full = Commands.project!(manifest)
    assert File.read!(Path.join(full.build_path, "mix.exs")) == mix
  end

  @tag :slow
  test "native staging rejects a changed Hex organization", %{
    mixfile: mixfile,
    manifest: manifest
  } do
    put_package_options(
      mixfile,
      ~s|organization: if(String.contains?(__DIR__, "/.weld/"), do: "staged_org", else: "test_org"),|
    )

    assert_raise Error, ~r/staged package metadata differs from source/, fn ->
      Commands.project!(manifest)
    end
  end

  @tag :slow
  test "Erlang charlist include paths stay relocation-stable in plan identities and preserve staging",
       %{
         root: root,
         mixfile: mixfile,
         manifest: manifest
       } do
    other = FixtureCase.copy_fixture("source_project")
    on_exit(fn -> File.rm_rf!(Path.dirname(other)) end)

    for checkout <- [root, other] do
      configure_preserve_erlc_include!(checkout, """
      erlc_options: [
        :debug_info,
        {:i, Path.expand("include", __DIR__) |> String.to_charlist()},
        {:d, :SPROUT_CODEPOINTS, [1, 2, 3]}
      ],
      """)
    end

    other_manifest = Path.join(other, "build_support/weld.exs")
    first = Inventory.portable(Plan.build!(manifest))
    second = Inventory.portable(Plan.build!(other_manifest))

    assert first["input_id"] == second["input_id"]
    assert first["plan_id"] == second["plan_id"]

    full = Commands.project!(manifest)
    live = Commands.project!(manifest, live: true)
    assert File.regular?(Path.join(full.build_path, "include/sprout.hrl"))
    assert File.regular?(Path.join(live.build_path, "mix.exs"))

    put_project_options(
      mixfile,
      """
      erlc_options: [{:i, if(String.contains?(__DIR__, "/.weld/"), do: ~c"/tmp/drift", else: Path.expand("include", __DIR__) |> String.to_charlist())}],
      """
    )

    assert_raise Error, ~r/staged compiler metadata differs from source/, fn ->
      Commands.project!(manifest, no_cache: true)
    end
  end

  @tag :slow
  test "preserve follows the pinned Hex default Makefile* pattern including Makefile.win", %{
    root: root,
    mixfile: mixfile,
    manifest: manifest
  } do
    source =
      mixfile
      |> File.read!()
      |> String.replace(
        ~s|,\n        files: ~w(mix.exs VERSION components/pure/lib components/runtime/lib priv README.md)|,
        ""
      )

    File.write!(mixfile, source)
    File.write!(Path.join(root, "Makefile.win"), "all:\n\t@echo ok\n")

    assert_raise Error, ~r/source inventory missing native package path Makefile\.win/, fn ->
      Plan.build!(manifest)
    end

    manifest_source =
      manifest
      |> File.read!()
      |> String.replace("README.md)", "README.md Makefile.win)")

    File.write!(manifest, manifest_source)
    full = Commands.project!(manifest)
    assert "Makefile.win" in full.package_files
  end

  defp configure_preserve_erlc_include!(checkout, option_line) do
    File.mkdir_p!(Path.join(checkout, "include"))
    File.write!(Path.join(checkout, "include/sprout.hrl"), "-define(SPROUT_HRL, 1).\n")
    put_project_options(Path.join(checkout, "mix.exs"), option_line)

    manifest = Path.join(checkout, "build_support/weld.exs")

    File.write!(
      manifest,
      manifest
      |> File.read!()
      |> String.replace("README.md)", "README.md include)")
    )
  end

  defp put_project_options(mixfile, options) do
    mix =
      mixfile
      |> File.read!()
      |> String.replace("app: :sprout,", "app: :sprout,\n      " <> String.trim(options))

    File.write!(mixfile, mix)
    mix
  end

  defp put_package_options(mixfile, options) do
    mix =
      mixfile |> File.read!() |> String.replace("package: [", "package: [\n        " <> options)

    File.write!(mixfile, mix)
    mix
  end
end
