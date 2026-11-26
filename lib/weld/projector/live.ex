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

    config_projects =
      if plan.artifact.mode == :package_projection, do: plan.selected_projects, else: projects

    config_roots = Enum.map(config_projects, &Path.join(&1.abs_path, "config"))
    patterns = discovery_patterns(plan)

    guard_code(%{
      checks: metadata_checks(plan, config_roots, opts, root),
      slots: slot_checks(plan, projects, opts, root),
      topology: topology_checks(config_roots, opts),
      safe_roots: opts |> Keyword.get(:directories, []) |> Enum.uniq() |> Enum.sort(),
      patterns: patterns,
      discovered: discover(patterns, root),
      root: root,
      refresh: refresh_command(plan)
    })
  end

  defp metadata_checks(plan, config_roots, opts, root) do
    metadata =
      [plan.manifest.manifest_path, Path.join(root, "mix.lock")] ++
        Enum.map(~w(.formatter.exs .credo.exs .dialyzer_ignore.exs), &Path.join(root, &1)) ++
        Enum.flat_map(plan.workspace.projects, fn {_id, project} ->
          [Path.join(project.abs_path, "mix.exs"), Path.join(project.abs_path, "mix.lock")]
        end) ++
        Enum.map(plan.structural_inputs, &Path.join(root, &1)) ++
        Keyword.get(opts, :metadata, []) ++
        Keyword.get(opts, :digests, []) ++
        Enum.flat_map(config_roots, &regular_files/1)

    metadata |> Enum.uniq() |> Enum.sort() |> Enum.map(&{&1, fingerprint(&1)})
  end

  defp slot_checks(plan, projects, opts, root) do
    projects
    |> Enum.flat_map(&project_slots(plan, &1))
    |> Kernel.++(Keyword.get(opts, :directories, []))
    |> Enum.flat_map(&ancestors(&1, root))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, path_type(&1)})
  end

  defp project_slots(plan, project) do
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
  end

  defp topology_checks(config_roots, opts) do
    (config_roots ++ Keyword.get(opts, :topology, []))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, topology(&1)})
  end

  defp guard_code(inputs) do
    quote do
      weld_refresh = unquote(inputs.refresh)
      weld_type = unquote(path_type_fn())
      weld_read_digest = unquote(read_digest_fn())
      weld_digest = unquote(digest_fn())
      weld_children = unquote(children_fn())
      weld_walk = unquote(walk_fn())
      weld_topology = unquote(topology_fn())
      unquote(check_inputs_ast(inputs))
      unquote(check_safe_roots_ast(inputs))
      unquote(check_discovery_ast(inputs))
    end
  end

  defp path_type_fn do
    quote do
      fn path ->
        case File.lstat(path) do
          {:ok, %{type: type}} -> type
          {:error, :enoent} -> :missing
          _ -> :unreadable
        end
      end
    end
  end

  defp read_digest_fn do
    quote do
      fn path, mode ->
        case File.read(path) do
          {:ok, bytes} ->
            {Base.encode16(:crypto.hash(:sha256, bytes), case: :lower), Bitwise.band(mode, 0o111)}

          _ ->
            :unreadable
        end
      end
    end
  end

  defp digest_fn do
    quote do
      fn path ->
        case File.lstat(path) do
          {:ok, %{type: :regular, mode: mode}} -> weld_read_digest.(path, mode)
          {:error, :enoent} -> :missing
          _ -> :unsafe
        end
      end
    end
  end

  defp children_fn do
    quote do
      fn walk, path ->
        case File.ls(path) do
          {:ok, names} -> Enum.flat_map(names, &walk.(walk, Path.join(path, &1)))
          _ -> [{path, :unreadable}]
        end
      end
    end
  end

  defp walk_fn do
    quote do
      fn walk, path ->
        type = weld_type.(path)
        children = if type == :directory, do: weld_children.(walk, path), else: []
        [{path, type} | children]
      end
    end
  end

  defp topology_fn do
    quote do
      fn path ->
        weld_walk.(weld_walk, path)
        |> Enum.map(fn {entry, type} -> {Path.relative_to(entry, path), type} end)
        |> Enum.sort()
      end
    end
  end

  defp check_inputs_ast(inputs) do
    quote do
      for {path, expected} <- unquote(Macro.escape(inputs.checks)) do
        unless weld_digest.(path) == expected, do: Mix.raise(weld_refresh)
      end

      for {path, expected} <- unquote(Macro.escape(inputs.slots)) do
        unless weld_type.(path) == expected, do: Mix.raise(weld_refresh)
      end

      for {path, expected} <- unquote(Macro.escape(inputs.topology)) do
        unless weld_topology.(path) == expected, do: Mix.raise(weld_refresh)
      end
    end
  end

  defp check_safe_roots_ast(inputs) do
    quote do
      for root <- unquote(inputs.safe_roots), {_path, type} <- weld_topology.(root) do
        unless type in [:regular, :directory], do: Mix.raise(weld_refresh)
      end
    end
  end

  defp check_discovery_ast(inputs) do
    quote do
      weld_projects =
        unquote(inputs.patterns)
        |> Enum.flat_map(&Path.wildcard(&1, match_dot: false))
        |> Enum.reject(fn path ->
          path
          |> Path.relative_to(unquote(inputs.root))
          |> Path.split()
          |> Enum.any?(&(&1 in unquote(@ignored)))
        end)
        |> Enum.filter(&File.regular?/1)
        |> Enum.uniq()
        |> Enum.sort()

      unless weld_projects == unquote(inputs.discovered), do: Mix.raise(weld_refresh)
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
    |> String.trim_trailing()
  end

  defp refresh_command(plan) do
    "live projection inputs changed; run mix weld project --artifact " <>
      plan.artifact.id <>
      " --kind live --manifest " <> shell_argument(plan.manifest.manifest_path)
  end

  defp discovery_patterns(plan) do
    root = plan.manifest.repo_root

    Enum.map(plan.workspace.discovery.globs, &Path.join([root, &1, "mix.exs"]))
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

  defp shell_argument(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
