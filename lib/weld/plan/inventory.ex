defmodule Weld.Plan.Inventory do
  @moduledoc false

  alias Weld.{Error, Output, Workspace}
  alias Weld.Workspace.Project

  @tooling_files ~w(.formatter.exs .credo.exs .dialyzer_ignore.exs)
  @local_state ~w(.git .weld deps _build .mix_sources.json)

  @type entry :: %{
          source: String.t(),
          target: String.t(),
          owner: String.t() | nil,
          kind: :compiled | :runtime | :test | :docs | :metadata | :artifact_test,
          directory: boolean()
        }

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

  def covered?(path, root),
    do: root == "." or path == root or String.starts_with?(path, root <> "/")

  def checkout_path(%Project{id: "."}, path), do: path
  def checkout_path(%Project{id: id}, path), do: Path.join(id, path)

  def normalize_paths(project, paths) do
    paths
    |> Enum.map(fn path ->
      absolute = Path.expand(path, project.abs_path)

      unless absolute != project.abs_path and covered?(absolute, project.abs_path) do
        raise Error, "project #{project.id} source path escapes its project root: #{inspect(path)}"
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

    include_suite? = tests? and not verification_only?

    test_compile =
      if include_suite? do
        normalize_paths(project, project.test_elixirc_paths ++ project.test_erlc_paths) -- compiled
      else
        []
      end

    tests = if include_suite?, do: normalize_paths(project, project.test_paths), else: []

    roots =
      Enum.uniq(project.copy_dirs ++ compiled ++ includes ++ test_compile ++ tests)
      |> Enum.sort()
      |> Enum.reduce([], fn path, current ->
        if Enum.any?(current, &covered?(path, &1)), do: current, else: [path | current]
      end)

    component = if project.id == ".", do: "root", else: project.id
    declared = compiled ++ includes ++ test_compile ++ tests

    for path <- roots, present_component_path?(project, path, declared) do
      kind =
        cond do
          verification_only? -> :test
          path in compiled -> :compiled
          path in tests or path in test_compile -> :test
          true -> :runtime
        end

      target = Path.join(["components", component, path])
      entry!(workspace, checkout_path(project, path), target, kind)
    end
  end

  defp component_roots(workspace, :monolith, project, _tests?, verification_only?) do
    slug =
      project.id
      |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
      |> String.trim("_")
      |> String.downcase()

    sources =
      for path <- project.copy_dirs do
        {target, kind} =
          cond do
            verification_only? -> {Path.join(["test/support/weld_projects", slug, path]), :test}
            path in ["lib", "src"] -> {path, :compiled}
            true -> {path, :runtime}
          end

        entry!(workspace, checkout_path(project, path), target, kind)
      end

    tests =
      for path <- normalize_paths(project, project.test_paths),
          not verification_only?,
          File.dir?(Path.join(project.abs_path, path)) do
        entry!(workspace, checkout_path(project, path), Path.join("test", slug), :test)
      end

    sources ++ tests
  end

  defp present_component_path?(project, path, declared_paths) do
    cond do
      File.dir?(Path.join(project.abs_path, path)) -> true
      path in declared_paths and path not in ~w(lib src include test) ->
        raise Error, "project #{project.id} declared source path not found: #{path}"

      true -> false
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

  defp expand(workspace, roots) do
    Enum.flat_map(roots, fn entry ->
      if entry.directory do
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
      else
        [entry]
      end
    end)
  end

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
