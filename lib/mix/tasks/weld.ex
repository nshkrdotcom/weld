defmodule Mix.Tasks.Weld do
  use Mix.Task
  @shortdoc "Compile, qualify and release Weld artifacts"
  @moduledoc "The single Weld command entrypoint. Run `mix weld help` for commands."

  @impl Mix.Task
  def run(args) do
    try do
      invoke(args)
    after
      Mix.Task.reenable("weld")
    end
  end

  defp invoke([]), do: IO.puts(Weld.CLI.help())
  defp invoke(["--help"]), do: IO.puts(Weld.CLI.help())
  defp invoke(["help"]), do: IO.puts(Weld.CLI.help())

  defp invoke(["help", command]) do
    try do
      IO.puts(Weld.CLI.help(command))
    rescue
      error in [Weld.Error, ArgumentError] ->
        emit(
          "help",
          "text",
          {:error, [Weld.CLI.diagnostic(:invalid_arguments, Exception.message(error))]}
        )
    end
  end

  defp invoke([command | args]) do
    format = requested_format(args)

    result =
      try do
        request = Weld.CLI.parse!(command, args)
        Weld.run(request)
      rescue
        error in [Weld.Error, ArgumentError] ->
          {:error, [Weld.CLI.diagnostic(:invalid_arguments, Exception.message(error))]}
      end

    emit(command, format, result)
  end

  defp emit(command, "json", result) do
    IO.puts(Weld.CLI.encode_json(Weld.CLI.envelope(command, result)))
    finish(Weld.CLI.exit_status(command, result))
  end

  defp emit(command, _, {:ok, data} = result) do
    IO.puts(Weld.CLI.render_text(command, data))
    finish(Weld.CLI.exit_status(command, result))
  end

  defp emit(command, _, {:error, diagnostics} = result) do
    Enum.each(
      diagnostics,
      &IO.puts(
        :stderr,
        "#{Weld.CLI.diagnostic_field(&1, :code)}: #{Weld.CLI.diagnostic_field(&1, :message)}"
      )
    )

    finish(Weld.CLI.exit_status(command, result))
  end

  defp finish(0), do: :ok
  defp finish(code), do: exit({:shutdown, code})

  defp requested_format(["--format", value | _]), do: value
  defp requested_format(["--format=" <> value | _]), do: value
  defp requested_format([_ | args]), do: requested_format(args)
  defp requested_format([]), do: "text"
end
