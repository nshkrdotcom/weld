defmodule Weld.Core.Inputs do
  @moduledoc false
  alias Weld.Core.Inventory
  alias Weld.Error
  alias Weld.Core.Facts
  alias Weld.Layout.FilePlan

  # Observe typed declarations once. The pattern itself remains in the watch
  # even when an optional input is absent, so later additions change identity.
  def observe!(facts, root, declaration) do
    pattern = declaration[:path]
    Inventory.validate_path!(pattern)
    absolute = Facts.source!(facts, root, pattern)

    type = declaration[:type]
    observed_type = Facts.type(facts, absolute)
    expected_type = %{file: :regular, tree: :directory}[type]
    if expected_type && observed_type not in [expected_type, :missing],
      do: raise(Error, "declared input type mismatch for #{pattern}: expected #{type}, observed #{observed_type}")
    paths = matching_paths(facts, type, absolute)

    if declaration[:required] and missing_paths?(facts, type, paths, absolute),
      do: raise(Error, "missing declared input: #{pattern}")

    entries =
      paths
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn relative ->
        observation(facts, root, relative)
      end)

    %{
      pattern: pattern,
      type: declaration[:type],
      required: declaration[:required],
      topology: Enum.map(paths, fn path -> {path, Facts.type(facts, path)} end),
      entries: entries
    }
  end

  defp observation(facts, root, relative) do
    node = Facts.stat!(facts, Path.join(root, relative))
    unless node.type == :regular, do: raise(Error, "unsafe input: #{relative}")
    %{target: relative, sha256: node.sha256, size: node.size,
      mode: node.mode, executable: Bitwise.band(node.mode, 0o111) != 0}
  end

  defp matching_paths(facts, :file, path), do: if(Facts.regular?(facts, path), do: [path], else: [])
  defp matching_paths(facts, :tree, path), do: Facts.list_files(facts, path)
  defp matching_paths(facts, :glob, pattern) do
    facts |> Facts.wildcard(pattern) |> Enum.flat_map(fn path ->
      Facts.reject_tree_links!(facts, path)
      if Facts.dir?(facts, path), do: Facts.list_files(facts, path), else: [path]
    end)
  end
  defp missing_paths?(facts, :tree, [], path), do: not Facts.dir?(facts, path)
  defp missing_paths?(_facts, _type, paths, _path), do: paths == []

  def collect(plan) do
    root = plan.manifest.repo_root
    artifact_watches = Enum.map(plan.artifact.inputs, &watch(plan.facts, root, ".", &1))

    preserve_watches =
      if plan.source_root do
        Enum.map(
          plan.artifact.source_project[:inputs] || [],
          &watch(plan.facts, root, hd(plan.artifact.roots), &1)
        )
      else
        []
      end

    ids = Enum.uniq(plan.selected_ids ++ plan.verification_ids ++ plan.artifact.external_projects)

    project_watches =
      for id <- ids, declaration <- Map.get(plan.manifest.project_inputs, id, []) do
        watch(plan.facts, root, id, declaration)
      end

    Enum.sort_by(
      artifact_watches ++ preserve_watches ++ project_watches,
      &{&1.owner, &1.pattern, &1.type}
    )
  end

  defp watch(facts, root, id, declaration) do
    local = if id == ".", do: root, else: Facts.source!(facts, root, id)
    observe!(facts, local, declaration) |> Map.merge(%{owner: id, declaration: declaration})
  end

  def sources(watches) do
    for watch <- watches, entry <- watch.entries do
      if watch.owner == ".", do: entry.target, else: Path.join(watch.owner, entry.target)
    end
    |> Enum.uniq()
    |> Enum.sort()
  end

  def mapped(plan) do
    for watch <- plan.input_watches,
        watch.declaration[:target] == :relative,
        watch.owner in (plan.selected_ids ++ plan.verification_ids),
        entry <- watch.entries do
      source = if watch.owner == ".", do: entry.target, else: Path.join(watch.owner, entry.target)

      target = mapped_target(plan, watch.owner, entry.target, source)
      roles = watch.declaration[:roles]

      %{
        source: source,
        target: Inventory.validate_path!(target),
        owner: watch.owner,
        roles: roles,
        kind: role_kind(roles),
        directory: false,
        publish: watch.declaration[:publish]
      }
    end
  end

  defp mapped_target(%{artifact: %{mode: :package_projection}}, owner, target, _source) do
    Path.join(["components", if(owner == ".", do: "root", else: owner), target])
  end

  defp mapped_target(%{artifact: %{mode: :monolith}}, _owner, target, _source), do: target

  defp mapped_target(plan, _owner, _target, source) do
    Path.relative_to(Path.join(plan.manifest.repo_root, source), plan.source_root)
  end

  defp role_kind(roles),
    do: if(:compile in roles, do: :compiled, else: Enum.find([:native, :runtime, :docs, :test], :metadata, &(&1 in roles)))

  def add_operations!(plan, operations) do
    Enum.reduce(mapped(plan), operations, &add_operation!(plan.manifest.repo_root, &1, &2))
  end

  defp add_operation!(root, entry, operations) do
    source = Path.join(root, entry.source)

    case Enum.find(operations, &(&1.target == entry.target)) do
      nil ->
        mutable = Enum.any?(entry.roles, &(&1 in [:native, :metadata, :lock, :structure, :generation]))
        operations ++ [FilePlan.copy(source, entry.target, entry.kind, if(mutable, do: :copy, else: :link_or_copy))]

      %{sources: sources, content: nil} ->
        unless source in sources, do: raise(Error, "declared input collision at #{entry.target}")
        operations

      _ ->
        raise Error, "declared input collides with generated file: #{entry.target}"
    end
  end

  def publication_files(plan, paths, patterns) do
    overrides = Map.new(mapped(plan), &{&1.target, &1.publish})
    # Derive an exact list, not a second directory allowlist. Explicit role
    # declarations override inferred publication membership.
    paths
    |> Enum.uniq()
    |> Enum.filter(fn path ->
      Map.get(overrides, path, Enum.any?(patterns, &(path == &1 or String.starts_with?(path, &1 <> "/"))))
    end)
    |> Enum.sort()
  end
end
