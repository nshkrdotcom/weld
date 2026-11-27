defmodule Weld.Layout.FilePlan do
  @moduledoc false

  alias Weld.Error
  alias Weld.Core.{Facts, Inventory}

  def copy(source, target, kind, operation \\ :link_or_copy) do
    %{target: target, sources: [source], kind: kind, operation: operation, content: nil}
  end

  def generated(target, content, kind, sources \\ [], operation \\ :generate) do
    %{
      target: target,
      sources: Enum.uniq(sources) |> Enum.sort(),
      kind: kind,
      operation: operation,
      content: content
    }
  end

  # Preserve the historical first destination and repeated slug-prefix policy.
  # Identical files share one physical output and all source owners.
  def merge!(facts, operations, source, target, slug, kind) do
    case Enum.find(operations, &(&1.target == target)) do
      nil -> {operations ++ [copy(source, target, kind, source_operation(kind))], target, []}
      existing -> merge_existing!(facts, operations, existing, source, slug, kind)
    end
  end

  defp merge_existing!(facts, operations, existing, source, slug, kind) do
    target = existing.target

    if is_nil(existing.content) and equal_source?(facts, hd(existing.sources), source) do
      participants = existing.sources ++ [source]
      updated = %{existing | sources: Enum.sort(Enum.uniq(participants)), operation: :copy}
      {replace_target(operations, updated), target, participants}
    else
      if kind == :native or String.starts_with?(target, "include/") or
           (kind == :compiled and Path.extname(target) in ~w(.ex .exs .erl .hrl .c .h .cpp .cc)),
         do: raise(Error, "conflicting source files at #{target}")

      {destination, collisions} = remap_target(target, slug, operations, existing.sources)

      {operations ++ [copy(source, destination, kind, source_operation(kind))], destination,
       collisions ++ [source]}
    end
  end

  defp source_operation(kind) when kind in [:native, :runtime, :metadata], do: :copy
  defp source_operation(_kind), do: :link_or_copy

  defp equal_source?(facts, left, right) do
    left = Facts.stat!(facts, left)
    right = Facts.stat!(facts, right)

    left.sha256 == right.sha256 and left.size == right.size and
      Bitwise.band(left.mode, 0o111) != 0 == (Bitwise.band(right.mode, 0o111) != 0)
  end

  defp replace_target(operations, replacement) do
    Enum.map(operations, fn op ->
      if op.target == replacement.target, do: replacement, else: op
    end)
  end

  defp remap_target(target, slug, operations, collisions) do
    candidate = Path.join(Path.dirname(target), slug <> "__" <> Path.basename(target))

    case Enum.find(operations, &(&1.target == candidate)) do
      nil -> {candidate, collisions}
      existing -> remap_target(candidate, slug, operations, collisions ++ existing.sources)
    end
  end

  def validate!(operations) do
    targets = Enum.map(operations, & &1.target)

    for target <- targets do
      if Path.type(target) != :relative or String.contains?(target, ["\\", <<0>>]) or
           Enum.any?(
             String.split(target, "/"),
             &(&1 in ["", ".", "..", ".git", ".weld", "_build", "deps", ".mix_sources.json"])
           ) or
           target in ["projection.lock.json", "weld.provenance.json"] do
        raise Error, "unsafe planned destination: #{target}"
      end
    end

    duplicates = Enum.frequencies(targets) |> Enum.filter(fn {_target, count} -> count > 1 end)

    if duplicates != [] do
      [{target, _} | _] = Enum.sort(duplicates)

      raise Error, duplicate_target_message(target, operations)
    end

    target_set = MapSet.new(targets)

    for target <- targets, parent <- parents(target), MapSet.member?(target_set, parent) do
      raise Error, "projection file/directory collision: #{parent} and #{target}"
    end

    _ = Inventory.validate!(operations)
    Enum.sort_by(operations, & &1.target)
  end

  defp duplicate_target_message(target, operations) do
    migration? =
      String.starts_with?(target, "priv/") and
        Enum.any?(operations, &(&1.target == target and &1.operation == :copy))

    cond do
      migration? -> "migration path collision: #{target}"
      String.starts_with?(target, "priv/") -> "priv path collision at #{target}"
      true -> "projection path collision: #{target}"
    end
  end

  defp parents(path) do
    case Path.dirname(path) do
      "." -> []
      parent -> [parent | parents(parent)]
    end
  end

  def slug(id) do
    case id |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.trim("_") |> String.downcase() do
      "" -> "root"
      slug -> slug
    end
  end
end
