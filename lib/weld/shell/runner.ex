defmodule Weld.Shell.Runner do
  @moduledoc false

  @mix_env ~w(MIX_EXS MIX_LOCKFILE MIX_TARGET MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH HEX_API_KEY HEX_API_TOKEN WELD_CI_BUILD_ROOT)
  @max_output 2 * 1024 * 1024

  def run!(command, arguments, opts) do
    timeout = executable!("timeout")
    command = executable!(command)
    seconds = Keyword.fetch!(opts, :seconds)
    env = Enum.map(@mix_env, &{&1, false}) |> Map.new() |> Map.merge(Map.new(opts[:env] || []))

    port =
      Port.open({:spawn_executable, timeout}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        {:args, ["--kill-after=2s", "#{seconds}s", command | arguments]},
        {:cd, Keyword.fetch!(opts, :cd)},
        {:env, Enum.map(env, fn {key, value} -> {to_charlist(key), chars(value)} end)}
      ])

    collect(port, [], 0)
  end

  defp collect(port, chunks, size) do
    receive do
      {^port, {:data, bytes}} when size + byte_size(bytes) <= @max_output ->
        collect(port, [bytes | chunks], size + byte_size(bytes))

      {^port, {:data, _bytes}} ->
        terminate(port)
        raise Weld.Error, "subprocess output exceeded #{@max_output} bytes"

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(Enum.reverse(chunks)), status}
    end
  end

  defp terminate(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        # GNU timeout makes itself and its child a dedicated process group.
        System.cmd(executable!("kill"), ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)

      nil ->
        :ok
    end

    if Port.info(port), do: Port.close(port)
  end

  defp chars(nil), do: false
  defp chars(false), do: false
  defp chars(value), do: to_charlist(value)

  defp executable!(name),
    do:
      System.find_executable(name) ||
        raise(Weld.Error, "required executable unavailable: #{name}")
end
