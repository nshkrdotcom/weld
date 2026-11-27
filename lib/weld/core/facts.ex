defmodule Weld.Core.Facts do
  @moduledoc """
  Pure access to an explicit, immutable observation of the source tree.

  Missing observations never trigger IO. Absolute names are shell locators;
  portable inventories convert them to validated checkout-relative names.
  """
  alias Weld.Core.Inventory
  alias Weld.Error

  def type(facts, path),
    do: Map.get(facts.nodes, Path.expand(path, facts.root), %{type: :missing}).type

  def regular?(facts, path), do: type(facts, path) == :regular
  def dir?(facts, path), do: type(facts, path) == :directory
  def exists?(facts, path), do: type(facts, path) != :missing

  def stat(facts, path) do
    case Map.fetch(facts.nodes, Path.expand(path, facts.root)) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, :enoent}
    end
  end

  def stat!(facts, path) do
    case stat(facts, path) do
      {:ok, node} -> node
      _ -> raise Error, "missing_fact: #{path}"
    end
  end

  def read!(facts, path) do
    case stat(facts, path) do
      {:ok, %{type: :regular, content: content}} when is_binary(content) -> content
      _ -> raise Error, "missing_fact: source bytes for #{path}"
    end
  end

  def digest!(facts, path), do: stat!(facts, path).sha256

  def fingerprint(facts, path) do
    case stat(facts, path) do
      {:ok, %{type: :regular, mode: mode, sha256: digest}} -> {digest, Bitwise.band(mode, 0o111)}
      {:error, :enoent} -> :missing
      _ -> raise Error, "unsafe observed input: #{path}"
    end
  end

  def source!(facts, root, relative) do
    Inventory.validate_path!(relative)
    root = Path.expand(root, facts.root)
    path = Path.expand(relative, root)
    reject_parents!(facts, path, root)
    path
  rescue
    error in ArgumentError -> reraise Error, [message: Exception.message(error)], __STACKTRACE__
  end

  defp reject_parents!(facts, path, root) do
    unless path == root or String.starts_with?(path, root <> "/"),
      do: raise(Error, "observed path escapes source root: #{path}")

    unless type(facts, path) in [:regular, :directory, :missing],
      do: raise(Error, "unsafe observed source: #{path}")

    if path != root, do: reject_parents!(facts, Path.dirname(path), root)
    :ok
  end

  def reject_tree_links!(facts, root) do
    validate_topology!(topology(facts, root))
    root
  end

  defp validate_topology!(nodes) do
    for {path, kind} <- nodes,
        kind not in [:regular, :directory, :missing],
        do: raise(Error, "unsafe observed source: #{path}")

    nodes
  end

  def ls!(facts, root) do
    root = Path.expand(root, facts.root)
    unless dir?(facts, root), do: raise(Error, "missing_fact: directory #{root}")

    facts.nodes
    |> Map.keys()
    |> Enum.filter(&(Path.dirname(&1) == root))
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  def topology(facts, root) do
    root = Path.expand(root, facts.root)

    facts.nodes
    |> Enum.filter(fn {path, _} -> covered?(path, root) end)
    |> Enum.map(fn {path, node} -> {path, node.type} end)
    |> case do
      [] -> [{root, :missing}]
      nodes -> Enum.sort(nodes)
    end
  end

  def list_files(facts, root) do
    nodes = facts |> topology(root) |> validate_topology!()
    for {path, :regular} <- nodes, do: path
  end

  def empty_dirs(facts, root) do
    root = Path.expand(root, facts.root)
    nodes = topology(facts, root)
    parents = MapSet.new(nodes, fn {path, _kind} -> Path.dirname(path) end)

    for {path, :directory} <- nodes,
        path != root,
        not MapSet.member?(parents, path),
        do: Path.relative_to(path, root)
  end

  def wildcard(facts, pattern) do
    regex = glob_regex(Path.expand(pattern, facts.root))
    facts.nodes |> Map.keys() |> Enum.filter(&Regex.match?(regex, &1)) |> Enum.sort()
  end

  def matches?(path, %Regex{} = pattern), do: Regex.match?(pattern, path)
  def matches?(path, pattern), do: Regex.match?(glob_regex(pattern), path)

  defp glob_regex(pattern) do
    source = pattern |> String.graphemes() |> glob_parts(0) |> IO.iodata_to_binary()
    Regex.compile!("\\A" <> source <> "\\z", "u")
  rescue
    error in Regex.CompileError ->
      reraise Error,
              [message: "invalid input glob #{inspect(pattern)}: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp glob_parts(["*", "*", "/" | rest], depth), do: ["(?:.*/)?" | glob_parts(rest, depth)]
  defp glob_parts(["*", "*" | rest], depth), do: [".*" | glob_parts(rest, depth)]
  defp glob_parts(["*" | rest], depth), do: ["[^/]*" | glob_parts(rest, depth)]
  defp glob_parts(["?" | rest], depth), do: ["[^/]" | glob_parts(rest, depth)]
  defp glob_parts(["{" | rest], depth), do: ["(?:" | glob_parts(rest, depth + 1)]
  defp glob_parts(["}" | rest], depth) when depth > 0, do: [")" | glob_parts(rest, depth - 1)]
  defp glob_parts(["," | rest], depth) when depth > 0, do: ["|" | glob_parts(rest, depth)]

  defp glob_parts(["[" | rest], depth) do
    {members, tail} = Enum.split_while(rest, &(&1 != "]"))

    unless members != [] and tail != [] and "/" not in members,
      do: raise(Error, "invalid character class in input glob")

    {negative, members} =
      case members do
        [head | tail] when head in ["!", "^"] -> {"^", tail}
        _ -> {"", members}
      end

    unless members != [], do: raise(Error, "empty character class in input glob")

    escaped =
      Enum.map(members, fn
        "\\" -> "\\\\"
        "^" -> "\\^"
        "[" -> "\\["
        member -> member
      end)

    ["[", negative, escaped, "]" | glob_parts(tl(tail), depth)]
  end

  defp glob_parts(["}" | _], 0), do: raise(Error, "unmatched brace in input glob")
  defp glob_parts([char | rest], depth), do: [Regex.escape(char) | glob_parts(rest, depth)]
  defp glob_parts([], 0), do: []
  defp glob_parts([], _), do: raise(Error, "unclosed brace in input glob")

  defp covered?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
