defmodule Mix.Tasks.Weld do
  use Mix.Task
  @shortdoc "Compile, qualify and release Weld artifacts"
  @moduledoc "The single Weld command entrypoint. Run `mix weld help` for commands."

  @impl Mix.Task
  def run([]), do: IO.puts(Weld.CLI.help())
  def run(["help"]), do: IO.puts(Weld.CLI.help())
  def run(["help", command]), do: IO.puts(Weld.CLI.help(command))

  def run([command | args]) do
    format = if "json" in args, do: "json", else: "text"

    try do
      request = Weld.CLI.parse!(command, args)

      if request.options[:help] do
        IO.puts(Weld.CLI.help(command))
      else
        emit(command, request.options[:format] || "text", Weld.run(request))
      end
    rescue
      error in [Weld.Error, ArgumentError] ->
        emit(
          command,
          format,
          {:error, [Weld.CLI.diagnostic(:invalid_arguments, Exception.message(error))]}
        )
    after
      Mix.Task.reenable("weld")
    end
  end

  defp emit(command, "json", result) do
    {ok, data, diagnostics} =
      case result do
        {:ok, data} -> {not failed?(data), data, []}
        {:error, diagnostics} -> {false, nil, diagnostics}
      end

    envelope = %{
      schema: "weld.result/2",
      command: command,
      ok: ok,
      data: data,
      diagnostics: diagnostics
    }

    IO.puts(Jason.encode!(Weld.CLI.json_value(envelope)))

    unless ok,
      do:
        exit(
          {:shutdown,
           if(is_map(data) && data[:partial_failure], do: 5, else: if(data, do: 4, else: 3))}
        )
  end

  defp emit("path", _, {:ok, %{path: path}}), do: IO.puts(path)
  defp emit(_, _, {:ok, data}) when is_binary(data), do: IO.puts(data)

  defp emit(_, _, {:ok, data}) do
    IO.puts(inspect(data, pretty: true, limit: :infinity))
    if failed?(data), do: exit({:shutdown, if(data[:partial_failure], do: 5, else: 4)})
  end

  defp emit(_, _, {:error, diagnostics}) do
    Enum.each(diagnostics, &IO.puts(:stderr, "#{&1.code}: #{&1.message}"))
    exit({:shutdown, 3})
  end

  defp failed?(data) when is_map(data),
    do: data[:partial_failure] == true or data[:state] in ["unknown", "conflict"]

  defp failed?(_), do: false
end
