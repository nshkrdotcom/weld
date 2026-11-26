defmodule Weld do
  @moduledoc "Deterministic artifact compilation and release operations."
  @version Mix.Project.config()[:version]

  @spec version() :: String.t()
  def version, do: @version

  @doc "Execute a validated command request, returning data or structured diagnostics."
  @spec run(map(), keyword()) :: {:ok, term()} | {:error, [map()]}
  def run(request, opts \\ []), do: Weld.CLI.execute(request, opts)
end
