defmodule Weld.Shell.Diff do
  @moduledoc false

  alias Weld.Core.Inventory
  alias Weld.{Error, Hash, Output}

  @operational ~w(_build deps .git .weld doc weld.provenance.json projection.lock.json)

  def compare(plan, path, kind) do
    Output.reject_link!(path)
    unless File.dir?(path), do: raise(Error, "projection does not exist: #{path}")

    root = plan.manifest.repo_root
    expected = plan.output_inventory
    links = if kind == :live, do: planned_links(plan), else: %{}
    expected_paths = MapSet.new(expected, & &1.target)

    entries =
      path
      |> observe("", root, links, expected_paths)
      |> Map.new()

    %{
      artifact: plan.artifact.id,
      kind: kind,
      path: path,
      entries: Inventory.diff(expected, entries)
    }
  end

  defp planned_links(%{artifact: %{mode: :source_project}, output_inventory: entries}) do
    for %{target: target, inputs: [%{source: source} | _]} <- entries,
        Path.basename(target) not in ["mix.exs", "mix.lock"],
        {destination, origin} <- same_suffix_parents(target, source),
        into: %{},
        do: {destination, origin}
  end

  defp planned_links(plan) do
    roots =
      for root <- get_in(plan.layout, [:live_roots]) || [],
          into: %{},
          do: {root.target, root.source}

    for %{operation: :link_or_copy, target: target, inputs: [%{source: source} | _]} <-
          plan.output_inventory,
        into: roots,
        do: {target, source}
  end

  defp same_suffix_parents(target, source) do
    parents =
      with name when name != "." <- Path.dirname(target),
           origin when origin != "." <- Path.dirname(source),
           true <- Path.basename(target) == Path.basename(source) do
        same_suffix_parents(name, origin)
      else
        _ -> []
      end

    [{target, source} | parents]
  end

  defp observe(path, relative, root, links, expected) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        observe_directory(path, relative, root, links, expected)

      {:ok, %{type: :regular} = stat} ->
        fact = %{
          sha256: Hash.sha256_file(path),
          size: stat.size,
          executable: Bitwise.band(stat.mode, 0o111) != 0
        }

        [{relative, fact}]

      {:ok, %{type: :symlink}} ->
        observe_link(path, relative, root, links, expected)

      {:ok, _} ->
        raise Error, "unsupported projection entry: #{relative}"

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file stats", path: path
    end
  end

  defp observe_directory(path, relative, root, links, expected) do
    for name <- File.ls!(path) |> Enum.sort(),
        target = Path.join(relative, name),
        relative != "" or name not in @operational or expected_under?(expected, name),
        entry <- observe(Path.join(path, name), target, root, links, expected),
        do: entry
  end

  defp observe_link(path, relative, root, links, expected) do
    expected_source = Map.get(links, relative)

    if is_nil(expected_source) do
      raise Error, "unexpected projection symlink: #{relative}"
    end

    source = Output.source!(root, expected_source)
    link = Path.expand(File.read_link!(path), Path.dirname(path))

    unless link == source, do: raise(Error, "live link differs from plan: #{relative}")
    observe(source, relative, root, %{}, expected)
  end

  defp expected_under?(expected, name) do
    Enum.any?(expected, &(&1 == name or String.starts_with?(&1, name <> "/")))
  end
end
