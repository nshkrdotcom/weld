defmodule Weld.Projector.Monolith.FilePlan do
  @moduledoc false

  alias Weld.{Error, Hash, Output}

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
  def merge!(operations, source, target, slug, kind) do
    case Enum.find(operations, &(&1.target == target)) do
      nil -> {operations ++ [copy(source, target, kind)], target, []}
      existing -> merge_existing!(operations, existing, source, slug, kind)
    end
  end

  defp merge_existing!(operations, existing, source, slug, kind) do
    target = existing.target

    if existing.operation == :link_or_copy and
         fingerprint(hd(existing.sources)) == fingerprint(source) do
      participants = existing.sources ++ [source]
      updated = %{existing | sources: Enum.uniq(participants)}
      {replace_target(operations, updated), target, participants}
    else
      {destination, collisions} = remap_target(target, slug, operations, existing.sources)
      {operations ++ [copy(source, destination, kind)], destination, collisions ++ [source]}
    end
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
           target in ["projection.lock.json", "weld.provenance.json", "mix.lock"] do
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

  def materialize!(operations, build_path, kind) do
    for op <- validate!(operations) do
      target = Output.source!(build_path, op.target)
      if File.exists?(target), do: raise(Error, "projection path collision: #{op.target}")
      File.mkdir_p!(Path.dirname(target))

      case op do
        %{content: content} when is_binary(content) ->
          File.write!(target, content, [:exclusive])

        %{operation: :link_or_copy, sources: [source | _]} when kind == :live ->
          File.ln_s!(source, target)

        %{sources: [source | _]} ->
          File.cp!(source, target)
          File.chmod!(target, Bitwise.band(File.stat!(source).mode, 0o777))
      end

      op.target
    end
  end

  def slug(id) do
    case id |> String.replace(~r/[^a-zA-Z0-9]+/, "_") |> String.trim("_") |> String.downcase() do
      "" -> "root"
      slug -> slug
    end
  end

  def validate_materialized!(operations, build_path, kind, fingerprints) do
    Enum.each(operations, &validate_materialized_operation!(&1, build_path, kind, fingerprints))
    :ok
  end

  defp validate_materialized_operation!(
         %{content: content} = op,
         build_path,
         _kind,
         _fingerprints
       )
       when is_binary(content) do
    target = Path.join(build_path, op.target)

    unless File.regular?(target) and File.read!(target) == content,
      do: raise(Error, "generated output differs from plan: #{op.target}")
  end

  defp validate_materialized_operation!(
         %{operation: :link_or_copy, sources: [source | _]} = op,
         build_path,
         :live,
         _fingerprints
       ) do
    target = Path.join(build_path, op.target)

    unless File.read_link(target) == {:ok, source},
      do: raise(Error, "live link differs from plan: #{op.target}")
  end

  defp validate_materialized_operation!(
         %{sources: [source | _]} = op,
         build_path,
         _kind,
         fingerprints
       ) do
    target = Path.join(build_path, op.target)

    unless fingerprint(target) == Map.fetch!(fingerprints, source),
      do: raise(Error, "copied output differs from plan: #{op.target}")
  end

  def fingerprint(path) do
    Output.reject_link!(path)

    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> {Hash.sha256_file(path), Bitwise.band(mode, 0o111)}
      {:error, :enoent} -> :missing
      _ -> raise Error, "invalid planned input: #{path}"
    end
  end

  def topology(path) do
    Output.reject_link!(path)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        [
          {path, :directory}
          | Enum.flat_map(Enum.sort(File.ls!(path)), &topology(Path.join(path, &1)))
        ]

      {:ok, %{type: :regular}} ->
        [{path, :regular}]

      {:error, :enoent} ->
        [{path, :missing}]

      _ ->
        raise Error, "invalid planned input: #{path}"
    end
  end
end
