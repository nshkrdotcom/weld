defmodule Weld.Layout.Live do
  @moduledoc "Self-contained live guards rendered solely from explicit observations."
  alias Weld.Core.{Facts, Selection}

  def guard_source(plan, opts \\ []), do: plan |> guard_ast(opts) |> Macro.to_string()

  def guard_ast(plan, opts \\ []) do
    root = plan.manifest.repo_root
    projects = Selection.projects_for_view(plan, :test)
    config = Enum.map(projects, &Path.join(&1.abs_path, "config"))

    checks = metadata_checks(plan, opts, root, config)
    slots = observed_slots(plan, projects, root)
    topology = observed_topology(plan, opts, root, config)
    safe = Keyword.get(opts, :directories, []) |> Enum.map(&Path.relative_to(&1, root))
    links = Keyword.get(opts, :links, [])
    globs = Enum.map(plan.workspace.discovery.globs, &Path.join(&1, "mix.exs"))
    discovered = discovered_projects(plan)
    refresh = refresh_command(plan, root)

    # Each fragment uses this module's quote context. Join its statements into
    # one block so generated variable bindings and execution order stay intact.
    fragments = [
      guard_helpers_ast(refresh),
      metadata_guard_ast(checks, slots),
      topology_guard_ast(topology, safe),
      link_guard_ast(links),
      discovery_guard_ast(globs, discovered)
    ]

    {:__block__, [], Enum.flat_map(fragments, &quoted_statements/1)}
  end

  defp quoted_statements({:__block__, _, expressions}), do: expressions
  defp quoted_statements(expression), do: [expression]

  defp metadata_checks(plan, opts, root, config) do
    metadata =
      [plan.manifest.manifest_path, Path.join(root, "mix.lock")] ++
        Enum.map(plan.structural_inputs, &Path.join(root, &1)) ++
        Keyword.get(opts, :digests, []) ++
        Keyword.get(opts, :metadata, []) ++
        Enum.flat_map(config, &Facts.list_files(plan.facts, &1))

    metadata
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, root), Facts.fingerprint(plan.facts, &1)})
  end

  defp observed_slots(plan, projects, root) do
    for project <- projects,
        path <-
          Enum.uniq(
            project.elixirc_paths ++
              project.erlc_paths ++
              project.test_paths ++ ~w(lib src c_src include priv config test)
          ) do
      absolute = Path.expand(path, project.abs_path)
      {Path.relative_to(absolute, root), Facts.type(plan.facts, absolute)}
    end
  end

  defp observed_topology(plan, opts, root, config) do
    (config ++ Keyword.get(opts, :topology, []))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path ->
      observed =
        Facts.topology(plan.facts, path)
        |> Enum.map(fn {node, kind} -> {Path.relative_to(node, path), kind} end)

      {Path.relative_to(path, root), observed}
    end)
  end

  defp discovered_projects(plan) do
    plan.workspace.projects
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&if(&1 == ".", do: "mix.exs", else: Path.join(&1, "mix.exs")))
    |> Enum.sort()
  end

  defp refresh_command(plan, root) do
    refresh =
      "live projection inputs changed; run mix weld project --artifact " <>
        quote_arg(plan.artifact.id) <>
        " --kind live --root " <>
        quote_arg(root) <>
        " --manifest " <> quote_arg(plan.manifest.manifest_path)

    # Refresh paths are computed at runtime too, so guard bytes are portable.
    String.replace(refresh, root, "<checkout>")
  end

  defp guard_helpers_ast(refresh) do
    quote do
      weld_source_root = Path.expand("../../../..", __DIR__)
      weld_refresh = String.replace(unquote(refresh), "<checkout>", weld_source_root)

      unquote(type_reader_ast())
      unquote(fingerprint_reader_ast())
      unquote(tree_walker_ast())
    end
  end

  defp type_reader_ast do
    quote do
      weld_type = fn path ->
        case File.lstat(path) do
          {:ok, %{type: type}} -> type
          {:error, :enoent} -> :missing
          _ -> :unsafe
        end
      end
    end
  end

  defp fingerprint_reader_ast do
    quote do
      weld_fingerprint = fn path ->
        case File.lstat(path) do
          {:ok, %{type: :regular, mode: mode}} ->
            {Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower),
             Bitwise.band(mode, 0o111)}

          {:error, :enoent} ->
            :missing

          _ ->
            :unsafe
        end
      end
    end
  end

  defp tree_walker_ast do
    quote do
      weld_walk = fn walk, path ->
        kind = weld_type.(path)

        children =
          if kind == :directory do
            File.ls!(path) |> Enum.sort() |> Enum.flat_map(&walk.(walk, Path.join(path, &1)))
          else
            []
          end

        [{path, kind} | children]
      end
    end
  end

  defp metadata_guard_ast(checks, slots) do
    quote do
      for {relative, expected} <- unquote(Macro.escape(checks)) do
        unless weld_fingerprint.(Path.join(weld_source_root, relative)) == expected,
          do: Mix.raise(weld_refresh)
      end

      for {relative, expected} <- unquote(Macro.escape(Enum.sort(Enum.uniq(slots)))) do
        unless weld_type.(Path.join(weld_source_root, relative)) == expected,
          do: Mix.raise(weld_refresh)
      end
    end
  end

  defp topology_guard_ast(topology, safe) do
    quote do
      for {relative, expected} <- unquote(Macro.escape(topology)) do
        path = Path.join(weld_source_root, relative)

        observed =
          weld_walk.(weld_walk, path)
          |> Enum.map(fn {node, kind} -> {Path.relative_to(node, path), kind} end)
          |> Enum.sort()

        unless observed == expected, do: Mix.raise(weld_refresh)
      end

      for relative <- unquote(Enum.sort(Enum.uniq(safe))),
          {_path, kind} <- weld_walk.(weld_walk, Path.join(weld_source_root, relative)) do
        unless kind in [:regular, :directory], do: Mix.raise(weld_refresh)
      end
    end
  end

  defp link_guard_ast(links) do
    quote do
      for {target, source} <- unquote(Macro.escape(links)) do
        link = Path.join(__DIR__, target)

        unquote(link_target_ast())
      end
    end
  end

  defp link_target_ast do
    quote do
      case File.read_link(link) do
        {:ok, actual} ->
          unless Path.expand(actual, Path.dirname(link)) == Path.join(weld_source_root, source),
            do: Mix.raise(weld_refresh)

        _ ->
          Mix.raise(weld_refresh)
      end
    end
  end

  defp discovery_guard_ast(globs, discovered) do
    quote do
      weld_discovered =
        unquote(globs)
        |> Enum.flat_map(&Path.wildcard(Path.join(weld_source_root, &1), match_dot: true))
        |> Enum.reject(fn path ->
          path
          |> Path.relative_to(weld_source_root)
          |> Path.split()
          |> Enum.any?(&(&1 in ~w(.git .weld deps _build dist tmp doc)))
        end)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, weld_source_root))
        |> Enum.uniq()
        |> Enum.sort()

      unless weld_discovered == unquote(discovered), do: Mix.raise(weld_refresh)
    end
  end

  def aliases_source, do: Macro.to_string(aliases_ast())

  defp aliases_ast do
    quote do
      [
        "hex.build": fn _ ->
          Mix.raise("live projections cannot be packaged; generate a full candidate")
        end,
        "hex.publish": fn _ ->
          Mix.raise("live projections cannot be published; generate a full candidate")
        end
      ]
    end
  end

  def native_mix!(content, guard, links) do
    override = native_override_ast(guard, links)
    ast = Code.string_to_quoted!(content)

    {ast, count} =
      Macro.postwalk(ast, 0, fn
        {:defmodule, meta, [name, [do: body]]} = node, count ->
          if uses_mix?(body),
            do: {{:defmodule, meta, [name, [do: {:__block__, [], [body, override]}]]}, count + 1},
            else: {node, count}

        node, count ->
          {node, count}
      end)

    unless count == 1,
      do:
        raise(
          Weld.Error,
          "unsupported_live_mix: use a full view; expected one Mix.Project module"
        )

    Weld.SourceFormatter.format!(Macro.to_string(ast))
  end

  defp native_override_ast(guard, links) do
    quote do
      defoverridable project: 0

      def project do
        unquote(guard)
        config = super()
        docs = config[:docs] || []

        unquote(native_paths_ast(links))

        Keyword.put(
          config,
          :aliases,
          Keyword.merge(config[:aliases] || [], unquote(aliases_ast()))
        )
      end
    end
  end

  defp native_paths_ast(links) do
    quote do
      for path <- [
            config[:build_path] || "_build",
            config[:deps_path] || "deps",
            config[:lockfile] || "mix.lock",
            if(is_list(docs), do: docs[:output] || "doc", else: "doc")
          ] do
        absolute = Path.expand(path, __DIR__)

        unless String.starts_with?(absolute, __DIR__ <> "/"),
          do: Mix.raise("live mutable path escapes generated project")

        unquote(native_overlap_ast(links))
      end
    end
  end

  defp native_overlap_ast(links) do
    quote do
      for relative <- unquote(links) do
        linked = Path.expand(relative, __DIR__)

        if absolute == linked or String.starts_with?(absolute, linked <> "/") or
             String.starts_with?(linked, absolute <> "/"),
           do: Mix.raise("live mutable path overlaps linked source")
      end
    end
  end

  defp uses_mix?({:__block__, _, entries}), do: Enum.any?(entries, &uses_mix?/1)
  defp uses_mix?({:use, _, [{:__aliases__, _, [:Mix, :Project]}]}), do: true
  defp uses_mix?(_), do: false
  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
