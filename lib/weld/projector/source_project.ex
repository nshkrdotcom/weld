defmodule Weld.Projector.SourceProject do
  @moduledoc """
  Materializes an explicitly declared root project. The source Mix file owns
  dependencies, application configuration, package contents and compiler options.
  """

  alias Weld.{Error, Hash, Output}

  def project!(plan, stage, kind) do
    root = plan.manifest.repo_root
    options = plan.artifact.source_project
    files = options[:files]
    lock = if File.regular?(Path.join(root, "mix.lock")), do: ["mix.lock"], else: []
    structural = Enum.uniq(["mix.exs" | lock] ++ options[:structural_inputs])
    project = Map.fetch!(plan.workspace.projects, ".")
    validate_path_deps!(project.deps, root, files)
    inputs = project.elixirc_paths ++ project.erlc_paths ++ project.test_paths

    directories =
      Enum.filter(inputs ++ ["priv", "config", "include"], &File.exists?(Path.expand(&1, root)))

    Enum.each(files, fn file ->
      if file in ~w(weld.provenance.json projection.lock.json .mix_sources.json),
        do: raise(Error, "reserved source inventory path: #{file}")

      path = Output.source!(root, file)
      check_tree!(path)

      if Enum.any?(List.delete(files, file), &covered?(file, &1)),
        do: raise(Error, "overlapping source paths: #{file}")
    end)

    unless Enum.uniq(files) == files, do: raise(Error, "duplicate source inventory path")

    for file <- ["mix.exs" | lock] ++ directories do
      relative = Path.relative_to(Path.expand(file, root), root)

      unless Enum.any?(files, &covered?(relative, &1)),
        do: raise(Error, "source inventory missing #{relative}")
    end

    for file <- structural, do: require_file!(Output.source!(root, file))
    check_modules!(root, project.elixirc_paths)

    copied =
      for relative <- files, reduce: [] do
        acc ->
          source = Output.source!(root, relative)
          target = Path.join(stage, relative)
          File.mkdir_p!(Path.dirname(target))

          cond do
            kind == :full ->
              File.cp_r!(source, target)
              if File.dir?(target), do: Hash.list_files(target) ++ acc, else: [target | acc]

            relative == "mix.exs" ->
              metadata = [
                plan.manifest.manifest_path | Enum.map(structural, &Path.join(root, &1))
              ]

              write_live_mix!(
                source,
                target,
                root,
                Enum.uniq(metadata),
                directories,
                plan.artifact.id
              )

              [target | acc]

            relative == "mix.lock" ->
              File.cp!(source, target)
              [target | acc]

            true ->
              case File.ln_s(source, target) do
                :ok ->
                  acc

                {:error, reason} ->
                  raise Error,
                        "live projection needs a working symlink for #{relative}: #{reason}"
              end
          end
      end

    validate_staging!(stage, if(kind == :live, do: root, else: stage), plan.artifact.package)
    %{copied_files: Enum.sort(copied), package_files: files}
  end

  # Load the staged Mix file in a fresh VM. A process already running inside
  # the source project may have loaded its helpers or its project module.
  defp validate_staging!(stage, compiler_root, package) do
    script = """
    Mix.start()
    Mix.Project.in_project(:weld_projection_probe, ".", [], fn project ->
      config = Mix.Project.config()
      unless {config[:app], config[:version]} == #{inspect({package.otp_app, package.version})},
        do: raise("staged application identity differs from the manifest")

      if function_exported?(project, :application, 0), do: project.application()
      paths = (config[:elixirc_paths] || ["lib"]) ++ (config[:erlc_paths] || ["src"])
      root = #{inspect(compiler_root)}

      for path <- paths do
        absolute = Path.expand(path)
        unless absolute == root or String.starts_with?(absolute, root <> "/"),
          do: raise("compiler input escapes its declared project: " <> absolute)
      end
    end)
    """

    case System.cmd("elixir", ["-e", script],
           cd: stage,
           env: [{"MIX_ENV", Atom.to_string(Mix.env())}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _} -> raise Error, "staged source project failed validation:\n#{output}"
    end
  end

  defp validate_path_deps!(deps, root, files) do
    for dep <- deps, path = dep.opts[:path] do
      absolute = Path.expand(path, root)
      mixfile = Path.relative_to(Path.join(absolute, "mix.exs"), root)

      unless Path.type(path) == :relative and String.starts_with?(absolute, root <> "/") and
               Enum.any?(files, &covered?(mixfile, &1)) do
        raise Error,
              "source-project dependency #{inspect(dep.app)} needs a portable source in the declared inventory"
      end
    end
  end

  defp covered?(file, dir), do: file == dir or String.starts_with?(file, dir <> "/")

  defp require_file!(path) do
    unless File.regular?(path), do: raise(Error, "missing structural input: #{path}")
  end

  defp check_tree!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      {:ok, %{type: :directory}} ->
        Enum.each(File.ls!(path), fn entry ->
          if entry in ~w(.weld .git deps _build .mix_sources.json),
            do: raise(Error, "local state in source inventory: #{path}/#{entry}")

          check_tree!(Path.join(path, entry))
        end)

      _ ->
        raise Error, "source inventory requires existing regular files and directories: #{path}"
    end
  end

  defp check_modules!(root, paths) do
    paths
    |> Enum.flat_map(fn path ->
      Path.wildcard(Path.join([Path.expand(path, root), "**", "*.ex"]))
    end)
    |> Enum.reduce(%{}, fn path, seen ->
      declarations = path |> File.read!() |> Code.string_to_quoted!(file: path) |> modules([])

      Enum.reduce(declarations, seen, fn name, acc ->
        if prior = acc[name],
          do: raise(Error, "duplicate module #{inspect(name)} in #{prior} and #{path}")

        Map.put(acc, name, path)
      end)
    end)
  end

  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, parent) do
    case Enum.all?(parts, &is_atom/1) do
      true ->
        name = if List.first(parts) == :"Elixir", do: tl(parts), else: parent ++ parts
        [Module.concat(name) | modules(body, name)]

      false ->
        raise Error, "dynamic module names are not supported in source-project compiler roots"
    end
  end

  defp modules({:__block__, _, statements}, parent),
    do: Enum.flat_map(statements, &modules(&1, parent))

  defp modules({:quote, _, _}, _parent), do: []

  defp modules({:defmodule, _, _}, _parent),
    do: raise(Error, "dynamic module names are not supported in source-project compiler roots")

  defp modules({_form, _meta, args}, parent) when is_list(args), do: modules(args, parent)
  defp modules({_key, value}, parent), do: modules(value, parent)
  defp modules(list, parent) when is_list(list), do: Enum.flat_map(list, &modules(&1, parent))
  defp modules(_other, _parent), do: []

  defp write_live_mix!(source, target, root, metadata, directories, artifact) do
    checks = Enum.map(metadata, &{&1, Hash.sha256_file(&1)})
    directories = Enum.map(directories, &Path.expand(&1, root))

    refresh =
      "live projection metadata changed; run mix weld.project --artifact #{artifact} --live"

    # Append an override inside the original Mix project module. This keeps
    # lexical helpers, application/0, functions in docs options and Mix.env()
    # branches intact, without loading the Weld library in the consumer.
    override =
      quote do
        defoverridable project: 0

        def project do
          unless Enum.all?(unquote(directories), &File.dir?/1), do: Mix.raise(unquote(refresh))

          Enum.each(unquote(Macro.escape(checks)), fn {path, expected} ->
            with {:ok, bytes} <- File.read(path),
                 digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
                 true <- digest == expected do
              :ok
            else
              _ -> Mix.raise(unquote(refresh))
            end
          end)

          config = super()
          root = unquote(root)

          config =
            Enum.reduce(
              [elixirc_paths: ["lib"], erlc_paths: ["src"], test_paths: ["test"]],
              config,
              fn {key, default}, current ->
                paths = Enum.map(Keyword.get(current, key, default), &Path.expand(&1, root))
                Keyword.put(current, key, paths)
              end
            )

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

    ast =
      source
      |> File.read!()
      |> Code.string_to_quoted!(file: source)
      |> Macro.prewalk(fn
        {:__DIR__, _, context} when is_atom(context) -> root
        node -> node
      end)

    {ast, count} =
      Macro.postwalk(ast, 0, fn
        {:defmodule, meta, [name, [do: body]]} = node, count ->
          if uses_mix_project?(body) do
            wrapped = {:__block__, [], [body, override]}
            {{:defmodule, meta, [name, [do: wrapped]]}, count + 1}
          else
            {node, count}
          end

        node, count ->
          {node, count}
      end)

    unless count == 1, do: raise(Error, "live mode requires exactly one module using Mix.Project")
    File.write!(target, Macro.to_string(ast) <> "\n")
  end

  defp uses_mix_project?({:__block__, _, entries}), do: Enum.any?(entries, &uses_mix_project?/1)
  defp uses_mix_project?({:use, _, [{:__aliases__, _, [:Mix, :Project]}]}), do: true
  defp uses_mix_project?(_other), do: false
end
