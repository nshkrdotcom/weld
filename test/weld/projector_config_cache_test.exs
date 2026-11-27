defmodule Weld.ProjectorConfigCacheTest do
  use ExUnit.Case, async: false

  alias Weld.{FixtureCase, Manifest}

  test "full and live package caches refresh config, imports, and companion bytes" do
    for live? <- [false, true] do
      {manifest, config_root} = config_fixture!()
      write_config_tree!(config_root)
      projection = Weld.Commands.project!(manifest, live: live?)
      refute projection.reused?
      assert Weld.Commands.project!(manifest, live: live?).reused?

      for relative <- ["config.exs", "nested/imported.exs", "nested/value.txt"] do
        source = Path.join(config_root, relative)
        original = File.read!(source)
        updated = String.replace(original, "first", "other")
        mtime = File.stat!(source).mtime
        assert byte_size(updated) == byte_size(original)
        File.write!(source, updated)
        File.touch!(source, mtime)

        refreshed = Weld.Commands.project!(manifest, live: live?)

        refute refreshed.reused?
        assert refreshed.build_path == projection.build_path
        assert_runtime_copies!(refreshed, relative, updated)
        assert Weld.Commands.project!(manifest, live: live?).reused?
      end
    end
  end

  test "full and live package caches track missing config roots, additions, and removals" do
    for live? <- [false, true] do
      {manifest, config_root} = config_fixture!()
      File.rm_rf!(config_root)
      projection = Weld.Commands.project!(manifest, live: live?)
      refute projection.reused?
      assert Weld.Commands.project!(manifest, live: live?).reused?

      write_config_tree!(config_root)
      added = Weld.Commands.project!(manifest, live: live?)
      refute added.reused?

      assert_runtime_copies!(
        added,
        "config.exs",
        File.read!(Path.join(config_root, "config.exs"))
      )

      assert Weld.Commands.project!(manifest, live: live?).reused?

      File.write!(Path.join(config_root, "new.txt"), "new companion")
      added_file = Weld.Commands.project!(manifest, live: live?)
      refute added_file.reused?
      assert_runtime_copies!(added_file, "new.txt", "new companion")
      assert Weld.Commands.project!(manifest, live: live?).reused?

      File.rm!(Path.join(config_root, "new.txt"))
      removed_file = Weld.Commands.project!(manifest, live: live?)
      refute removed_file.reused?

      for path <- runtime_copies(removed_file, "new.txt"), do: refute(File.exists?(path))

      assert Weld.Commands.project!(manifest, live: live?).reused?

      File.rm_rf!(config_root)
      removed = Weld.Commands.project!(manifest, live: live?)
      refute removed.reused?

      for path <- runtime_copies(removed, "config.exs"), do: refute(File.exists?(path))

      assert Weld.Commands.project!(manifest, live: live?).reused?
    end
  end

  test "full and live package caches refresh executable changes and normalize non-executable permissions" do
    for live? <- [false, true] do
      {manifest, config_root} = config_fixture!()
      write_config_tree!(config_root)
      source = Path.join(config_root, "nested/value.txt")
      File.chmod!(source, 0o644)
      Weld.Commands.project!(manifest, live: live?)
      assert Weld.Commands.project!(manifest, live: live?).reused?

      File.chmod!(source, 0o600)
      assert Weld.Commands.project!(manifest, live: live?).reused?
      File.chmod!(source, 0o755)
      refreshed = Weld.Commands.project!(manifest, live: live?)

      refute refreshed.reused?
      assert_runtime_copies!(refreshed, "nested/value.txt", "first")

      for path <- runtime_copies(refreshed, "nested/value.txt") do
        assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o755
      end

      assert Weld.Commands.project!(manifest, live: live?).reused?
    end
  end

  defp config_fixture! do
    manifest =
      FixtureCase.copied_manifest_path("package_bootstrap_bundle", "package_bootstrap_bundle")

    {manifest, Path.join(Manifest.load!(manifest).repo_root, "core/bootstrap/config")}
  end

  defp write_config_tree!(root) do
    File.mkdir_p!(Path.join(root, "nested"))

    File.write!(Path.join(root, "config.exs"), """
    import Config
    import_config "nested/imported.exs"
    config :fixture_bootstrap, required_value: :configured, cache_value: :first
    """)

    File.write!(Path.join(root, "nested/imported.exs"), """
    import Config
    config :fixture_bootstrap,
      imported_value: :first,
      companion: File.read!(Path.join(__DIR__, "value.txt"))
    """)

    File.write!(Path.join(root, "nested/value.txt"), "first")
  end

  defp assert_runtime_copies!(projection, relative, contents) do
    for path <- runtime_copies(projection, relative) do
      assert File.read!(path) == contents
    end
  end

  defp runtime_copies(projection, relative) do
    for root <- ["config/runtime_sources", "priv/weld/config/runtime_sources"] do
      Path.join([projection.build_path, root, "core_bootstrap", relative])
    end
  end
end
