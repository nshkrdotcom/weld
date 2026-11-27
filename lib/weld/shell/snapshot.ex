defmodule Weld.Shell.Snapshot do
  @moduledoc "Source observations gathered once and shared by every artifact in a command."
  alias Weld.{Core.Facts, Core.Identity, Core.Inventory, Error, Git, Output}

  @ignored ~w(.git .weld deps _build .mix_sources.json dist tmp doc)
  @max_entries 250_000
  @max_bytes 512 * 1024 * 1024

  def collect!(manifest, opts \\ []) do
    root = Path.expand(manifest.repo_root)
    checkout_root = Path.expand(Keyword.get(opts, :checkout_root) || Git.root(root) || root)

    unless root == checkout_root or String.starts_with?(root, checkout_root <> "/"),
      do: raise(Error, "workspace root escapes its source checkout")

    %{nodes: nodes} = observe!(root)

    %{
      root: root,
      checkout_root: checkout_root,
      nodes: nodes,
      compiler_id: compiler_id(),
      toolchain: %{
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "architecture" => to_string(:erlang.system_info(:system_architecture))
      },
      context: Keyword.get(opts, :context, []),
      remote_url: Git.remote_url(root)
    }
  end

  def observe!(root) do
    root = Path.expand(root)
    {nodes, _count, _bytes} = walk(root, %{}, 0, 0)
    %{root: root, nodes: nodes}
  end

  def recheck!(facts, paths \\ :all) do
    observed = observe!(facts.root)

    wanted =
      if paths == :all,
        do: Map.keys(facts.nodes) ++ Map.keys(observed.nodes),
        else: Enum.map(paths, &Path.expand(&1, facts.root))

    for path <- Enum.uniq(wanted) do
      before = facts.nodes[path] && Map.drop(facts.nodes[path], [:content])
      after_read = observed.nodes[path] && Map.drop(observed.nodes[path], [:content])

      unless before == after_read,
        do: raise(Error, "inputs_changed: #{Path.relative_to(path, facts.root)}")
    end

    :ok
  end

  @doc "Refresh only compiler-selected input slots and rule matches, including additions."
  def refresh!(facts, inputs) do
    checkout_root = Map.get(facts, :checkout_root) || facts.root

    roots =
      Enum.flat_map(inputs, fn input ->
        fact = input["fact"]

        case input["kind"] do
          kind when kind in ["file", "absence"] ->
            [fact["path"]]

          "tree" ->
            [fact["root"]]

          "glob" ->
            matches = glob_matches!(facts, checkout_root, fact)
            Enum.map(fact["matches"], & &1["path"]) ++ matches

          _ ->
            []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(fn relative -> Enum.any?(Path.split(relative), &(&1 in @ignored)) end)

    roots =
      Enum.reduce(roots, [], fn relative, selected ->
        if Enum.any?(
             selected,
             &(relative == &1 or &1 == "." or String.starts_with?(relative, &1 <> "/"))
           ), do: selected, else: selected ++ [relative]
      end)

    absolute =
      Enum.map(roots, fn relative ->
        source_path!(facts, checkout_root, relative)
      end)

    retained =
      Map.reject(facts.nodes, fn {path, _} ->
        Enum.any?(absolute, &(path == &1 or String.starts_with?(path, &1 <> "/")))
      end)

    retained_bytes =
      Enum.reduce(retained, 0, fn {_path, node}, total -> total + Map.get(node, :size, 0) end)

    {nodes, _count, _bytes} =
      Enum.reduce(absolute, {retained, map_size(retained), retained_bytes}, fn path,
                                                                               {nodes, count,
                                                                                bytes} ->
        case File.lstat(path) do
          {:error, :enoent} -> {nodes, count, bytes}
          {:ok, _} -> walk(path, nodes, count, bytes)
          {:error, reason} -> raise Error, "cannot recheck selected source #{path}: #{reason}"
        end
      end)

    %{facts | nodes: nodes}
  end

  defp source_path!(facts, checkout_root, relative) do
    path = if relative == ".", do: checkout_root, else: Output.source!(checkout_root, relative)

    unless path == facts.root or String.starts_with?(path, facts.root <> "/"),
      do: raise(Error, "portable input escapes its workspace: #{relative}")

    path
  end

  # Expand rule membership without following links or collecting an unbounded
  # wildcard result. Only the literal rule prefix is scanned; bytes are read
  # later for selected matches, by the same bounded source observer.
  defp glob_matches!(facts, checkout_root, fact) do
    _ = source_path!(facts, checkout_root, fact["root"])
    Inventory.validate_path!(fact["pattern"])

    pattern =
      if fact["root"] == ".", do: fact["pattern"], else: Path.join(fact["root"], fact["pattern"])

    prefix =
      pattern
      |> Path.split()
      |> Enum.take_while(fn part ->
        not String.contains?(part, ["*", "?", "[", "{"])
      end)

    prefix = if prefix == [], do: ".", else: Path.join(prefix)

    if Enum.any?(Path.split(prefix), &(&1 in @ignored)) do
      []
    else
      directory = source_path!(facts, checkout_root, prefix)
      {paths, _count} = glob_nodes!(directory, [], 0)
      nodes = Map.new(paths, &{&1, nil})

      Facts.wildcard(%{root: checkout_root, nodes: nodes}, pattern)
      |> Enum.map(&Path.relative_to(&1, checkout_root))
    end
  end

  defp glob_nodes!(path, paths, count) do
    if count >= @max_entries, do: raise(Error, "workspace rule exceeds bounded entry capacity")

    case File.lstat(path) do
      {:error, :enoent} ->
        {paths, count}

      {:ok, %{type: :regular}} ->
        {[path | paths], count + 1}

      {:ok, %{type: :directory}} ->
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.reject(&(&1 in @ignored))
        |> Enum.reduce({[path | paths], count + 1}, fn child, {selected, observed} ->
          glob_nodes!(Path.join(path, child), selected, observed)
        end)

      {:ok, _} ->
        raise Error, "unsafe watched source: #{path}"

      {:error, reason} ->
        raise Error, "cannot inspect watched source #{path}: #{reason}"
    end
  end

  defp walk(path, nodes, count, bytes) do
    if count >= @max_entries,
      do: raise(Error, "workspace snapshot exceeds bounded entry capacity")

    count = count + 1
    stat = File.lstat!(path)
    node = %{type: stat.type, mode: Bitwise.band(stat.mode, 0o777)}

    {node, count, bytes} =
      if stat.type == :regular do
        if bytes + stat.size > @max_bytes,
          do: raise(Error, "workspace snapshot exceeds bounded input capacity")

        contents = File.read!(path)
        after_read = File.lstat!(path)

        unless after_read.type == :regular and after_read.size == byte_size(contents) and
                 after_read.mode == stat.mode and after_read.mtime == stat.mtime,
               do: raise(Error, "inputs_changed: #{path}")

        {Map.merge(node, %{
           content: contents,
           size: byte_size(contents),
           sha256: Identity.raw(contents)
         }), count, bytes + byte_size(contents)}
      else
        {node, count, bytes}
      end

    nodes = Map.put(nodes, path, node)

    if stat.type == :directory do
      path
      |> File.ls!()
      |> Enum.sort()
      |> Enum.reject(&(&1 in @ignored))
      |> Enum.reduce({nodes, count, bytes}, fn child, {acc, n, size} ->
        walk(Path.join(path, child), acc, n, size)
      end)
    else
      {nodes, count, bytes}
    end
  end

  def compiler_id do
    # Source identity is relocation independent. Installed archives use BEAM
    # chunks with build paths/debug metadata removed by the compiler.
    _ = Application.load(:weld)
    modules = (Application.spec(:weld, :modules) || []) |> Enum.sort()

    entries =
      Enum.map(modules, fn module ->
        case :code.get_object_code(module) do
          {^module, binary, _path} ->
            stable =
              case :beam_lib.strip(binary) do
                {:ok, {^module, stripped}} -> stripped
                _ -> binary
              end

            %{"module" => Atom.to_string(module), "sha256" => Identity.raw(stable)}

          :error ->
            raise Error, "compiler identity unavailable: #{inspect(module)}"
        end
      end)

    Identity.digest("input", %{
      "schema" => "weld.compiler/2",
      "version" => "0.20.0",
      "modules" => entries
    })
  end
end
