defmodule Weld.Plan.Inventory do
  @moduledoc false

  alias Weld.{Error, Output, Workspace}
  alias Weld.Layout.FilePlan
  alias Weld.Workspace.Project

  @tooling_files ~w(.formatter.exs .credo.exs .dialyzer_ignore.exs)
  @local_state ~w(.git .weld deps _build .mix_sources.json)

  @type entry :: Weld.Plan.inventory_entry()

  def build(workspace, %{mode: :source_project} = artifact, [project], selected, verification) do
    compiled =
      for member <- selected ++ verification,
          covered?(member.abs_path, project.abs_path),
          path <- normalize_paths(member, member.elixirc_paths ++ member.erlc_paths) do
        Path.relative_to(Path.join(member.abs_path, path), project.abs_path)
      end

    tests = normalize_paths(project, project.test_paths)
    docs = artifact.output.docs
    files = artifact.source_project[:files]

    unless Enum.uniq(files) == files, do: raise(Error, "duplicate source inventory path")

    roots =
      for path <- files do
        Output.source!(project.abs_path, path)
        kind = source_kind(path, compiled, tests, docs)
        entry!(workspace, checkout_path(project, path), path, kind)
      end

    inventory =
      workspace
      |> expand(roots)
      |> Enum.map(fn file ->
        kind = source_kind(file.target, compiled, tests, docs)
        %{file | kind: kind}
      end)

    {order(roots), order(inventory)}
  end

  def build(_workspace, %{mode: :source_project}, [], _selected, _verify), do: {[], []}

  def build(workspace, artifact, _source, selected, verification) do
    tests? = artifact.mode == :monolith or artifact.verify.component_tests

    components =
      Enum.flat_map(selected, &component_roots(workspace, artifact.mode, &1, tests?, false))

    test_support =
      Enum.flat_map(verification, &component_roots(workspace, artifact.mode, &1, tests?, true))

    docs = Enum.map(artifact.output.docs, &entry!(workspace, &1, &1, :docs))
    assets = Enum.map(artifact.output.assets, &entry!(workspace, &1, &1, :runtime))

    tooling =
      for path <- @tooling_files, File.regular?(Path.join(workspace.manifest.repo_root, path)) do
        entry!(workspace, path, path, :metadata)
      end

    artifact_tests =
      artifact.verify.artifact_tests
      |> Enum.with_index(1)
      |> Enum.map(fn {source, index} ->
        target = if artifact.verify.component_tests, do: "test/artifact_#{index}", else: "test"
        entry!(workspace, source, target, :artifact_test)
      end)

    roots = order(components ++ test_support ++ docs ++ assets ++ tooling ++ artifact_tests)
    {roots, workspace |> expand(roots) |> order()}
  end

  def layout_inventory(plan, layout) do
    root = plan.manifest.repo_root

    outputs =
      Enum.map(layout.full, fn op ->
        inputs =
          Enum.map(op.sources, fn source ->
            %{source: Path.relative_to(source, root), owner: owner(plan.workspace, source)}
          end)
          |> Enum.sort_by(& &1.source)

        %{
          target: op.target,
          inputs: inputs,
          kind: op.kind,
          operation: op.operation,
          publish: op.target in layout.package_files,
          generated_digest: if(op.content, do: Weld.Hash.sha256_binary(op.content), else: nil),
          sha256:
            if(op.content,
              do: Weld.Hash.sha256_binary(op.content),
              else: Weld.Hash.sha256_file(hd(op.sources))
            ),
          size: if(op.content, do: byte_size(op.content), else: File.stat!(hd(op.sources)).size),
          executable:
            is_nil(op.content) and Bitwise.band(File.stat!(hd(op.sources)).mode, 0o111) != 0
        }
      end)

    sources =
      for output <- outputs, input <- output.inputs do
        %{
          source: input.source,
          owner: input.owner,
          target: output.target,
          kind: output.kind,
          directory: false,
          operation: output.operation,
          publish: output.publish
        }
      end

    {order(sources), outputs}
  end

  # Preserve projects are initially planned against the source Mix allowlist.
  # The detached probe still verifies that the staged native metadata agrees.
  def preserve_inventory(plan) do
    root = plan.manifest.repo_root
    project = Map.fetch!(plan.workspace.projects, hd(plan.artifact.roots))

    patterns =
      project.package_files ||
        ~w(lib priv .formatter.exs mix.exs README* readme* LICENSE* license* CHANGELOG* changelog* src c_src Makefile)

    published =
      patterns
      |> Enum.flat_map(&Path.wildcard(Path.join(plan.source_root, &1), match_dot: true))
      |> Enum.flat_map(fn path -> if File.dir?(path), do: regular_files!(path), else: [path] end)
      |> Enum.map(&Path.relative_to(&1, plan.source_root))
      |> MapSet.new()

    for entry <- plan.source_inventory do
      observed = Weld.Shell.Files.observe!(root, entry.source)

      Map.merge(observed, %{
        target: entry.target,
        inputs: [%{source: entry.source, owner: entry.owner}],
        kind: entry.kind,
        operation: :link_or_copy,
        publish: MapSet.member?(published, entry.target),
        generated_digest: nil
      })
    end
    |> Weld.Core.Inventory.validate!()
  end

  def covered?(path, root),
    do: root == "." or path == root or String.starts_with?(path, root <> "/")

  def checkout_path(%Project{id: "."}, path), do: path
  def checkout_path(%Project{id: id}, path), do: Path.join(id, path)

  def normalize_paths(project, paths) do
    paths
    |> Enum.map(fn path ->
      absolute = Path.expand(path, project.abs_path)

      unless absolute != project.abs_path and covered?(absolute, project.abs_path) do
        raise Error,
              "project #{project.id} source path escapes its project root: #{inspect(path)}"
      end

      relative = Path.relative_to(absolute, project.abs_path)
      Output.source!(project.abs_path, relative)
      relative
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp component_roots(workspace, :package_projection, project, tests?, verification_only?) do
    compiled = normalize_paths(project, project.elixirc_paths ++ project.erlc_paths)
    includes = normalize_paths(project, [project.erlc_include_path])
    {test_compile, tests} = suite_roots(project, compiled, tests? and not verification_only?)
    roots = collapse_roots(project.copy_dirs ++ compiled ++ includes ++ test_compile ++ tests)
    component = if project.id == ".", do: "root", else: project.id
    declared = compiled ++ includes ++ test_compile ++ tests

    for path <- roots, present_component_path?(project, path, declared) do
      kind = component_kind(path, compiled, tests ++ test_compile, verification_only?)
      target = Path.join(["components", component, path])
      entry!(workspace, checkout_path(project, path), target, kind)
    end
  end

  defp component_roots(workspace, :monolith, project, _tests?, verification_only?) do
    slug = FilePlan.slug(project.id)

    sources =
      for path <- Enum.uniq(project.copy_dirs ++ ["config"]),
          File.dir?(Path.join(project.abs_path, path)) do
        {target, kind} =
          cond do
            path == "config" -> {Path.join(["config/sources", slug]), :metadata}
            verification_only? -> {Path.join(["test/support/weld_projects", slug, path]), :test}
            path in ["lib", "src"] -> {path, :compiled}
            true -> {path, :runtime}
          end

        entry!(workspace, checkout_path(project, path), target, kind)
      end

    tests =
      for path <-
            normalize_paths(
              project,
              project.test_paths ++
                Enum.filter(project.test_elixirc_paths, &(&1 == "test/support"))
            ),
          not verification_only?,
          File.dir?(Path.join(project.abs_path, path)) do
        entry!(workspace, checkout_path(project, path), Path.join("test", slug), :test)
      end

    sources ++ tests
  end

  defp suite_roots(_project, _compiled, false), do: {[], []}

  defp suite_roots(project, compiled, true) do
    test_compile =
      normalize_paths(project, project.test_elixirc_paths ++ project.test_erlc_paths) -- compiled

    {test_compile, normalize_paths(project, project.test_paths)}
  end

  defp collapse_roots(paths) do
    paths
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce([], fn path, current ->
      if Enum.any?(current, &covered?(path, &1)), do: current, else: [path | current]
    end)
  end

  defp component_kind(_path, _compiled, _tests, true), do: :test

  defp component_kind(path, compiled, tests, false) do
    cond do
      path in compiled -> :compiled
      path in tests -> :test
      true -> :runtime
    end
  end

  defp present_component_path?(project, path, declared_paths) do
    cond do
      File.dir?(Path.join(project.abs_path, path)) ->
        true

      path in declared_paths and path not in ~w(lib src include test) ->
        raise Error, "project #{project.id} declared source path not found: #{path}"

      true ->
        false
    end
  end

  defp source_kind(path, compiled, tests, docs) do
    cond do
      Enum.any?(compiled, &covered?(path, &1)) -> :compiled
      Enum.any?(tests, &covered?(path, &1)) -> :test
      Enum.any?(docs, &covered?(path, &1)) or doc_path?(path) -> :docs
      Enum.any?(["priv", "assets", "src", "c_src", "include"], &covered?(path, &1)) -> :runtime
      true -> :metadata
    end
  end

  defp doc_path?(path) do
    Path.extname(path) in [".md", ".livemd"] or Path.basename(path) == "LICENSE"
  end

  defp entry!(workspace, source, target, kind) do
    root = workspace.manifest.repo_root
    absolute = Output.source!(root, source)

    case File.lstat(absolute) do
      {:ok, %{type: type}} when type in [:directory, :regular] ->
        %{
          source: source,
          target: target,
          owner: owner(workspace, absolute),
          kind: kind,
          directory: type == :directory
        }

      _ ->
        raise Error, "source inventory requires existing regular files and directories: #{source}"
    end
  end

  defp expand(workspace, roots), do: Enum.flat_map(roots, &expand_entry(workspace, &1))

  defp expand_entry(workspace, %{directory: true} = entry) do
    absolute = Path.join(workspace.manifest.repo_root, entry.source)

    for source <- regular_files!(absolute) do
      relative = Path.relative_to(source, absolute)

      %{
        entry
        | source: Path.join(entry.source, relative),
          target: Path.join(entry.target, relative),
          owner: owner(workspace, source),
          directory: false
      }
    end
  end

  defp expand_entry(_workspace, entry), do: [entry]

  defp regular_files!(path) do
    path
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      source = Path.join(path, name)

      if name in @local_state, do: raise(Error, "local state in source inventory: #{source}")

      case File.lstat!(source).type do
        :directory -> regular_files!(source)
        :regular -> [source]
        _ -> raise Error, "source inventory requires regular files and directories: #{source}"
      end
    end)
  end

  defp owner(workspace, path) do
    case Workspace.file_owner(workspace, path) do
      {:project, id} -> id
      _ -> nil
    end
  end

  defp order(entries), do: entries |> Enum.uniq() |> Enum.sort_by(&{&1.target, &1.source})
end
