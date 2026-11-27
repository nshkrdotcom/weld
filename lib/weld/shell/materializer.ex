defmodule Weld.Shell.Materializer do
  @moduledoc "Execute a closed compiler operation list without selecting or rendering inputs."
  alias Weld.Core.{Facts, Identity, Inventory}
  alias Weld.{Error, Hash, Output}

  def execute!(layout, facts, stage, kind) do
    if kind == :live and Map.get(layout, :live_error), do: raise(Error, layout.live_error)
    operations = Map.fetch!(layout, kind)
    groups = if kind == :live, do: Map.get(layout, :live_roots, []), else: []

    for group <- groups do
      source = Output.source!(facts.root, group.source)
      target = Output.source!(stage, group.target)
      Output.reject_tree_links!(source)
      File.mkdir_p!(Path.dirname(target))
      File.ln_s!(source, target)
    end

    for op <- operations, not Enum.any?(groups, &under?(op.target, &1.target)) do
      Inventory.validate_path!(op.target)
      target = Output.source!(stage, op.target)
      if File.exists?(target), do: raise(Error, "output collision: #{op.target}")
      File.mkdir_p!(Path.dirname(target))

      materialize_file!(op, facts, target, kind)
    end

    for directory <- Map.get(layout, :empty_dirs, []),
        not Enum.any?(groups, &under?(directory, &1.target)),
        do: File.mkdir_p!(Output.source!(stage, directory))

    validate!(layout, facts, stage, kind)
  end

  defp materialize_file!(%{content: content}, _facts, target, _kind) when is_binary(content) do
    File.write!(target, content, [:exclusive])
    File.chmod!(target, 0o644)
  end

  defp materialize_file!(%{sources: [source | _]} = op, facts, target, kind) do
    expected = Facts.stat!(facts, source)
    actual = file_observation!(source)

    unless actual.sha256 == expected.sha256 and actual.mode == expected.mode,
      do: raise(Error, "inputs_changed: #{source}")

    if kind == :live and op.operation == :link_or_copy do
      File.ln_s!(source, target)
    else
      File.cp!(source, target)
      File.chmod!(target, if(Bitwise.band(expected.mode, 0o111) == 0, do: 0o644, else: 0o755))
    end
  end

  def validate!(layout, facts, stage, kind) do
    operations = Map.fetch!(layout, kind)
    groups = if kind == :live, do: Map.get(layout, :live_roots, []), else: []
    links = Map.new(groups, &{&1.target, Path.join(facts.root, &1.source)})

    links =
      for op <- operations,
          kind == :live and op.operation == :link_or_copy and is_nil(op.content),
          not Enum.any?(groups, &under?(op.target, &1.target)),
          into: links,
          do: {op.target, hd(op.sources)}

    physical = physical_paths!(stage, "", links)

    expected =
      (Enum.map(operations, & &1.target)
       |> Enum.reject(fn target -> Enum.any?(groups, &under?(target, &1.target)) end)) ++
        Map.keys(Map.new(groups, &{&1.target, true}))

    unless Enum.sort(physical) == Enum.sort(expected),
      do: raise(Error, "materialized file set differs from plan")

    empty =
      Map.get(layout, :empty_dirs, [])
      |> Enum.reject(fn path -> Enum.any?(groups, &under?(path, &1.target)) end)
      |> Enum.sort()

    unless Enum.sort(empty_directories!(stage, "")) == empty,
      do: raise(Error, "materialized empty directory set differs from plan")

    for op <- operations,
        not Map.has_key?(links, op.target),
        not Enum.any?(groups, &under?(op.target, &1.target)) do
      actual = file_observation!(Path.join(stage, op.target))

      expected =
        if op.content,
          do: %{sha256: Identity.raw(op.content), mode: 0o644},
          else: Facts.stat!(facts, hd(op.sources))

      normalized_mode = if Bitwise.band(expected.mode, 0o111) == 0, do: 0o644, else: 0o755

      unless actual.sha256 == expected.sha256 and actual.mode == normalized_mode,
        do: raise(Error, "materialized bytes or mode differ from plan: #{op.target}")
    end

    for {_target, source} <- links, do: Output.reject_tree_links!(source)

    %{
      linked_files:
        for(
          op <- operations,
          Enum.any?(links, fn {target, _} -> under?(op.target, target) end),
          do: op.target
        ),
      copied_files:
        Enum.map(operations, & &1.target) --
          Enum.filter(Enum.map(operations, & &1.target), fn path ->
            Enum.any?(links, fn {target, _} -> under?(path, target) end)
          end)
    }
  end

  defp physical_paths!(root, relative, links) do
    path = if relative == "", do: root, else: Path.join(root, relative)

    case File.lstat!(path).type do
      :directory ->
        File.ls!(path)
        |> Enum.sort()
        |> Enum.flat_map(&physical_paths!(root, Path.join(relative, &1), links))

      :regular ->
        [relative]

      :symlink ->
        expected = Map.get(links, relative) || raise(Error, "unplanned live link: #{relative}")

        unless Path.expand(File.read_link!(path), Path.dirname(path)) == expected,
          do: raise(Error, "live link differs from plan: #{relative}")

        [relative]

      _ ->
        raise Error, "unsafe materialized entry: #{relative}"
    end
  end

  defp file_observation!(path) do
    case File.lstat!(path) do
      %{type: :regular, mode: mode} ->
        %{sha256: Hash.sha256_file(path), mode: Bitwise.band(mode, 0o777)}

      _ ->
        raise Error, "expected regular source: #{path}"
    end
  end

  defp empty_directories!(root, relative) do
    path = if relative == "", do: root, else: Path.join(root, relative)

    case File.lstat!(path).type do
      :directory ->
        case File.ls!(path) |> Enum.sort() do
          [] -> if relative == "", do: [], else: [relative]
          names -> Enum.flat_map(names, &empty_directories!(root, Path.join(relative, &1)))
        end

      _ ->
        []
    end
  end

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
