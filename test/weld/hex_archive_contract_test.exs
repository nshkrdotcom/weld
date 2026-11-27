defmodule Weld.HexArchiveContractTest do
  use ExUnit.Case, async: false
  alias Weld.{Error, FixtureCase, Hash}
  alias Weld.Shell.Hex

  test "actual inner members, executable modes, bytes and dependencies are checked" do
    root = FixtureCase.unique_tmp_dir("hex-archive")
    File.write!(Path.join(root, "mix.exs"), "# frozen\n")
    File.write!(Path.join(root, "build.sh"), "#!/bin/sh\n")
    File.chmod!(Path.join(root, "build.sh"), 0o755)

    metadata = %{
      "name" => "probe",
      "app" => "probe",
      "version" => "1.0.0",
      "files" => ["build.sh", "mix.exs"],
      "requirements" => %{}
    }

    files = [{~c"mix.exs", "# frozen\n"}, {~c"build.sh", "#!/bin/sh\n", %{executable: true}}]
    {:ok, %{tarball: bytes}} = :hex_tarball.create(metadata, files)
    tar = Path.join(root, "probe.tar")
    File.write!(tar, bytes)
    assert :ok = Hex.check_package!(tar, root, ["mix.exs", "build.sh"], metadata)
    assert %{entries: [_, _], metadata: actual} = Hex.package_observation!(tar)
    assert actual["requirements"] == %{}
    File.chmod!(Path.join(root, "build.sh"), 0o644)

    assert_raise Error, ~r/modes/, fn ->
      Hex.check_package!(tar, root, ["mix.exs", "build.sh"], metadata)
    end
  end

  test "docs are built once and roundtrip against exact payload" do
    root = FixtureCase.unique_tmp_dir("hex-docs")
    docs = Path.join(root, "docs")
    File.mkdir!(docs)
    File.write!(Path.join(docs, "index.html"), "<h1>Exact</h1>\n")
    result = Hex.freeze_docs!(docs, Path.join(root, "docs.tar.gz"))
    assert result.sha256 == Hash.sha256_file(result.path)
    assert Hex.docs_observation!(result.path).entries == result.entries
    assert_raise File.Error, fn -> Hex.freeze_docs!(docs, result.path) end
  end

  test "a malformed checksum cannot be accepted merely because the expected files match" do
    root = FixtureCase.unique_tmp_dir("hex-corrupt")
    metadata = %{"name" => "probe", "version" => "1.0.0", "files" => ["mix.exs"]}
    {:ok, %{tarball: bytes}} = :hex_tarball.create(metadata, [{~c"mix.exs", "# frozen"}])
    <<prefix::binary-size(1024), byte, rest::binary>> = bytes
    tar = Path.join(root, "corrupt.tar")
    File.write!(tar, prefix <> <<Bitwise.bxor(byte, 1)>> <> rest)
    assert_raise Error, fn -> Hex.package_observation!(tar) end
  end

  test "actual malicious archive members cannot hide behind matching names or checksums" do
    root = FixtureCase.unique_tmp_dir("hex-attacks")

    for {name, members} <- [
          {"duplicate", [%{path: "mix.exs", bytes: "one"}, %{path: "mix.exs", bytes: "two"}]},
          {"traversal", [%{path: "../escape", bytes: "outside"}]},
          {"absolute", [%{path: "/absolute", bytes: "outside"}]},
          {"alias", [%{path: "lib/../mix.exs", bytes: "alias"}]},
          {"symlink", [%{path: "mix.exs", type: "2", link: "../outside"}]},
          {"hardlink", [%{path: "mix.exs", type: "1", link: "../outside"}]},
          {"fifo", [%{path: "mix.exs", type: "6"}]},
          {"setuid", [%{path: "mix.exs", bytes: "mode", mode: 0o4755}]},
          {"world_writable", [%{path: "mix.exs", bytes: "mode", mode: 0o666}]},
          {"size", [%{path: "mix.exs", bytes: "size", size: 2048}]},
          {"parent_file",
           [%{path: "lib", bytes: "file"}, %{path: "lib/module.ex", bytes: "child"}]}
        ] do
      tar = Path.join(root, name <> ".tar")
      File.write!(tar, Weld.TarFixture.package(members))
      assert_raise Error, fn -> Hex.package_observation!(tar) end
      refute File.exists?(Path.join(Path.dirname(root), "escape"))
    end
  end

  test "duplicate metadata fields and nested dependencies are rejected before map normalization" do
    root = FixtureCase.unique_tmp_dir("hex-metadata-duplicates")

    for suffix <- [
          "{<<\"name\">>,<<\"probe\">>}.\n",
          "{<<\"extra\">>,[{<<\"a\">>,1},{<<\"a\">>,2}]}.\n"
        ] do
      path = Path.join(root, Weld.Output.nonce() <> ".tar")

      File.write!(
        path,
        Weld.TarFixture.package([%{path: "mix.exs", bytes: "# exact"}], &(&1 <> suffix))
      )

      assert_raise Error, ~r/duplicate/, fn -> Hex.package_observation!(path) end
    end
  end

  test "docs reject unsafe paths and preserve explicitly empty directories" do
    root = FixtureCase.unique_tmp_dir("docs-paths")
    malformed = Path.join(root, "malformed.tar.gz")

    File.write!(
      malformed,
      :zlib.gzip(Weld.TarFixture.tar([%{path: "../outside", bytes: "escape"}]))
    )

    assert_raise Error, fn -> Hex.docs_observation!(malformed) end
    docs = Path.join(root, "docs")
    File.mkdir_p!(Path.join(docs, "empty"))
    File.write!(Path.join(docs, "index.html"), "<h1>Docs</h1>")
    result = Hex.freeze_docs!(docs, Path.join(root, "docs.tar.gz"))
    assert result.empty_dirs == ["empty"]
    assert Hex.docs_observation!(result.path).empty_dirs == ["empty"]
  end
end
