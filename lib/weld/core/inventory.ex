defmodule Weld.Core.Inventory do
  @moduledoc """
  Pure inventory views and comparison over explicit source/output observations.

  An entry's `target` is a portable relative path; `inputs` contains the
  provenance of every contributing source, including transformations. No view
  discovers files independently of the supplied inventory.
  """

  alias Weld.Core.Identity

  @forbidden ~w(.git .weld deps _build .mix_sources.json)
  @type entry :: map()

  @spec validate!([entry()]) :: [entry()]
  def validate!(entries) do
    sorted = Enum.sort_by(entries, & &1.target)
    targets = Enum.map(sorted, & &1.target)
    set = MapSet.new(targets)

    if MapSet.size(set) != length(targets), do: raise(ArgumentError, "duplicate inventory target")
    folded = Enum.map(targets, &String.downcase/1)

    if length(Enum.uniq(folded)) != length(folded),
      do: raise(ArgumentError, "case-fold inventory collision")

    folded_set = MapSet.new(folded)

    for target <- targets do
      validate_path!(target)

      for parent <- parents(target), MapSet.member?(folded_set, String.downcase(parent)) do
        raise ArgumentError, "inventory file/directory collision: #{parent} and #{target}"
      end
    end

    sorted
  end

  @doc false
  def default_hex_files do
    ~w(lib priv .formatter.exs mix.exs README* readme* LICENSE* license* CHANGELOG* changelog* src c_src Makefile*)
  end

  @doc false
  def relative_charlist_path(path, root) when is_list(path) and is_binary(root) do
    if Enum.all?(path, &is_integer/1), do: strip_charlist_root(path, String.to_charlist(root))
  end

  defp strip_charlist_root(path, root), do: strip_charlist_prefix(path, root, root ++ ~c"/")
  defp strip_charlist_prefix(root, root, _prefix), do: ~c"."

  defp strip_charlist_prefix(path, _root, prefix) do
    if List.starts_with?(path, prefix), do: Enum.drop(path, length(prefix)), else: path
  end

  @spec validate_path!(String.t()) :: String.t()
  def validate_path!(path) do
    if not is_binary(path) or not String.valid?(path) or Path.type(path) != :relative or
         String.contains?(path, ["\\", <<0>>]) or
         Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".." | @forbidden])) do
      raise ArgumentError, "unsafe inventory path: #{inspect(path)}"
    end

    path
  end

  defp parents(path) do
    case Path.dirname(path) do
      "." -> []
      parent -> [parent | parents(parent)]
    end
  end

  @spec view([entry()], :project | :package | :verify | :docs | :live_guard) :: [entry()]
  def view(entries, :project), do: validate!(entries)
  def view(entries, :verify), do: validate!(entries)
  def view(entries, :package), do: entries |> Enum.filter(& &1.publish) |> validate!()

  def view(entries, :docs) do
    entries |> Enum.filter(&(&1.kind in [:compiled, :runtime, :docs, :metadata])) |> validate!()
  end

  def view(entries, :live_guard) do
    entries |> Enum.reject(&(&1.operation == :link_or_copy)) |> validate!()
  end

  @spec targets([entry()], atom()) :: [String.t()]
  def targets(entries, role), do: Enum.map(view(entries, role), & &1.target)

  @doc "Build a reverse index including all contributors to a generated output."
  @spec reverse_index([entry()]) :: map()
  def reverse_index(entries) do
    for entry <- entries, input <- entry.inputs, reduce: %{} do
      index -> Map.update(index, input.source, [entry.target], &[entry.target | &1])
    end
    |> Map.new(fn {source, targets} -> {source, Enum.sort(Enum.uniq(targets))} end)
  end

  @doc "Compare exact expected entries with observed entries keyed by target."
  @spec diff([entry()], %{String.t() => map()}) :: [map()]
  def diff(entries, observed) do
    expected = Map.new(validate!(entries), &{&1.target, &1})

    (Map.keys(expected) ++ Map.keys(observed))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn target ->
      want = expected[target]
      have = observed[target]

      state =
        cond do
          is_nil(want) -> :unexpected
          is_nil(have) -> :missing
          signature(want) == signature(have) -> :identical
          true -> :modified
        end

      %{target: target, state: state, expected: want, observed: have}
    end)
  end

  defp signature(entry), do: Map.take(entry, [:sha256, :size, :executable, :link])

  @spec project_id([map()], [String.t()]) :: String.t()
  def project_id(entries, empty_dirs \\ []) do
    files =
      entries
      |> validate!()
      |> Enum.map(fn entry ->
        %{
          "path" => entry.target,
          "sha256" => entry.sha256,
          "size" => entry.size,
          "executable" => entry.executable
        }
      end)

    Identity.digest("project", %{"entries" => files, "empty_dirs" => Enum.sort(empty_dirs)})
  end
end
