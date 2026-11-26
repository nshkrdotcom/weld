defmodule Weld.OutputTest do
  use ExUnit.Case, async: true

  alias Weld.{Error, FixtureCase, Output}

  setup do
    root = FixtureCase.unique_tmp_dir("weld_output")
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, ignore: Path.join(root, ".gitignore")}
  end

  test "a missing rule is added once, and is effective from a nested project", %{
    root: root,
    ignore: ignore
  } do
    nested = Path.join(root, "private/component")
    File.mkdir_p!(nested)
    tasks = for _ <- 1..6, do: Task.async(fn -> Weld.Output.setup!(nested) end)
    Enum.each(tasks, &Task.await/1)
    assert File.read!(ignore) == ".weld/\n"
    refute File.exists?(Path.join(nested, ".weld"))

    for probe <-
          ~w(.weld/v2/full/name/project/mix.exs .weld/v2/live/name/priv .weld/v2/cache/test) do
      assert {_, 0} = System.cmd("git", ["check-ignore", "--no-index", probe], cd: root)
    end
  end

  test "normalization preserves unrelated bytes, newline convention and permissions", %{
    root: root,
    ignore: ignore
  } do
    File.write!(ignore, "# local\r\n/.weld/\r\nkeep   \r\n.weld/   \r\n/.weld   \r\nlast")
    File.chmod!(ignore, 0o640)

    for _ <- 1..2 do
      Weld.Output.setup!(root)
      assert File.read!(ignore) == "# local\r\n.weld/\r\nkeep   \r\nlast"
      assert Bitwise.band(File.stat!(ignore).mode, 0o777) == 0o640
    end

    File.write!(ignore, "# last")
    Weld.Output.setup!(root)
    assert File.read!(ignore) == "# last\n.weld/\n"
  end

  test "exceptions, tracked output and unsafe paths fail closed", %{root: root, ignore: ignore} do
    for rule <- ["!/.weld/", "!.weld/keep", "!/.w?ld", "!/.w[e]ld   ", "!/.weld   "] do
      File.write!(ignore, rule)
      assert_raise Error, ~r/conflicting/, fn -> Weld.Output.setup!(root) end
      assert File.read!(ignore) == rule
    end

    File.write!(ignore, ".weld/\n")
    tracked = Path.join(root, ".weld/tracked")
    File.write!(tracked, "owned by Git")
    {_, 0} = System.cmd("git", ["add", "-f", ".weld/tracked"], cd: root)
    assert_raise Error, ~r/tracked/, fn -> Weld.Output.setup!(root) end
    assert File.read!(tracked) == "owned by Git"
    assert_raise Error, ~r/invalid/, fn -> Output.path(root, ["full", "../elsewhere"]) end
  end

  test "refuses files, symlinks and unowned trees at the output root", %{root: root} do
    output = Path.join(root, ".weld")
    File.write!(output, "mine")
    assert_raise Error, fn -> Weld.Output.setup!(root) end
    File.rm!(output)
    File.ln_s!(root, output)
    assert_raise Error, ~r/symlink/, fn -> Weld.Output.setup!(root) end
    File.rm!(output)
    File.mkdir!(output)
    File.mkdir!(Path.join(output, "v2"))
    File.write!(Path.join(output, "v2/user-data"), "preserve")
    assert_raise Error, ~r/unmanaged/, fn -> Weld.Output.setup!(root) end
    assert File.read!(Path.join(output, "v2/user-data")) == "preserve"
  end

  test "activation restores a managed interrupted backup before another rename", %{root: root} do
    Output.setup!(root)
    target = Output.path(root, ["full", "demo", "project"])
    previous = target <> ".weld-previous"
    File.mkdir_p!(previous)
    File.write!(Path.join(previous, "owner"), "weld fixture")
    File.write!(Path.join(previous, "value"), "prior projection")
    managed? = &(File.read(Path.join(&1, "owner")) == {:ok, "weld fixture"})

    missing_stage = Output.path(root, ["staging", "missing"])

    assert_raise File.RenameError, fn ->
      Output.with_lock(root, fn -> Output.activate!(missing_stage, target, managed?) end)
    end

    assert File.read!(Path.join(target, "value")) == "prior projection"
    refute File.exists?(previous)
  end

  test "linked worktrees get independent output roots", %{root: root} do
    FixtureCase.git_output!(root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=test@example.test",
      "commit",
      "--allow-empty",
      "-m",
      "baseline"
    ])

    linked = root <> "-linked"
    on_exit(fn -> File.rm_rf!(linked) end)
    FixtureCase.git_output!(root, ["worktree", "add", "--detach", linked])
    Weld.Output.setup!(linked)
    assert File.regular?(Path.join(linked, ".weld/v2/.owner"))
    refute File.exists?(Path.join(root, ".weld"))
  end
end
