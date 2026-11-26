defmodule Weld.Shell.Inputs do
  @moduledoc false
  alias Weld.{Error, Output}
  alias Weld.Core.Inventory
  alias Weld.Shell.Files

  # Observe typed declarations once. The pattern itself remains in the watch
  # even when an optional input is absent, so later additions change identity.
  def observe!(root, declaration) do
    pattern = declaration[:path]
    Inventory.validate_path!(pattern)
    absolute = Output.source!(root, pattern)

    paths =
      case declaration[:type] do
        :file ->
          if File.regular?(absolute), do: [absolute], else: []

        :tree ->
          if File.dir?(absolute), do: files_in!(absolute), else: []

        :glob ->
          Path.wildcard(absolute, match_dot: true)
          |> Enum.flat_map(fn path ->
            Output.reject_link!(path)
            if File.dir?(path), do: files_in!(path), else: [path]
          end)
      end

    if paths == [] and declaration[:required] and
         not (declaration[:type] == :tree and File.dir?(absolute)),
       do: raise(Error, "missing declared input: #{pattern}")

    entries =
      paths
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn relative ->
        Files.observe!(root, relative) || raise(Error, "missing input: #{relative}")
      end)

    %{
      pattern: pattern,
      type: declaration[:type],
      required: declaration[:required],
      entries: entries
    }
  end

  defp files_in!(path) do
    {files, _empty} = Files.tree!(path)
    Enum.map(files, &Path.join(path, &1.target))
  end

  def collect!(plan) do
    root = plan.manifest.repo_root
    artifact_watches = Enum.map(plan.artifact.inputs, &watch(root, ".", &1))

    preserve_watches =
      if plan.source_root do
        Enum.map(
          plan.artifact.source_project[:inputs] || [],
          &watch(root, hd(plan.artifact.roots), &1)
        )
      else
        []
      end

    ids = Enum.uniq(plan.selected_ids ++ plan.verification_ids ++ plan.artifact.external_projects)

    project_watches =
      for id <- ids, declaration <- Map.get(plan.manifest.project_inputs, id, []) do
        watch(root, id, declaration)
      end

    Enum.sort_by(
      artifact_watches ++ preserve_watches ++ project_watches,
      &{&1.owner, &1.pattern, &1.type}
    )
  end

  defp watch(root, id, declaration) do
    local = if id == ".", do: root, else: Output.source!(root, id)
    observe!(local, declaration) |> Map.merge(%{owner: id, declaration: declaration})
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

      target =
        case plan.artifact.mode do
          :package_projection ->
            Path.join([
              "components",
              if(watch.owner == ".", do: "root", else: watch.owner),
              entry.target
            ])

          :monolith ->
            entry.target

          :source_project ->
            Path.relative_to(Path.join(plan.manifest.repo_root, source), plan.source_root)
        end

      roles = watch.declaration[:roles]

      kind =
        cond do
          :native in roles -> :native
          :compiled in roles -> :compiled
          :runtime in roles -> :runtime
          :docs in roles -> :docs
          :test in roles -> :test
          true -> :metadata
        end

      %{
        source: source,
        target: Inventory.validate_path!(target),
        owner: watch.owner,
        roles: roles,
        kind: kind,
        directory: false,
        publish: watch.declaration[:publish]
      }
    end
  end

  def add_operations!(plan, operations) do
    Enum.reduce(mapped(plan), operations, fn entry, acc ->
      source = Path.join(plan.manifest.repo_root, entry.source)

      case Enum.find(acc, &(&1.target == entry.target)) do
        nil ->
          acc ++ [Weld.Layout.FilePlan.copy(source, entry.target, entry.kind)]

        %{sources: sources, content: nil} ->
          if source in sources,
            do: acc,
            else: raise(Error, "declared input collision at #{entry.target}")

        _ ->
          raise Error, "declared input collides with generated file: #{entry.target}"
      end
    end)
  end

  def publication_files(plan, paths, patterns) do
    overrides = Map.new(mapped(plan), &{&1.target, &1.publish})
    # Derive an exact list, not a second directory allowlist. Explicit role
    # declarations override inferred publication membership.
    paths
    |> Enum.uniq()
    |> Enum.filter(fn path ->
      Map.get(overrides, path, Enum.any?(patterns, &Weld.Plan.Inventory.covered?(path, &1)))
    end)
    |> Enum.sort()
  end
end
