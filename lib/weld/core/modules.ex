defmodule Weld.Core.Modules do
  @moduledoc false
  alias Weld.Error
  @doc false
  def validate_module_sources!(sources) do
    Enum.reduce(sources, %{}, fn {path, contents}, seen ->
      declarations = contents |> Code.string_to_quoted!(file: path) |> modules([])
      Enum.reduce(declarations, seen, &register_module!(&2, &1, path))
    end)
  end

  defp register_module!(seen, name, path) do
    if prior = seen[name],
      do: raise(Error, "duplicate module #{inspect(name)} in #{prior} and #{path}")

    Map.put(seen, name, path)
  end

  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, parent) do
    case Enum.all?(parts, &is_atom/1) do
      true ->
        name = if List.first(parts) == :"Elixir", do: tl(parts), else: parent ++ parts
        [Module.concat(name) | modules(body, name)]

      false ->
        raise Error, "dynamic module names are not supported in projection compiler roots"
    end
  end

  defp modules({:__block__, _, statements}, parent),
    do: Enum.flat_map(statements, &modules(&1, parent))

  defp modules({:quote, _, _}, _parent), do: []

  defp modules({:defmodule, _, _}, _parent),
    do: raise(Error, "dynamic module names are not supported in projection compiler roots")

  defp modules({_form, _meta, args}, parent) when is_list(args), do: modules(args, parent)
  defp modules({_key, value}, parent), do: modules(value, parent)
  defp modules(list, parent) when is_list(list), do: Enum.flat_map(list, &modules(&1, parent))
  defp modules(_other, _parent), do: []
end
