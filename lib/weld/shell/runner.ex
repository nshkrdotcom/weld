defmodule Weld.Shell.Runner do
  @moduledoc """
  Argv-only subprocess boundary with isolated overrides, bounded redacted logs
  and process-group termination. GNU timeout is required on supported hosts.
  """

  alias Weld.Error

  @overrides ~w(MIX_EXS MIX_LOCKFILE MIX_ENV MIX_TARGET MIX_BUILD_PATH MIX_BUILD_ROOT
    MIX_DEPS_PATH MIX_HOME MIX_ARCHIVES HEX_HOME HEX_API_KEY HEX_API_TOKEN HEX_TOKEN
    HEX_UNSAFE_HTTPS HEX_UNSAFE_REGISTRY HEX_NO_VERIFY_REPO_ORIGIN HEX_MIRROR
    HEX_TRUSTED_MIRROR HEX_CACERTS_PATH HEX_OFFLINE WELD_CI_BUILD_ROOT ERL_LIBS
    ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN GITHUB_TOKEN GH_TOKEN NPM_TOKEN OPENAI_API_KEY CI_JOB_TOKEN CC CXX AR CFLAGS CXXFLAGS
    CPPFLAGS LDFLAGS MAKEFLAGS RUSTFLAGS RUSTUP_TOOLCHAIN CARGO_HOME RUSTUP_HOME)
  @tail_bytes 64 * 1024
  @max_log_bytes 64 * 1024 * 1024
  @line_bytes 16 * 1024

  def run!(command, arguments, opts), do: execute!(command, arguments, opts, false)

  @doc "Bounded exact bytes for Git object plumbing; never written to diagnostic logs."
  def capture!(command, arguments, opts), do: execute!(command, arguments, opts, true)

  defp execute!(command, arguments, opts, raw?) when is_list(arguments) do
    seconds = Keyword.get(opts, :seconds, 900)
    unless is_integer(seconds) and seconds > 0, do: raise(Error, "invalid subprocess timeout")
    timeout = executable!("timeout")
    executable = executable!(command)
    log = if raw?, do: nil, else: open_log(opts[:log_path])

    try do
      state = state(opts, raw?, log, seconds)
      supervise!(open_port(timeout, executable, arguments, seconds, opts), state)
    after
      if log, do: File.close(log)
    end
  end

  defp open_port(timeout, executable, arguments, seconds, opts) do
    env = Map.new(@overrides, &{&1, nil}) |> Map.merge(Map.new(opts[:env] || []))

    Port.open({:spawn_executable, timeout}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :use_stdio,
      {:args, ["--signal=TERM", "--kill-after=2s", "#{seconds}s", executable | arguments]},
      {:cd, Keyword.fetch!(opts, :cd)},
      {:env, Enum.map(env, fn {key, value} -> {to_charlist(key), chars(value)} end)}
    ])
  end

  defp state(opts, raw?, log, seconds) do
    maximum = opts[:max_bytes] || @max_log_bytes

    %{
      raw: raw?,
      maximum: maximum,
      tail: "",
      pending: "",
      discarded: false,
      total: 0,
      logged: 0,
      log: log,
      limit: if(raw?, do: maximum, else: opts[:tail_bytes] || @tail_bytes),
      secrets: opts[:redact] || [],
      deadline: System.monotonic_time(:millisecond) + seconds * 1000 + 3000
    }
  end

  defp supervise!(port, state) do
    guard =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> monitor_owner(self(), pid)
        nil -> nil
      end

    try do
      collect(port, state)
    after
      if guard, do: send(guard, :finished)
      if Port.info(port), do: terminate(port)
    end
  end

  @doc "Return deliberately selected Mix paths; callers may add declared public inputs."
  def mix_env(project, cache, env, extra \\ []) do
    [
      {"MIX_ENV", to_string(env)},
      {"MIX_TARGET", "host"},
      {"MIX_BUILD_ROOT", Path.join(cache, "build")},
      {"MIX_DEPS_PATH", Path.join(cache, "deps")},
      {"MIX_HOME", Path.join(cache, "mix-home")},
      {"HEX_HOME", Path.join(cache, "hex-home")},
      {"HOME", Path.join(cache, "home")},
      {"XDG_CONFIG_HOME", Path.join(cache, "config-home")},
      {"XDG_CACHE_HOME", Path.join(cache, "system-cache")},
      {"MIX_ARCHIVES", archives_path()},
      {"MIX_EXS", Path.join(project, "mix.exs")}
    ] ++ native_env!() ++ extra
  end

  defp native_env! do
    allowed =
      ~w(CC CXX AR CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS RUSTFLAGS RUSTUP_TOOLCHAIN CARGO_HOME RUSTUP_HOME)

    env = Application.get_env(:weld, :native_env, [])

    unless is_list(env) and
             Enum.all?(env, fn
               {key, value} ->
                 key in allowed and is_binary(value) and not String.contains?(value, <<0>>)

               _ ->
                 false
             end),
           do: raise(Error, "native_env must contain declared nonsecret toolchain inputs")

    env
  end

  defp archives_path do
    case :code.which(Hex) do
      path when is_list(path) ->
        path
        |> to_string()
        |> Path.dirname()
        |> Path.dirname()
        |> Path.dirname()
        |> Path.dirname()

      _ ->
        raise Error, "installed Hex archive is required for isolated Mix execution"
    end
  end

  @doc false
  def sanitize(bytes, secrets \\ []) do
    bytes = if String.valid?(bytes), do: bytes, else: inspect(bytes, limit: :infinity)

    bytes =
      Enum.reduce(secrets, bytes, fn secret, text ->
        if is_binary(secret) and secret != "",
          do: String.replace(text, secret, "[REDACTED]"),
          else: text
      end)

    bytes
    |> then(
      &Regex.replace(
        ~r{(?i)(authorization\s*[:=]\s*)(?:bearer\s+|basic\s+)?[^\s,;]+},
        &1,
        "\\1[REDACTED]"
      )
    )
    |> then(
      &Regex.replace(
        ~r{(?i)((?:api[_-]?key|api[_-]?token|access[_-]?token|refresh[_-]?token|password|secret|token)\s*[=:]\s*)[^\s&;,]+},
        &1,
        "\\1[REDACTED]"
      )
    )
    |> then(&Regex.replace(~r{(https?://)[^\s/@]+@}, &1, "\\1[REDACTED]@"))
  end

  defp collect(port, state) do
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} ->
        total = state.total + byte_size(bytes)

        if total > state.maximum do
          terminate(port)
          raise Error, "subprocess output exceeded #{state.maximum} bytes"
        end

        state = %{state | total: total}

        collect(
          port,
          if(state.raw, do: %{state | tail: state.tail <> bytes}, else: stream(state, bytes))
        )

      {^port, {:exit_status, status}} ->
        state = if state.raw, do: state, else: flush(state)

        if status in [124, 137],
          do:
            raise(
              Error,
              "subprocess timed out; process group terminated\n#{if state.raw, do: "", else: state.tail}"
            )

        {state.tail, status}
    after
      remaining ->
        terminate(port)

        raise Error,
              "subprocess timed out; process group terminated\n#{if state.raw, do: "", else: state.tail}"
    end
  end

  defp stream(state, bytes) do
    case :binary.split(bytes, "\n") do
      [part, rest] ->
        next =
          cond do
            state.discarded ->
              state

            byte_size(state.pending) + byte_size(part) > @line_bytes ->
              emit(state, "[REDACTED overlong output line]\n")

            true ->
              emit(state, state.pending <> part <> "\n")
          end

        stream(%{next | pending: "", discarded: false}, rest)

      [part] ->
        cond do
          state.discarded ->
            state

          byte_size(state.pending) + byte_size(part) > @line_bytes ->
            %{emit(state, "[REDACTED overlong output line]\n") | pending: "", discarded: true}

          true ->
            %{state | pending: state.pending <> part}
        end
    end
  end

  defp flush(%{discarded: true} = state), do: state
  defp flush(state), do: emit(%{state | pending: ""}, state.pending)
  defp emit(state, ""), do: state

  defp emit(state, bytes) do
    bytes = sanitize(bytes, state.secrets)
    logged = state.logged + byte_size(bytes)

    if logged > state.maximum,
      do: raise(Error, "sanitized subprocess log exceeded its byte bound")

    if state.log, do: IO.binwrite(state.log, bytes)
    tail = state.tail <> bytes
    excess = max(byte_size(tail) - state.limit, 0)

    %{
      state
      | logged: logged,
        tail: utf8_tail(binary_part(tail, excess, byte_size(tail) - excess))
    }
  end

  defp utf8_tail(<<byte, rest::binary>>) when byte in 0x80..0xBF, do: utf8_tail(rest)
  defp utf8_tail(bytes), do: bytes

  defp open_log(nil), do: nil

  defp open_log(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = File.open(path, [:write, :exclusive, :binary])
    File.chmod!(path, 0o600)
    io
  end

  defp monitor_owner(owner, pid) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :finished -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, ^owner, _reason} -> terminate_group(pid)
      end
    end)
  end

  defp terminate(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> terminate_group(pid)
      nil -> :ok
    end

    if Port.info(port), do: Port.close(port)
  end

  defp terminate_group(pid),
    do: System.cmd(executable!("kill"), ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)

  defp chars(nil), do: false
  defp chars(false), do: false
  defp chars(value), do: to_charlist(value)

  defp executable!(name),
    do: System.find_executable(name) || raise(Error, "required executable unavailable: #{name}")
end
