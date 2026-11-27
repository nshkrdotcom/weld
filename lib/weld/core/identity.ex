defmodule Weld.Core.Identity do
  @moduledoc """
  Canonical, domain-separated identities over explicit values.

  This module has no filesystem, clock, Mix, or process dependencies. Callers
  must convert domain enums and structured facts to their wire representation.
  """

  @domains ~w(input plan project package docs qualification bundle work_cache projection_cache)
  @type digest :: String.t()
  @type value :: nil | boolean() | integer() | String.t() | [value()] | %{String.t() => value()}

  @spec canonical(value()) :: binary()
  def canonical(value), do: IO.iodata_to_binary(encode(value))

  @doc "Decode only the unique canonical wire representation; duplicates and floats fail."
  def decode!(bytes) when is_binary(bytes) do
    value = Jason.decode!(bytes)
    unless canonical(value) == bytes, do: raise(ArgumentError, "noncanonical JSON record")
    value
  end

  @spec digest(String.t(), value()) :: digest()
  def digest(domain, value) when domain in @domains do
    raw(["weld/2/", domain, "\n", encode(value)])
  end

  @spec raw(iodata()) :: digest()
  def raw(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  def valid?(_), do: false

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(value) when is_integer(value), do: Integer.to_string(value)

  defp encode(value) when is_binary(value) do
    unless String.valid?(value), do: raise(ArgumentError, "canonical strings must be UTF-8")
    Jason.encode!(value)
  end

  defp encode(value) when is_list(value) do
    ["[", Enum.intersperse(Enum.map(value, &encode/1), ","), "]"]
  end

  defp encode(value) when is_map(value) and not is_struct(value) do
    pairs =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn
        {key, item} when is_binary(key) -> [encode(key), ":", encode(item)]
        _ -> raise ArgumentError, "canonical object keys must be strings"
      end)

    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp encode(_), do: raise(ArgumentError, "unsupported canonical value")
end
