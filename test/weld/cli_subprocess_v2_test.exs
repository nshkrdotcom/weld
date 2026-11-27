defmodule Weld.CLISubprocessV2Test do
  use ExUnit.Case, async: false
  alias Weld.FixtureCase

  setup do
    %{tmp_dir: Weld.FixtureCase.unique_tmp_dir("weld_cli_subprocess")}
  end

  test "real Mix subprocesses emit one JSON envelope and exit 2 for bad arguments", %{
    tmp_dir: dir
  } do
    for args <- [
          ["plan", "--unknown", "--format", "json"],
          ["publish", "--format=json"],
          ["graph", "--view", "bogus", "--format", "json"]
        ] do
      {stdout, stderr, status} = cli(dir, args)
      assert status == 2, stderr

      assert %{
               "schema" => "weld.result/2",
               "ok" => false,
               "diagnostics" => [%{"code" => "invalid_arguments"}]
             } = Jason.decode!(stdout)

      refute stdout =~ "\e["
      refute File.exists?(Path.join(dir, ".weld"))
    end
  end

  test "help works from a directory without a project or a manifest", %{tmp_dir: dir} do
    {stdout, _stderr, status} = cli(dir, ["help", "prepare"])
    assert status == 0
    assert stdout =~ "--reuse"
    assert stdout =~ "--context"
    assert File.ls!(dir) == []
  end

  test "nested invocation resolves explicit manifest against invocation cwd and logs only to stderr" do
    root = FixtureCase.copy_fixture("library_bundle")
    FixtureCase.init_git!(root)
    manifest = Path.join(root, "packaging/weld/fixture_bundle.exs")
    File.write!(manifest, "IO.puts(\"trusted manifest log\")\n" <> File.read!(manifest))
    before = source_inventory(root)

    {stdout, stderr, status} =
      cli(Path.join(root, "core/contracts"), [
        "plan",
        "--manifest",
        "../../packaging/weld/fixture_bundle.exs",
        "--format",
        "json",
        "--verbose"
      ])

    assert status == 0, stderr

    assert %{
             "schema" => "weld.result/2",
             "ok" => true,
             "data" => %{"artifact_id" => "fixture_bundle"}
           } = Jason.decode!(stdout)

    assert stderr =~ "trusted manifest log"
    assert stderr =~ "weld plan:"
    assert source_inventory(root) == before
  end

  test "root historical status does not require a current manifest or create state", %{
    tmp_dir: dir
  } do
    {stdout, _stderr, status} =
      cli(dir, [
        "status",
        "--root",
        dir,
        "--artifact",
        "retired",
        "--identity",
        String.duplicate("a", 64),
        "--format",
        "json"
      ])

    assert status == 0
    assert %{"ok" => true, "data" => [%{"artifact" => "retired"}]} = Jason.decode!(stdout)
    refute File.exists?(Path.join(dir, ".weld"))
  end

  test "shell-escaped user paths round trip exactly through a real shell", %{tmp_dir: dir} do
    argument = Path.join(dir, "space ' quote ; literal")
    {output, 0} = System.cmd("sh", ["-c", "printf '%s' " <> Weld.CLI.quote_arg(argument)])
    assert output == argument
  end

  defp cli(cwd, args) do
    log = Path.join(System.tmp_dir!(), "weld-cli-stderr-#{System.unique_integer([:positive])}")
    paths = :code.get_path() |> Enum.map(&to_string/1) |> Enum.flat_map(&["-pa", &1])
    argv = paths ++ ["-e", "Mix.start(); Mix.CLI.main(System.argv())", "--", "weld" | args]

    try do
      {stdout, status} =
        System.cmd(
          "sh",
          [
            "-c",
            "log=$1; shift; exec \"$@\" 2>\"$log\"",
            "weld-cli-test",
            log,
            System.find_executable("elixir") | argv
          ],
          cd: cwd,
          env: [{"MIX_ENV", "test"}]
        )

      {stdout, File.read!(log), status}
    after
      File.rm(log)
    end
  end

  defp source_inventory(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(String.contains?(&1, "/.git/") or Path.basename(&1) == ".git"))
    |> Enum.map(fn path ->
      stat = File.lstat!(path)

      {Path.relative_to(path, root), stat.type, stat.mode,
       if(stat.type == :regular, do: File.read!(path))}
    end)
  end
end
