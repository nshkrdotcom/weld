defmodule Weld.Projector.SourceProject do
  @moduledoc """
  Materializes one existing Mix project from the workspace. Its Mix file owns
  dependencies, application configuration, package contents and compiler options.
  """

  alias Weld.{Error, Hash, Output}
  alias Weld.Projector.Live
  alias Weld.Shell.Runner

  @hex_default_files ~w(lib priv .formatter.exs mix.exs README* readme* LICENSE* license*
                        CHANGELOG* changelog* src c_src Makefile)
  @reserved ~w(weld.provenance.json projection.lock.json .mix_sources.json doc)

  def project!(plan, stage, kind) do
    root = plan.source_root
    [project_id] = plan.artifact.roots
    project = Map.fetch!(plan.workspace.projects, project_id)
    roots = plan.source_roots
    targets = Enum.map(roots, & &1.target)
    projects = portable_projects!(plan, project)

    required = Enum.flat_map(projects, &required_paths(&1, project))
    compiler_roots = Enum.flat_map(projects, &compiler_paths(&1, project))

    validate_inventory!(plan.manifest.repo_root, root, roots, targets, required)
    validate_modules!(compiler_roots)

    verification_files = plan.source_inventory |> Enum.map(& &1.target) |> Enum.sort()
    live_copies = live_copies(verification_files, projects, root)

    for entry <- roots do
      source = Output.source!(plan.manifest.repo_root, entry.source)
      target = Path.join(stage, entry.target)
      File.mkdir_p!(Path.dirname(target))
      materialize!(kind, entry.target, source, target, live_copies)
    end

    # Evaluate the unmodified Mix file against the staged inventory first.
    # Even a live view must not depend on unlisted checkout helpers.
    validate_staging!(stage, stage, root, projects)
    package_files = package_files!(project, root, stage)

    linked_files =
      if kind == :live do
        source_paths = Enum.map(roots, &Path.join(plan.manifest.repo_root, &1.source))

        guard = Live.guard_ast(plan, directories: source_paths)

        write_live_mix!(
          Path.join(root, "mix.exs"),
          Path.join(stage, "mix.exs"),
          root,
          guard,
          linked_roots(stage, stage)
        )

        validate_staging!(stage, root, root, [project])

        verification_files -- live_copies
      else
        []
      end

    %{
      copied_files: Enum.map(verification_files -- linked_files, &Path.join(stage, &1)),
      linked_files: linked_files,
      package_files: package_files,
      package_patterns: project.package_files || @hex_default_files,
      verification_files: verification_files
    }
  end

  defp validate_inventory!(checkout, root, roots, targets, required) do
    unless Enum.uniq(targets) == targets, do: raise(Error, "duplicate source inventory path")

    for entry <- roots do
      relative = entry.target

      if hd(Path.split(relative)) in @reserved,
        do: raise(Error, "reserved source inventory path: #{relative}")

      checkout |> Output.source!(entry.source) |> check_tree!()

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

    (fields |> Enum.map(&Path.expand(&1, project.abs_path)) |> Enum.filter(&File.exists?/1)) ++
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
      File.dir?(path) -> true
      relative in ["lib", "src"] and not File.exists?(path) -> false
      true -> raise Error, "#{project.id} compiler input is missing: #{relative}"
    end
  end

  defp live_copies(files, projects, root) do
    inventory = MapSet.new(files)

    locks =
      for file <- files,
          Path.basename(file) == "mix.lock",
          Path.join(Path.dirname(file), "mix.exs") in inventory,
          do: file

    # Give genuine path dependencies their own directories so their relative
    # Mix imports resolve through the staged project rather than a source link.
    mixfiles =
      Enum.map(projects, fn project ->
        Path.join(project.abs_path, "mix.exs") |> Path.relative_to(root)
      end)

    Enum.uniq(["mix.lock" | mixfiles] ++ locks)
  end

  defp materialize!(:full, _relative, source, target, _copies), do: File.cp_r!(source, target)

  defp materialize!(:live, relative, source, target, copies) do
    cond do
      relative in copies ->
        File.cp!(source, target)

      Enum.any?(copies, &covered?(&1, relative)) ->
        File.mkdir!(target)

        for child <- File.ls!(source) do
          materialize!(
            :live,
            Path.join(relative, child),
            Path.join(source, child),
            Path.join(target, child),
            copies
          )
        end

      true ->
        link!(relative, source, target)
    end
  end

  defp link!(relative, source, target) do
    case File.ln_s(source, target) do
      :ok ->
        :ok

      {:error, reason} ->
        raise Error, "live projection needs a working symlink for #{relative}: #{reason}"
    end
  end

  # Load the staged Mix file in a fresh VM. A process already running inside
  # the source project may have loaded its helpers or its project module.
  defp validate_staging!(stage, compiler_root, source_root, projects) do
    targets =
      for project <- projects do
        relative = Path.relative_to(project.abs_path, source_root)
        {relative, {project.app, project.version, project.package_name}}
      end

    script = """
    Mix.start()
    root = #{inspect(compiler_root)}
    generated_root = #{inspect(stage)}
    for {relative, {app, _, _} = expected} <- #{inspect(targets, limit: :infinity)} do
      Mix.Project.in_project(app, relative, [], fn project ->
        config = Mix.Project.config()
        package = config[:package] || []
        identity = {config[:app], config[:version], to_string(package[:name] || config[:app])}
        unless identity == expected,
          do: raise("staged application identity differs from the source")

        if function_exported?(project, :application, 0), do: project.application()
        docs = config[:docs] || []
        mutable_paths = [
          config[:build_path] || "_build",
          config[:deps_path] || "deps",
          config[:lockfile] || "mix.lock",
          if(is_list(docs), do: docs[:output] || "doc", else: "doc")
        ]

        for path <- mutable_paths do
          absolute = Path.expand(path)
          unless String.starts_with?(absolute, generated_root <> "/"),
            do: raise("mutable path escapes staged source project: " <> path)

          absolute
          |> Path.relative_to(generated_root)
          |> Path.split()
          |> Enum.reduce(generated_root, fn part, parent ->
            child = Path.join(parent, part)
            if match?({:ok, %{type: :symlink}}, File.lstat(child)),
              do: raise("mutable path overlaps linked source: " <> path)
            child
          end)
        end

        paths =
          List.wrap(config[:elixirc_paths] || ["lib"]) ++
            List.wrap(config[:erlc_paths] || ["src"]) ++
            List.wrap(config[:test_paths] || ["test"]) ++
            List.wrap(config[:erlc_include_path])

        for path <- paths do
          absolute = Path.expand(path)
          unless absolute == root or String.starts_with?(absolute, root <> "/"),
            do: raise("compiler input escapes its declared project: " <> absolute)
        end
      end)
    end
    """

    case Runner.run!("elixir", ["-e", script],
           cd: stage,
           env: [{"MIX_ENV", Atom.to_string(Mix.env())}],
           seconds: 30
         ) do
      {_output, 0} -> :ok
      {output, _} -> raise Error, "staged source project failed validation:\n#{output}"
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

  defp package_files!(project, root, stage) do
    (project.package_files || @hex_default_files)
    |> Enum.flat_map(&native_package_pattern!(&1, root, stage))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp native_package_pattern!(pattern, root, stage) do
    if Path.type(pattern) != :relative or ".." in Path.split(pattern),
      do: raise(Error, "unsafe native package path: #{pattern}")

    for source <- Path.wildcard(Path.join(root, pattern), match_dot: true) do
      validate_native_package_source!(source, root, stage)
      Path.relative_to(source, root)
    end
  end

  defp validate_native_package_source!(source, root, stage) do
    check_tree!(source)
    members = if File.dir?(source), do: Hash.list_files(source), else: [source]
    Enum.each(members, &validate_native_package_member!(&1, root, stage))
  end

  defp validate_native_package_member!(member, root, stage) do
    relative = Path.relative_to(member, root)
    target = Path.join(stage, relative)

    unless File.regular?(target) and Hash.sha256_file(member) == Hash.sha256_file(target),
      do: raise(Error, "source inventory missing native package path #{relative}")
  end

  defp covered?(file, dir), do: file == dir or String.starts_with?(file, dir <> "/")

  defp check_tree!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, %{type: :directory}} ->
        Enum.each(File.ls!(path), &check_entry!(path, &1))

      _ ->
        raise Error, "source inventory requires existing regular files and directories: #{path}"
    end
  end

  defp check_entry!(path, entry) do
    if entry in ~w(.weld .git deps _build .mix_sources.json),
      do: raise(Error, "local state in source inventory: #{path}/#{entry}")

    check_tree!(Path.join(path, entry))
  end

  @doc false
  def validate_modules!(paths) do
    paths
    |> Enum.flat_map(fn path ->
      Path.wildcard(Path.join([path, "**", "*.ex"]))
    end)
    |> Enum.uniq()
    |> Enum.map(&{&1, File.read!(&1)})
    |> validate_module_sources!()
  end

  @doc false
  def validate_module_sources!(sources) do
    Enum.reduce(sources, %{}, fn {path, contents}, seen ->
      declarations = contents |> Code.string_to_quoted!(file: path) |> modules([])
      Enum.reduce(declarations, seen, &register_module!(&2, &1, path))
    end)
  end

  defp register_module!(seen, name, path) do
    if prior = seen[name],
      do: raise(Error, "duplicate module #{inspect(name)} in #{prior} and #{path}")

    Map.put(seen, name, path)
  end

  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, parent) do
    case Enum.all?(parts, &is_atom/1) do
      true ->
        name = if List.first(parts) == :"Elixir", do: tl(parts), else: parent ++ parts
        [Module.concat(name) | modules(body, name)]

      false ->
        raise Error, "dynamic module names are not supported in projection compiler roots"
    end
  end

  defp modules({:__block__, _, statements}, parent),
    do: Enum.flat_map(statements, &modules(&1, parent))

  defp modules({:quote, _, _}, _parent), do: []

  defp modules({:defmodule, _, _}, _parent),
    do: raise(Error, "dynamic module names are not supported in projection compiler roots")

  defp modules({_form, _meta, args}, parent) when is_list(args), do: modules(args, parent)
  defp modules({_key, value}, parent), do: modules(value, parent)
  defp modules(list, parent) when is_list(list), do: Enum.flat_map(list, &modules(&1, parent))
  defp modules(_other, _parent), do: []

  defp linked_roots(path, root) do
    case File.lstat!(path).type do
      :symlink -> [Path.relative_to(path, root)]
      :directory -> Enum.flat_map(File.ls!(path), &linked_roots(Path.join(path, &1), root))
      _ -> []
    end
  end

  defp write_live_mix!(source, target, root, guard, links) do
    override = live_override_ast(root, guard, links)

    ast =
      source
      |> File.read!()
      |> Code.string_to_quoted!(file: source)
      |> Macro.prewalk(fn
        {:__DIR__, _, context} when is_atom(context) -> root
        node -> node
      end)

    {ast, count} = Macro.postwalk(ast, 0, &append_live_override(&1, &2, override))
    unless count == 1, do: raise(Error, "live mode requires exactly one module using Mix.Project")
    File.write!(target, Macro.to_string(ast) <> "\n")
  end

  defp append_live_override({:defmodule, meta, [name, [do: body]]} = node, count, override) do
    if uses_mix_project?(body) do
      wrapped = {:__block__, [], [body, override]}
      {{:defmodule, meta, [name, [do: wrapped]]}, count + 1}
    else
      {node, count}
    end
  end

  defp append_live_override(node, count, _override), do: {node, count}

  defp live_override_ast(root, guard, links) do
    quote do
      defoverridable project: 0

      def project do
        unquote(guard)
        config = super()
        root = unquote(root)
        generated_root = __DIR__
        mutable_paths = unquote(mutable_paths_ast()).(config)
        validate_mutable = unquote(mutable_validator_ast(links))
        Enum.each(mutable_paths, &validate_mutable.(&1, generated_root))
        rewrite_paths = unquote(compiler_paths_ast())
        config = rewrite_paths.(config, root)

        reject = fn _args ->
          Mix.raise("live projections cannot be packaged; generate a full candidate")
        end

        aliases =
          Keyword.merge(config[:aliases] || [], "hex.build": reject, "hex.publish": reject)

        config
        |> Keyword.put(
          :erlc_include_path,
          Path.expand(config[:erlc_include_path] || "include", root)
        )
        |> Keyword.put(:aliases, aliases)
      end
    end
  end

  defp mutable_paths_ast do
    quote do
      fn config ->
        docs = config[:docs] || []

        [
          config[:build_path] || "_build",
          config[:deps_path] || "deps",
          config[:lockfile] || "mix.lock",
          if(is_list(docs), do: docs[:output] || "doc", else: "doc")
        ]
      end
    end
  end

  defp mutable_validator_ast(links) do
    quote do
      fn path, generated_root ->
        absolute = Path.expand(path, generated_root)

        unless String.starts_with?(absolute, generated_root <> "/"),
          do: Mix.raise("live source project mutable path escapes its generated root: " <> path)

        validate_ancestors = unquote(mutable_ancestors_ast())
        validate_ancestors.(absolute, generated_root, path)
        overlaps = unquote(link_overlap_ast())

        if Enum.any?(unquote(links), &overlaps.(&1, absolute, generated_root)),
          do: Mix.raise("live source project mutable path contains linked source: " <> path)
      end
    end
  end

  defp mutable_ancestors_ast do
    quote do
      fn absolute, generated_root, path ->
        validate_link = unquote(mutable_link_ast())

        absolute
        |> Path.relative_to(generated_root)
        |> Path.split()
        |> Enum.scan(generated_root, &Path.join(&2, &1))
        |> Enum.each(&validate_link.(&1, path))
      end
    end
  end

  defp mutable_link_ast do
    quote do
      fn child, path ->
        if match?({:ok, %{type: :symlink}}, File.lstat(child)),
          do: Mix.raise("live source project mutable path overlaps linked source: " <> path)
      end
    end
  end

  defp link_overlap_ast do
    quote do
      fn relative, absolute, generated_root ->
        linked = Path.expand(relative, generated_root)

        linked == absolute or String.starts_with?(linked, absolute <> "/") or
          String.starts_with?(absolute, linked <> "/")
      end
    end
  end

  defp compiler_paths_ast do
    quote do
      fn config, root ->
        Enum.reduce(
          [elixirc_paths: ["lib"], erlc_paths: ["src"], test_paths: ["test"]],
          config,
          fn {key, default}, current ->
            paths =
              current
              |> Keyword.get(key, default)
              |> List.wrap()
              |> Enum.map(&Path.expand(&1, root))

            Keyword.put(current, key, paths)
          end
        )
      end
    end
  end

  defp uses_mix_project?({:__block__, _, entries}), do: Enum.any?(entries, &uses_mix_project?/1)
  defp uses_mix_project?({:use, _, [{:__aliases__, _, [:Mix, :Project]}]}), do: true
  defp uses_mix_project?(_other), do: false
end
