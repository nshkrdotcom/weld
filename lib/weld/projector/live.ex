defmodule Weld.Projector.Live do
  @moduledoc false

  alias Weld.{Hash, Output, Plan}

  @ignored ~w(.git .weld _build deps dist tmp doc)

  # The emitted code uses only Elixir/OTP and Mix. Ordinary linked source bytes
  # are deliberately not digested: they must remain incrementally compilable.
  @spec guard_ast(Plan.t(), keyword()) :: Macro.t()
  def guard_ast(plan, opts \\ []) do
    root = plan.manifest.repo_root
    projects = Plan.projects_for_view(plan, :test)

    metadata =
      [plan.manifest.manifest_path, Path.join(root, "mix.lock")] ++
        Enum.map(~w(.formatter.exs .credo.exs .dialyzer_ignore.exs), &Path.join(root, &1)) ++
        Enum.flat_map(plan.workspace.projects, fn {_id, project} ->
          [Path.join(project.abs_path, "mix.exs"), Path.join(project.abs_path, "mix.lock")]
        end) ++
        Enum.map(plan.structural_inputs, &Path.join(root, &1)) ++
        Keyword.get(opts, :metadata, []) ++ Keyword.get(opts, :digests, [])

    config_projects =
      if plan.artifact.mode == :package_projection, do: plan.selected_projects, else: projects

    config_roots = Enum.map(config_projects, &Path.join(&1.abs_path, "config"))

    metadata =
      metadata ++ Enum.flat_map(config_roots, &regular_files/1)

    checks = metadata |> Enum.uniq() |> Enum.sort() |> Enum.map(&{&1, fingerprint(&1)})

    slots =
      projects
      |> Enum.flat_map(fn project ->
        test_roots =
          if plan.artifact.mode == :package_projection and not Plan.selected?(plan, project.id),
            do: [],
            else: project.test_paths ++ ["config", "test"]

        (project.elixirc_paths ++
           project.erlc_paths ++
           [project.erlc_include_path] ++
           ~w(lib src c_src include priv) ++ test_roots)
        |> Enum.uniq()
        |> Enum.map(&Path.expand(&1, project.abs_path))
      end)
      |> Kernel.++(Keyword.get(opts, :directories, []))
      |> Enum.flat_map(&ancestors(&1, root))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{&1, path_type(&1)})

    topology =
      (config_roots ++ Keyword.get(opts, :topology, []))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{&1, topology(&1)})

    safe_roots =
      Keyword.get(opts, :directories, [])
      |> Enum.uniq()
      |> Enum.sort()

    patterns = discovery_patterns(plan)
    discovered = discover(patterns, root)
    refresh = refresh_command(plan)

    quote do
      weld_refresh = unquote(refresh)

      weld_type = fn path ->
        case File.lstat(path) do
          {:ok, %{type: type}} -> type
          {:error, :enoent} -> :missing
          _ -> :unreadable
        end
      end

      weld_digest = fn path ->
        case File.lstat(path) do
          {:ok, %{type: :regular, mode: mode}} ->
            case File.read(path) do
              {:ok, bytes} ->
                {Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
                 Bitwise.band(mode, 0o111)}

              _ ->
                :unreadable
            end

          {:error, :enoent} ->
            :missing

          _ ->
            :unsafe
        end
      end

      for {path, expected} <- unquote(Macro.escape(checks)) do
        unless weld_digest.(path) == expected, do: Mix.raise(weld_refresh)
      end

      for {path, expected} <- unquote(Macro.escape(slots)) do
        unless weld_type.(path) == expected, do: Mix.raise(weld_refresh)
      end

      weld_walk = fn walk, path ->
        type = weld_type.(path)

        children =
          if type == :directory do
            case File.ls(path) do
              {:ok, names} -> Enum.flat_map(names, &walk.(walk, Path.join(path, &1)))
              _ -> [{path, :unreadable}]
            end
          else
            []
          end

        [{path, type} | children]
      end

      weld_topology = fn path ->
        weld_walk.(weld_walk, path)
        |> Enum.map(fn {entry, type} -> {Path.relative_to(entry, path), type} end)
        |> Enum.sort()
      end

      for {path, expected} <- unquote(Macro.escape(topology)) do
        unless weld_topology.(path) == expected, do: Mix.raise(weld_refresh)
      end

      # New files are welcome in directory-linked views; new symlinks are not.
      for root <- unquote(safe_roots), {_path, type} <- weld_topology.(root) do
        unless type in [:regular, :directory], do: Mix.raise(weld_refresh)
      end

      weld_projects =
        unquote(patterns)
        |> Enum.flat_map(&Path.wildcard(&1, match_dot: false))
        |> Enum.reject(fn path ->
          path
          |> Path.relative_to(unquote(root))
          |> Path.split()
          |> Enum.any?(&(&1 in unquote(@ignored)))
        end)
        |> Enum.filter(&File.regular?/1)
        |> Enum.uniq()
        |> Enum.sort()

      unless weld_projects == unquote(discovered), do: Mix.raise(weld_refresh)
    end
  end

  @spec guard_source(Plan.t(), keyword()) :: String.t()
  def guard_source(plan, opts \\ []), do: plan |> guard_ast(opts) |> Macro.to_string()

  @spec aliases_source() :: String.t()
  def aliases_source do
    """
    [
      "hex.build": fn _ -> Mix.raise("live projections cannot be packaged; generate a full candidate") end,
      "hex.publish": fn _ -> Mix.raise("live projections cannot be packaged; generate a full candidate") end
    ]
    """
  end

  defp refresh_command(plan) do
    "live projection inputs changed; run mix weld.project --artifact " <>
      plan.artifact.id <> " --live " <> inspect(plan.manifest.manifest_path)
  end

  defp discovery_patterns(plan) do
    root = plan.manifest.repo_root

    case plan.workspace.discovery.globs do
      [] -> [Path.join(root, "**/mix.exs")]
      globs -> [Path.join(root, "mix.exs") | Enum.map(globs, &Path.join([root, &1, "mix.exs"]))]
    end
  end

  defp discover(patterns, root) do
    patterns
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: false))
    |> Enum.reject(fn path ->
      path |> Path.relative_to(root) |> Path.split() |> Enum.any?(&(&1 in @ignored))
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp topology(path) do
    walk(path)
    |> Enum.map(fn {entry, type} -> {Path.relative_to(entry, path), type} end)
    |> Enum.sort()
  end

  defp walk(path) do
    type = path_type(path)

    children =
      if type == :directory,
        do: path |> File.ls!() |> Enum.flat_map(&walk(Path.join(path, &1))),
        else: []

    [{path, type} | children]
  end

  defp fingerprint(path) do
    Output.reject_link!(path)

    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> {Hash.sha256_file(path), Bitwise.band(mode, 0o111)}
      {:error, :enoent} -> :missing
      _ -> raise Weld.Error, "invalid live input: #{path}"
    end
  end

  defp path_type(path) do
    case File.lstat(path) do
      {:ok, %{type: type}} -> type
      {:error, :enoent} -> :missing
      _ -> :unreadable
    end
  end

  defp regular_files(path), do: if(File.dir?(path), do: Hash.list_files(path), else: [])

  defp ancestors(path, root) do
    if path == root or not String.starts_with?(path, root <> "/") do
      [path]
    else
      [path | ancestors(Path.dirname(path), root)]
    end
  end
end
