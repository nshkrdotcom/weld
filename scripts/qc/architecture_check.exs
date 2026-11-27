# Parse source syntax and enforce the pure decision boundary. Run with Mix so
# all source dependencies are available; compilation/xref remain separate gates.
defmodule WeldArchitectureCheck do
  @forbidden ~w(File System Mix Git Output Projector Verifier Release ReleaseStatus
                Application Process Port Agent Task GenServer DateTime Calendar)
  @forbidden_erlang [:file, :filelib, :os, :httpc, :gen_tcp, :ssl, :ets, :persistent_term]
  @pure_code ~w(string_to_quoted string_to_quoted! format_string! quoted_to_algebra)

  def run do
    files =
      (Path.wildcard("lib/weld/core/**/*.ex") ++
         Path.wildcard("lib/weld/layout/**/*.ex") ++
         Path.wildcard("lib/weld/graph/**/*.ex") ++
         ~w(lib/weld/graph.ex lib/weld/plan/inventory.ex lib/weld/plan/boundary.ex
         lib/weld/config/generator.ex lib/weld/source_formatter.ex))
      |> Enum.uniq()
      |> Enum.sort()

    errors =
      Enum.flat_map(files, fn path ->
        ast = Code.string_to_quoted!(File.read!(path), file: path)
        aliases = aliases(ast, %{})
        walk(ast, path, aliases)
      end)

    if errors != [], do: raise(Enum.join(errors, "\n"))

    IO.puts(
      "AST pure-boundary assertions passed for #{length(files)} files; run compiled xref separately."
    )
  end

  defp aliases({:quote, _, _}, acc), do: acc

  defp aliases({:alias, _, [node | opts]}, acc) do
    names =
      case node do
        {{:., _, [{:__aliases__, _, base}, :{}]}, _, children} ->
          Enum.map(children, fn {:__aliases__, _, child} -> base ++ child end)

        {:__aliases__, _, segments} ->
          [segments]

        _ ->
          []
      end

    Enum.reduce(names, acc, fn segments, map ->
      key =
        case Keyword.get(List.flatten(opts), :as) do
          {:__aliases__, _, value} -> List.last(value)
          _ -> List.last(segments)
        end

      Map.put(map, key, segments)
    end)
  end

  defp aliases(value, acc) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.reduce(acc, &aliases/2)

  defp aliases(value, acc) when is_list(value), do: Enum.reduce(value, acc, &aliases/2)
  defp aliases(_, acc), do: acc

  # Quotations are emitted consumer code; checking their bodies as executed
  # compiler code would incorrectly classify the self-contained live guard.
  defp walk({:quote, _, _}, _path, _aliases), do: []

  defp walk({:|>, _, [left, {{:., _, [module, fun]}, meta, args}]}, path, aliases) do
    check(module, fun, length(args) + 1, meta, path, aliases) ++
      walk(left, path, aliases) ++ walk(args, path, aliases)
  end

  defp walk({:&, _, [{:/, _, [{{:., _, [module, fun]}, meta, []}, arity]}]}, path, aliases),
    do: check(module, fun, arity, meta, path, aliases)

  defp walk({{:., _, [module, fun]}, meta, args}, path, aliases)
       when is_atom(fun) and is_list(args),
       do: check(module, fun, length(args), meta, path, aliases) ++ walk(args, path, aliases)

  defp walk(value, path, aliases) when is_tuple(value),
    do: value |> Tuple.to_list() |> walk(path, aliases)

  defp walk(value, path, aliases) when is_list(value),
    do: Enum.flat_map(value, &walk(&1, path, aliases))

  defp walk(_, _, _), do: []

  defp check(module, fun, arity, meta, path, aliases) do
    segments =
      case module do
        {:__aliases__, _, [first | rest]} -> Map.get(aliases, first, [first]) ++ rest
        atom when is_atom(atom) -> [atom]
        _ -> []
      end

    name = Enum.map_join(segments, ".", &to_string/1)
    final = List.last(segments) |> to_string()

    forbidden =
      final in @forbidden or List.first(segments) in @forbidden_erlang or
        (final == "IO" and fun not in [:iodata_to_binary, :iodata_length]) or
        (final == "Code" and to_string(fun) not in @pure_code) or
        (final == "Path" and fun in [:expand, :absname] and arity == 1) or
        String.starts_with?(name, "Weld.Shell.")

    if forbidden,
      do: ["#{path}:#{meta[:line]} forbidden effect #{name}.#{fun}/#{arity}"],
      else: []
  end
end

WeldArchitectureCheck.run()
