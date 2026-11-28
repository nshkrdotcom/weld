defmodule Weld.SmokeAppTest do
  use ExUnit.Case, async: false

  alias Weld.{FixtureCase, Plan, SmokeApp}

  test "smoke subprocesses receive their own paths and the reported Mix environment" do
    root = FixtureCase.copy_fixture("library_bundle")
    scratch = FixtureCase.unique_tmp_dir("weld_smoke_environment")
    on_exit(fn -> File.rm_rf!(Path.dirname(root)) end)
    on_exit(fn -> File.rm_rf!(scratch) end)
    plan = Plan.build!(Path.join(root, "packaging/weld/fixture_bundle.exs"))
    command = Path.join(scratch, "mix")

    # This probe tests the subprocess boundary, not Mix compilation. The real
    # artifact verifier integration exercises compilation and application code.
    File.write!(command, """
    #!/bin/sh
    [ "$MIX_ENV" = dev ] || exit 41
    [ -z "${MIX_BUILD_PATH+x}" ] || exit 42
    [ "$MIX_BUILD_ROOT" = "$PWD/cache/build" ] || exit 43
    [ "$MIX_DEPS_PATH" = "$PWD/cache/deps" ] || exit 44
    [ -z "${MIX_PATH+x}" ] || exit 45
    [ -z "${MIX_REBAR3+x}" ] || exit 46
    [ -z "${WELD_QC_SANDBOX_API_KEY+x}" ] || exit 47
    printf '%s\\n' "$1" >> checked-commands
    """)

    File.chmod!(command, 0o755)

    variables =
      ~w(PATH MIX_ENV MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_PATH MIX_REBAR3 WELD_QC_SANDBOX_API_KEY)

    saved = Map.new(variables, &{&1, System.get_env(&1)})

    try do
      System.put_env("PATH", scratch <> ":" <> (saved["PATH"] || ""))
      for key <- tl(variables), do: System.put_env(key, "caller-state")
      assert %{task: "smoke", env: :dev, status: :ok} = SmokeApp.verify!(plan, root)
      [record] = Path.wildcard(Path.join(root, ".weld/v2/runs/verify/*/*/checked-commands"))
      assert File.read!(record) == "deps.get\ncompile\n"
    after
      for {key, value} <- saved do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end
  end
end
