defmodule Weld.SourceFormatter do
  @moduledoc false

  @spec format!(String.t()) :: String.t()
  def format!(source) when is_binary(source) do
    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> ensure_trailing_newline()
  end

  defp ensure_trailing_newline(source) do
    if String.ends_with?(source, "\n"), do: source, else: source <> "\n"
  end
end
