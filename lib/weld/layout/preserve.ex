defmodule Weld.Layout.Preserve do
  @moduledoc "Native Mix policy compiled to the same operations as components and flat."
  alias Weld.Core.{Facts, Inputs, Modules}
  alias Weld.Error
  alias Weld.Layout.{FilePlan, Live}
  alias Weld.Plan.Inventory
  @reserved ~w(weld.provenance.json projection.lock.json .mix_sources.json doc)

  def plan!(plan) do
    root = plan.source_root
    project = Map.fetch!(plan.workspace.projects, hd(plan.artifact.roots))
    projects = portable_projects!(plan, project)
    required = Enum.flat_map(projects, &required_paths(&1, project))
    roots = plan.source_roots

    validate_inventory!(
      plan.facts,
      plan.manifest.repo_root,
      root,
      roots,
      Enum.map(roots, & &1.target),
      required
    )

    Enum.flat_map(projects, &compiler_paths(&1, project))
    |> Enum.flat_map(&Facts.list_files(plan.facts, &1))
    |> Enum.uniq()
    |> Enum.filter(&(Path.extname(&1) == ".ex"))
    |> Enum.map(&{&1, Facts.read!(plan.facts, &1)})
    |> Modules.validate_module_sources!()

    outputs = Inventory.preserve_inventory(plan)

    for entry <- Inputs.mapped(plan) do
      unless Enum.any?(outputs, &(&1.target == entry.target and &1.publish == entry.publish)),
        do:
          raise(
            Error,
            "preserve inventory does not cover declared target/publication: #{entry.target}"
          )
    end

    full =
      for entry <- outputs do
        source = Path.join(plan.manifest.repo_root, hd(entry.inputs).source)

        operation =
          if entry.kind in [:compiled, :test] and
               hd(entry.inputs).source not in plan.structural_inputs and
               not Enum.any?(Path.split(entry.target), &(&1 in ~w(c_src priv config))),
             do: :link_or_copy,
             else: :copy

        FilePlan.copy(source, entry.target, entry.kind, operation)
      end

    full = FilePlan.validate!(full)

    groups =
      for entry <- roots,
          entry.directory,
          children = Enum.filter(full, &covered?(&1.target, entry.target)),
          children != [],
          Enum.all?(children, &(&1.operation == :link_or_copy)),
          do: entry

    links =
      for op <- full,
          op.operation == :link_or_copy,
          not Enum.any?(groups, &covered?(op.target, &1.target)),
          do: {op.target, Path.relative_to(hd(op.sources), plan.manifest.repo_root)}

    links = links ++ Enum.map(groups, &{&1.target, &1.source})

    guard =
      Live.guard_ast(plan,
        directories: Enum.map(groups, &Path.join(plan.manifest.repo_root, &1.source)),
        digests: for(op <- full, op.operation != :link_or_copy, source <- op.sources, do: source),
        links: links
      )

    mix = Facts.read!(plan.facts, Path.join(root, "mix.exs"))

    {live_mix, live_error} =
      try do
        {Live.native_mix!(mix, guard, Enum.map(links, &elem(&1, 0))), nil}
      rescue
        error in Error -> {nil, Exception.message(error)}
      end

    live =
      Enum.map(full, fn
        %{target: "mix.exs"} when is_binary(live_mix) ->
          FilePlan.generated("mix.exs", live_mix, :metadata, [
            Path.join(root, "mix.exs")
            | Enum.map(plan.structural_inputs, &Path.join(plan.manifest.repo_root, &1))
          ])

        op ->
          op
      end)

    %{
      full: full,
      live: FilePlan.validate!(live),
      live_error: live_error,
      live_roots: groups,
      package_files: for(entry <- outputs, entry.publish, do: entry.target),
      package_patterns: project.package_files,
      empty_dirs:
        for(
          entry <- roots,
          entry.directory,
          dir <- Facts.empty_dirs(plan.facts, Path.join(plan.manifest.repo_root, entry.source)),
          do: Path.join(entry.target, dir)
        ),
      native_projects: projects,
      config_warnings: []
    }
  end

  defp validate_inventory!(facts, checkout, root, roots, targets, required) do
    unless Enum.uniq(targets) == targets, do: raise(Error, "duplicate source inventory path")

    for entry <- roots do
      relative = entry.target

      if hd(Path.split(relative)) in @reserved,
        do: raise(Error, "reserved source inventory path: #{relative}")

      Facts.source!(facts, checkout, entry.source) |> then(&Facts.reject_tree_links!(facts, &1))

      if Enum.any?(List.delete(targets, relative), &covered?(relative, &1)),
        do: raise(Error, "overlapping source paths: #{relative}")
    end

    for path <- Enum.uniq(required) do
      relative = Path.relative_to(path, root)

      unless Enum.any?(targets, &covered?(relative, &1)),
        do: raise(Error, "source inventory missing #{relative}")
    end
  end

  defp required_paths(project, selected) do
    fields =
      ["mix.exs", "mix.lock", "priv", "config", project.erlc_include_path, "c_src"] ++
        if(project.id == selected.id, do: project.test_paths, else: [])

    (fields
     |> Enum.map(&Path.expand(&1, project.abs_path))
     |> Enum.filter(&Facts.exists?(project.facts, &1))) ++
      compiler_paths(project, selected)
  end

  defp compiler_paths(project, selected) do
    test_paths =
      if project.id == selected.id,
        do: project.test_elixirc_paths ++ project.test_erlc_paths,
        else: []

    for relative <- Enum.uniq(project.elixirc_paths ++ project.erlc_paths ++ test_paths),
        path = Path.expand(relative, project.abs_path),
        compiler_path?(project, relative, path),
        do: path
  end

  defp compiler_path?(project, relative, path) do
    cond do
      Facts.dir?(project.facts, path) -> true
      relative in ["lib", "src"] and not Facts.exists?(project.facts, path) -> false
      true -> raise Error, "#{project.id} compiler input is missing: #{relative}"
    end
  end

  defp portable_projects!(plan, project) do
    by_path = Map.new(plan.workspace.projects, fn {_id, member} -> {member.abs_path, member} end)

    collect_path_projects!([project], by_path, project.abs_path, %{})
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp collect_path_projects!([], _by_path, _root, projects), do: projects

  defp collect_path_projects!([project | rest], by_path, root, projects) do
    if Map.has_key?(projects, project.id) do
      collect_path_projects!(rest, by_path, root, projects)
    else
      dependencies = portable_path_dependencies!(project, by_path, root)

      collect_path_projects!(
        rest ++ dependencies,
        by_path,
        root,
        Map.put(projects, project.id, project)
      )
    end
  end

  defp portable_path_dependencies!(project, by_path, root) do
    for dependency <- project.deps, path = dependency.opts[:path] do
      portable_path_dependency!(dependency, path, project, by_path, root)
    end
  end

  defp portable_path_dependency!(dependency, path, project, by_path, root) do
    absolute = Path.expand(path, project.abs_path)

    with true <- Path.type(path) == :relative and covered?(absolute, root),
         %{app: app} = member when app == dependency.app <- Map.get(by_path, absolute) do
      member
    else
      _ ->
        raise Error,
              "source-project dependency #{inspect(dependency.app)} needs portable source in inventory"
    end
  end

  defp covered?(file, dir), do: file == dir or String.starts_with?(file, dir <> "/")
end
