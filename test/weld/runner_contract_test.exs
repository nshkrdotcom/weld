defmodule Weld.RunnerContractTest do
  use ExUnit.Case, async: false
  alias Weld.{Error, FixtureCase}
  alias Weld.Shell.Runner

  test "port cleanup is idempotent after subprocess exit" do
    port = Port.open({:spawn_executable, System.find_executable("true")}, [:exit_status])
    assert_receive {^port, {:exit_status, 0}}, 2_000
    assert :ok = Runner.close_port(port)
    assert Port.info(port) == nil
    assert :ok = Runner.close_port(port)
  end

  test "streamed logs and tails redact credentials, including split output" do
    root = FixtureCase.unique_tmp_dir("runner-redaction")
    log = Path.join(root, "command.log")

    {output, 0} =
      Runner.run!(
        "sh",
        [
          "-c",
          "printf 'Authoriza'; printf 'tion: Bearer secret-token\\nhttps://user:password@host/x?token=hidden\\n'"
        ],
        cd: root,
        seconds: 5,
        log_path: log
      )

    for bytes <- [output, File.read!(log)], secret <- ~w(secret-token password hidden) do
      refute bytes =~ secret
    end

    assert output =~ "[REDACTED]"
  end

  test "large output retains a bounded tail and full sanitized local log" do
    root = FixtureCase.unique_tmp_dir("runner-tail")
    log = Path.join(root, "command.log")

    {output, 0} =
      Runner.run!(
        "sh",
        [
          "-c",
          "i=0; while [ $i -lt 20000 ]; do printf '0123456789\\n'; i=$((i+1)); done; printf 'last-line\\n'"
        ],
        cd: root,
        seconds: 10,
        log_path: log,
        tail_bytes: 1024
      )

    assert byte_size(output) <= 1024
    assert output =~ "last-line"
    assert File.stat!(log).size > 200_000
  end

  @tag :slow
  test "timeout terminates descendants and preserves a sanitized failure tail" do
    root = FixtureCase.unique_tmp_dir("runner-timeout")

    assert_raise Error, ~r/timed out/, fn ->
      Runner.run!(
        "sh",
        ["-c", "sleep 60 & echo $! > child.pid; printf 'api_key=private\\n'; wait"],
        cd: root,
        seconds: 1
      )
    end

    pid = File.read!(Path.join(root, "child.pid")) |> String.trim()
    {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "allowlist strips unknown secrets and conflicting Mix/Hex vars while preserving justified inputs" do
    root = FixtureCase.unique_tmp_dir("runner-environment")

    blocked =
      ~w(MIX_EXS MIX_LOCKFILE MIX_BUILD_PATH MIX_TARGET HEX_API_KEY HEX_UNSAFE_HTTPS
        HEX_UNSAFE_REGISTRY HEX_MIRROR HEX_MIRROR_URL HEX_TRUSTED_MIRROR_URL HEX_REPOS_KEY
        HEX_API_URL WELD_SYNTHETIC_UNKNOWN_SECRET CUSTOM_SECRET_TOKEN CFLAGS)

    allowed = [
      {"HTTP_PROXY", "http://127.0.0.1:8888"},
      {"SSL_CERT_FILE", "/tmp/weld-ca.pem"},
      {"LC_ALL", "C"}
    ]

    all_names = blocked ++ Enum.map(allowed, &elem(&1, 0))
    saved = Map.new(all_names, &{&1, System.get_env(&1)})

    try do
      Enum.each(blocked, &System.put_env(&1, "poison"))
      Enum.each(allowed, fn {name, value} -> System.put_env(name, value) end)

      {output, 0} =
        Runner.run!("env", [],
          cd: root,
          seconds: 5,
          env: [{"CFLAGS", "-O2"}]
        )

      refute output =~ "poison"
      assert output =~ "PATH="
      assert output =~ "HTTP_PROXY=http://127.0.0.1:8888"
      assert output =~ "SSL_CERT_FILE=/tmp/weld-ca.pem"
      assert output =~ "LC_ALL=C"
      assert output =~ "CFLAGS=-O2"
    after
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end
  end

  test "MIX_BUILD_ROOT isolates Mix build path even when parent sets a conflicting MIX_BUILD_PATH" do
    root = FixtureCase.unique_tmp_dir("mix-build-root-isolation")
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(
      Path.join(root, "mix.exs"),
      """
      defmodule BuildRootProbe.MixProject do
        use Mix.Project
        def project, do: [app: :build_root_probe, version: "0.1.0", deps: []]
      end
      """
    )

    isolated_root = Path.join(root, "isolated-build-root")
    conflicting_path = Path.join(root, "conflicting-build-path")
    saved = System.get_env("MIX_BUILD_PATH")

    try do
      System.put_env("MIX_BUILD_PATH", conflicting_path)

      {output, 0} =
        System.cmd(
          "mix",
          ["run", "--no-start", "-e", "IO.puts(Mix.Project.build_path())"],
          cd: root,
          stderr_to_stdout: true,
          env: [{"MIX_BUILD_ROOT", isolated_root}, {"MIX_BUILD_PATH", nil}]
        )

      build_path = output |> String.split("\n", trim: true) |> List.last()
      assert String.starts_with?(build_path, isolated_root <> "/")
      refute File.exists?(conflicting_path)
    after
      if saved,
        do: System.put_env("MIX_BUILD_PATH", saved),
        else: System.delete_env("MIX_BUILD_PATH")
    end
  end
end
