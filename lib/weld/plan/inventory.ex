defmodule Weld.Plan.Inventory do
  @moduledoc false

  alias Weld.Core.{Facts, Identity}
  alias Weld.Core.Inventory, as: CoreInventory
  alias Weld.Core.Selection
  alias Weld.Error
  alias Weld.Layout.FilePlan
  alias Weld.Workspace.Project

  @tooling_files ~w(.formatter.exs .credo.exs .dialyzer_ignore.exs)
  @local_state ~w(.git .weld deps _build .mix_sources.json)

  @type entry :: map()

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
        Facts.source!(project.facts, project.abs_path, path)
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
      for path <- @tooling_files,
          Facts.regular?(workspace.facts, Path.join(workspace.manifest.repo_root, path)) do
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
    live = operations_by_target(layout.live)
    published = MapSet.new(layout.package_files)

    outputs =
      Enum.map(layout.full, fn op ->
        live_op = Map.fetch!(live, op.target)
        source_paths = Enum.uniq(op.sources ++ if(live_op.content, do: live_op.sources, else: []))

        inputs =
          Enum.map(
            if(source_paths == [], do: [plan.manifest.manifest_path], else: source_paths),
            fn source ->
              %{source: Path.relative_to(source, root), owner: owner(plan.workspace, source)}
            end
          )
          |> Enum.sort_by(& &1.source)

        %{
          target: op.target,
          inputs: inputs,
          kind: op.kind,
          operation: op.operation,
          publish: MapSet.member?(published, op.target),
          generated_digest: if(op.content, do: Identity.raw(op.content), else: nil),
          sha256:
            if(op.content,
              do: Identity.raw(op.content),
              else: Facts.digest!(plan.facts, hd(op.sources))
            ),
          size:
            if(op.content,
              do: byte_size(op.content),
              else: Facts.stat!(plan.facts, hd(op.sources)).size
            ),
          executable:
            is_nil(op.content) and
              Bitwise.band(Facts.stat!(plan.facts, hd(op.sources)).mode, 0o111) != 0
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

    patterns = project.package_files || CoreInventory.default_hex_files()

    published =
      patterns
      |> Enum.flat_map(&Facts.wildcard(plan.facts, Path.join(plan.source_root, &1)))
      |> Enum.flat_map(fn path ->
        if Facts.dir?(plan.facts, path), do: Facts.list_files(plan.facts, path), else: [path]
      end)
      |> Enum.map(&Path.relative_to(&1, plan.source_root))
      |> MapSet.new()

    planned = MapSet.new(plan.source_inventory, & &1.target)
    excluded = Map.get(project, :package_exclude_patterns, []) || []

    for path <- published,
        not Enum.any?(excluded, &Facts.matches?(path, &1)),
        not MapSet.member?(planned, path),
        do: raise(Error, "source inventory missing native package path #{path}")

    for entry <- plan.source_inventory do
      node = Facts.stat!(plan.facts, Path.join(root, entry.source))

      observed = %{
        sha256: node.sha256,
        size: node.size,
        mode: node.mode,
        executable: Bitwise.band(node.mode, 0o111) != 0
      }

      excluded = Map.get(project, :package_exclude_patterns, []) || []

      Map.merge(observed, %{
        target: entry.target,
        inputs: [%{source: entry.source, owner: entry.owner}],
        kind: entry.kind,
        operation: :link_or_copy,
        publish:
          MapSet.member?(published, entry.target) and
            not Enum.any?(excluded, &Facts.matches?(entry.target, &1)),
        generated_digest: nil
      })
    end
    |> CoreInventory.validate!()
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
      Facts.source!(project.facts, project.abs_path, relative)
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
          Facts.dir?(project.facts, Path.join(project.abs_path, path)) do
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
          Facts.dir?(project.facts, Path.join(project.abs_path, path)) do
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
      path in ["c_src", "include"] -> :native
      true -> :runtime
    end
  end

  defp present_component_path?(project, path, declared_paths) do
    cond do
      Facts.dir?(project.facts, Path.join(project.abs_path, path)) ->
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
      Enum.any?(["c_src", "include"], &covered?(path, &1)) -> :native
      Enum.any?(["priv", "assets", "src"], &covered?(path, &1)) -> :runtime
      true -> :metadata
    end
  end

  defp doc_path?(path) do
    Path.extname(path) in [".md", ".livemd"] or Path.basename(path) == "LICENSE"
  end

  defp entry!(workspace, source, target, kind) do
    root = workspace.manifest.repo_root
    absolute = Facts.source!(workspace.facts, root, source)

    case Facts.stat(workspace.facts, absolute) do
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

    for source <- regular_files!(workspace.facts, absolute) do
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

  defp regular_files!(facts, path) do
    Facts.reject_tree_links!(facts, path)

    for source <- Facts.list_files(facts, path) do
      if Enum.any?(Path.split(Path.relative_to(source, path)), &(&1 in @local_state)),
        do: raise(Error, "local state in source inventory: #{source}")

      source
    end
  end

  defp owner(workspace, path) do
    workspace.projects
    |> Map.values()
    |> Enum.filter(&covered?(path, &1.abs_path))
    |> Enum.sort_by(&{-byte_size(&1.abs_path), &1.id})
    |> case do
      [project | _] -> project.id
      [] -> nil
    end
  end

  defp order(entries), do: entries |> Enum.uniq() |> Enum.sort_by(&{&1.target, &1.source})

  @inventory_keys ~w(schema artifact input_id plan_id compiler_id normalized_metadata contexts selection dependencies inputs watches entries layout qualification_policy lock_slot frozen_project empty_dirs package_entries package_metadata docs_entries docs_empty_dirs)
  @roles ~w(compile runtime native test docs metadata lock generation structure verification)

  @doc "The single portable inventory authority used by plan, verification and release."
  def portable(plan) do
    root = plan.manifest.repo_root
    {metadata, external_inputs} = normalized_metadata(plan)
    references = Enum.flat_map(plan.output_inventory, & &1.inputs)

    paths =
      (Enum.map(references, & &1.source) ++
         plan.structural_inputs ++
         [Path.relative_to(plan.manifest.manifest_path, root)])
      |> Enum.uniq()
      |> Enum.sort()

    files = Enum.map(paths, &input_record(plan, &1, references))
    trees = automatic_watches(plan) ++ declared_watches(plan)

    tree_files =
      for tree <- trees,
          match <- tree["fact"]["matches"] || [],
          match["type"] == "file",
          do: input_record(plan, match["path"], references)

    compiler = %{
      "id" => "external:compiler",
      "kind" => "external",
      "roles" => ["generation"],
      "owners" => [],
      "fact" => %{
        "name" => "compiler",
        "value_digest" => plan.facts.compiler_id,
        "opaque" => false
      }
    }

    full_operations = operations_by_target(plan.layout.full)
    live_operations = operations_by_target(plan.layout.live)

    generated =
      for entry <- plan.output_inventory,
          live = Map.fetch!(live_operations, entry.target),
          entry.generated_digest || live.content do
        origins = Enum.map(entry.inputs, &origin_ref(plan, &1.source))

        %{
          "id" => "generated:" <> entry.target,
          "kind" => "generated",
          "roles" => entry_roles(plan, entry),
          "owners" => owners_for(entry),
          "fact" => %{
            "recipe" => "weld.layout/" <> layout_name(plan) <> "/" <> entry.target,
            "version" => 2,
            "inputs" => Enum.sort(Enum.uniq(["external:compiler" | origins]))
          }
        }
      end

    inputs =
      (files ++ tree_files ++ trees ++ [compiler] ++ external_inputs ++ generated)
      |> Enum.group_by(& &1["id"])
      |> Enum.map(fn {_id, values} ->
        first = hd(values)

        unless Enum.all?(values, &(&1["fact"] == first["fact"])),
          do: raise(Error, "conflicting input facts")

        %{first | "roles" => values |> Enum.flat_map(& &1["roles"]) |> Enum.uniq() |> Enum.sort()}
      end)
      |> Enum.sort_by(& &1["id"])

    inventory = %{
      "schema" => "weld.inventory/2",
      "artifact" => plan.artifact.id,
      "input_id" => nil,
      "plan_id" => nil,
      "compiler_id" => plan.facts.compiler_id,
      "normalized_metadata" => metadata,
      "contexts" => wire(plan.facts.context, plan.manifest.repo_root),
      "selection" => %{
        "dependency_members" => plan.dependency_ids,
        "compiled_owners" => Enum.sort(Enum.uniq(plan.selected_ids)),
        "verification_only" => plan.verification_ids,
        "inventory_only" => plan.inventory_member_ids,
        "excluded" => plan.excluded_ids,
        "reasons" =>
          wire(
            Enum.map(Weld.Graph.edges(plan.artifact_graph), &Map.from_struct/1),
            plan.manifest.repo_root
          )
      },
      "dependencies" =>
        wire(Selection.external_deps_for_view(plan, :package), plan.manifest.repo_root),
      "inputs" => inputs,
      "watches" =>
        inputs
        |> Enum.filter(&(&1["kind"] in ~w(absence tree glob) or "structure" in &1["roles"]))
        |> Enum.map(& &1["id"]),
      "entries" =>
        Enum.map(plan.output_inventory, fn entry ->
          portable_entry(
            plan,
            entry,
            Map.fetch!(full_operations, entry.target),
            Map.fetch!(live_operations, entry.target)
          )
        end),
      "layout" => layout_details(plan),
      "qualification_policy" => %{
        "artifact_tests" => plan.artifact.verify.artifact_tests,
        "component_tests" => plan.artifact.verify.component_tests,
        "hex_build" => plan.artifact.verify.hex_build,
        "hex_publish_check" => plan.artifact.verify.hex_publish,
        "smoke" =>
          if(plan.artifact.verify.smoke.enabled,
            do: %{"entry_file" => plan.artifact.verify.smoke.entry_file}
          ),
        "context" => plan.artifact.verify.context
      },
      "lock_slot" => %{
        "path" => "mix.lock",
        "policy" => if(plan.source_root, do: "preserve", else: "resolve")
      },
      "frozen_project" => [],
      "empty_dirs" => Map.get(plan.layout, :empty_dirs, []),
      "package_entries" => nil,
      "package_metadata" => nil,
      "docs_entries" => [],
      "docs_empty_dirs" => []
    }

    inventory = %{inventory | "input_id" => input_id(inventory)}
    inventory = %{inventory | "plan_id" => plan_id(inventory)}
    validate_portable!(inventory)
  end

  def input_id(inventory) do
    Identity.digest(
      "input",
      Map.take(
        inventory,
        ~w(inputs watches normalized_metadata contexts compiler_id)
      )
    )
  end

  def plan_id(inventory) do
    Identity.digest(
      "plan",
      Map.take(
        inventory,
        ~w(artifact input_id selection dependencies entries layout qualification_policy lock_slot)
      )
    )
  end

  defp normalized_metadata(plan) do
    ids =
      Enum.uniq(
        plan.selected_ids ++
          plan.verification_ids ++ plan.inventory_member_ids ++ plan.artifact.external_projects
      )

    {projects, external} =
      Enum.map_reduce(Enum.sort(ids), %{}, fn id, external ->
        project = Map.fetch!(plan.workspace.projects, id)

        {metadata, external} =
          project_dependency_metadata(project, plan.manifest.repo_root, external)

        {wire(metadata, plan.manifest.repo_root), external}
      end)

    {%{
       "artifact" => wire(Map.from_struct(plan.artifact), plan.manifest.repo_root),
       "projects" => projects,
       "toolchain" => plan.facts.toolchain
     }, Map.values(external)}
  end

  # Keep actual source declarations available to Graph and detached probes.
  # Portable metadata references opaque inputs for unobserved dependency sources;
  # observing the declaration does not establish the contents of that source.
  defp project_dependency_metadata(project, root, external) do
    {deps, external} = dependency_metadata(project.deps, project, root, external)

    {by_env, external} =
      project.deps_by_env
      |> Enum.sort()
      |> Enum.map_reduce(external, fn {env, deps}, external ->
        {deps, external} = dependency_metadata(deps, project, root, external)
        {{env, deps}, external}
      end)

    {configs, external} =
      project.config_by_env
      |> Enum.sort()
      |> Enum.map_reduce(external, fn {env, config}, external ->
        {deps, external} =
          Enum.map_reduce(config[:deps] || [], external, fn dep, external ->
            dependency_tuple_metadata(dep, project, root, external)
          end)

        config =
          if Keyword.has_key?(config, :deps), do: Keyword.put(config, :deps, deps), else: config

        {{env, config}, external}
      end)

    metadata =
      project
      |> Map.from_struct()
      |> Map.drop([:facts, :abs_path])
      |> Map.merge(%{deps: deps, deps_by_env: Map.new(by_env), config_by_env: Map.new(configs)})

    {metadata, external}
  end

  defp dependency_metadata(deps, project, root, external) do
    Enum.map_reduce(deps, external, fn dep, external ->
      {opts, external} = dependency_options_metadata(dep.opts, dep.app, project, root, external)
      {original, external} = dependency_tuple_metadata(dep.original, project, root, external)
      {%{dep | opts: opts, original: original}, external}
    end)
  end

  defp dependency_tuple_metadata({app, opts}, project, root, external) when is_list(opts) do
    {opts, external} = dependency_options_metadata(opts, app, project, root, external)
    {{app, opts}, external}
  end

  defp dependency_tuple_metadata({app, requirement, opts}, project, root, external)
       when is_list(opts) do
    {opts, external} = dependency_options_metadata(opts, app, project, root, external)
    {{app, requirement, opts}, external}
  end

  defp dependency_tuple_metadata(declaration, _project, _root, external),
    do: {declaration, external}

  defp dependency_options_metadata(opts, app, project, root, external) do
    {opts, external} = dependency_path_metadata(opts, app, project, root, external)

    case opts[:git] do
      git when is_binary(git) ->
        if Weld.Graph.local_git_locator?(git),
          do:
            opaque_dependency_option(
              opts,
              :git,
              portable_git_locator(git, root),
              app,
              project,
              external
            ),
          else: {opts, external}

      _ ->
        {opts, external}
    end
  end

  defp dependency_path_metadata(opts, app, project, root, external) do
    case opts[:path] do
      path when is_binary(path) ->
        absolute = Path.expand(path, project.abs_path)

        if absolute == root or String.starts_with?(absolute, root <> "/") do
          {keep_absolute_dependency_path(opts, path, absolute), external}
        else
          opaque_dependency_option(opts, :path, path, app, project, external)
        end

      _ ->
        {opts, external}
    end
  end

  defp keep_absolute_dependency_path(opts, path, absolute) do
    if Path.type(path) == :absolute, do: Keyword.put(opts, :path, absolute), else: opts
  end

  defp portable_git_locator(value, root) do
    if String.starts_with?(String.downcase(value), "file://") do
      uri = URI.parse(value)
      path = URI.decode(uri.path || "")

      case checkout_relative_locator(path, root) do
        nil ->
          value

        relative ->
          Identity.canonical(%{
            "anchor" => "checkout",
            "scheme" => "file",
            "authority" => uri.authority,
            "path" => relative,
            "query" => uri.query,
            "fragment" => uri.fragment
          })
      end
    else
      case checkout_relative_locator(value, root) do
        nil -> value
        relative -> Identity.canonical(%{"anchor" => "checkout", "path" => relative})
      end
    end
  end

  defp checkout_relative_locator(path, root) do
    if Path.type(path) == :absolute do
      path = Path.expand(path, root)
      if path == root or String.starts_with?(path, root <> "/"), do: Path.relative_to(path, root)
    end
  end

  defp opaque_dependency_option(opts, key, value, app, project, external) do
    digest = Identity.raw(value)

    name =
      "dependency-" <>
        Atom.to_string(key) <> "/" <> project.id <> "/" <> to_string(app) <> "/" <> digest

    id = "external:" <> name

    input = %{
      "id" => id,
      "kind" => "external",
      "roles" => ["structure"],
      "owners" => [project.id],
      "fact" => %{"name" => name, "value_digest" => digest, "opaque" => true}
    }

    {Keyword.put(opts, key, %{"external_input" => id}), Map.put(external, id, input)}
  end

  defp input_record(plan, path, references) do
    CoreInventory.validate_path!(path)
    absolute = Facts.source!(plan.facts, plan.manifest.repo_root, path)

    related =
      Enum.filter(plan.output_inventory, fn entry ->
        Enum.any?(entry.inputs, &(&1.source == path))
      end)

    role_set =
      related
      |> Enum.flat_map(&entry_roles(plan, &1))
      |> Kernel.++(declared_roles(plan, path))
      |> Kernel.++(if(Path.basename(path) == "mix.lock", do: ["lock"], else: []))
      |> Kernel.++(
        if(
          path in plan.structural_inputs or related == [] or
            path == Path.relative_to(plan.manifest.manifest_path, plan.manifest.repo_root),
          do: ["structure"],
          else: []
        )
      )
      |> Enum.uniq()
      |> Enum.sort()

    owned =
      references
      |> Enum.filter(&(&1.source == path))
      |> Enum.map(& &1.owner)
      |> Kernel.++(List.wrap(owner(plan.workspace, absolute)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    case Facts.stat(plan.facts, absolute) do
      {:ok, %{type: :regular} = node} ->
        %{
          "id" => "file:" <> path,
          "kind" => "file",
          "roles" => role_set,
          "owners" => owned,
          "fact" => %{
            "path" => path,
            "sha256" => node.sha256,
            "size" => node.size,
            "executable" => Bitwise.band(node.mode, 0o111) != 0,
            "mode" => normalized_file_mode(node.mode)
          }
        }

      {:error, :enoent} ->
        %{
          "id" => "absence:" <> path,
          "kind" => "absence",
          "roles" => ["structure"],
          "owners" => owned,
          "fact" => %{"path" => path}
        }

      _ ->
        raise Error, "unsafe inventory input: #{path}"
    end
  end

  defp automatic_watches(plan) do
    projects =
      Enum.map(
        Enum.uniq(plan.selected_ids ++ plan.verification_ids),
        &Map.fetch!(plan.workspace.projects, &1)
      )

    roots =
      for project <- projects,
          path <-
            Enum.uniq(
              project.copy_dirs ++
                project.elixirc_paths ++
                project.test_elixirc_paths ++
                project.erlc_paths ++
                project.test_paths ++ [project.erlc_include_path] ++ ~w(config c_src priv)
            ),
          do: {Path.join(project.abs_path, path), project.id}

    roots =
      roots ++
        Enum.map(plan.source_roots, &{Path.join(plan.manifest.repo_root, &1.source), &1.owner})

    trees =
      for {absolute, owner} <- Enum.uniq(roots), Facts.type(plan.facts, absolute) != :regular do
        relative = Path.relative_to(absolute, plan.manifest.repo_root)
        tree_record(plan, relative, nil, owner, Facts.topology(plan.facts, absolute))
      end

    discovery =
      for glob <- plan.workspace.discovery.globs do
        pattern = if glob == ".", do: "mix.exs", else: Path.join(glob, "mix.exs")

        matches =
          Facts.wildcard(plan.facts, Path.join(plan.manifest.repo_root, pattern))
          |> Enum.reject(fn path ->
            path
            |> Path.relative_to(plan.manifest.repo_root)
            |> Path.split()
            |> Enum.any?(&(&1 in ~w(.git .weld _build deps dist tmp doc)))
          end)
          |> Enum.map(&{&1, Facts.type(plan.facts, &1)})

        tree_record(plan, ".", pattern, nil, matches)
      end

    trees ++ discovery
  end

  defp declared_watches(plan) do
    for watch <- plan.input_watches do
      local =
        if watch.owner == ".",
          do: plan.manifest.repo_root,
          else: Path.join(plan.manifest.repo_root, watch.owner)

      absolute = Path.join(local, watch.pattern)
      relative = Path.relative_to(absolute, plan.manifest.repo_root)

      topology =
        case watch.type do
          :glob ->
            Facts.wildcard(plan.facts, absolute)
            |> Enum.flat_map(&Facts.topology(plan.facts, &1))
            |> Enum.uniq()

          _ ->
            Facts.topology(plan.facts, absolute)
        end

      tree_record(
        plan,
        if(watch.type == :glob, do: watch.owner, else: relative),
        if(watch.type == :glob, do: watch.pattern),
        watch.owner,
        topology
      )
    end
  end

  defp normalized_file_mode(mode), do: if(Bitwise.band(mode, 0o111) == 0, do: 0o644, else: 0o755)

  defp tree_record(plan, root, pattern, owner, topology) do
    kind = if pattern, do: "glob", else: "tree"

    matches =
      for {path, type} <- topology, type != :missing do
        unless type in [:regular, :directory], do: raise(Error, "unsafe watched input: #{path}")

        %{
          "path" => Path.relative_to(path, plan.manifest.repo_root),
          "type" => if(type == :regular, do: "file", else: "directory"),
          "mode" =>
            case Facts.stat!(plan.facts, path) do
              %{type: :regular, mode: mode} -> normalized_file_mode(mode)
              %{type: :directory, mode: mode} -> mode
            end
        }
      end

    %{
      "id" => kind <> ":" <> root <> if(pattern, do: ":" <> pattern, else: ""),
      "kind" => kind,
      "roles" => ["structure"],
      "owners" => List.wrap(owner),
      "fact" => %{
        "root" => root,
        "pattern" => pattern,
        "excludes" => [],
        "matches" => Enum.sort_by(matches, & &1["path"])
      }
    }
  end

  defp operations_by_target(operations), do: Map.new(operations, &{&1.target, &1})

  defp portable_entry(plan, entry, full, live) do
    origins = Enum.map(entry.inputs, &origin_ref(plan, &1.source))

    origins =
      if full.content || live.content, do: ["generated:" <> entry.target | origins], else: origins

    %{
      "target" => entry.target,
      "kind" => "file",
      "roles" => entry_roles(plan, entry),
      "owners" => owners_for(entry),
      "origins" => Enum.sort(Enum.uniq(origins)),
      "full" => variant(plan, full, :full),
      "live" => variant(plan, live, :live),
      "package" => entry.publish,
      "verify" => true
    }
  end

  defp variant(_plan, %{content: content}, _kind) when is_binary(content) do
    %{
      "strategy" => "write",
      "source" => nil,
      "content_sha256" => Identity.raw(content),
      "size" => byte_size(content),
      "executable" => false,
      "group" => nil
    }
  end

  defp variant(plan, %{sources: [source | _]} = op, kind) do
    node = Facts.stat!(plan.facts, source)
    strategy = variant_strategy(op, kind)

    %{
      "strategy" => strategy,
      "source" => "file:" <> Path.relative_to(source, plan.manifest.repo_root),
      "content_sha256" => node.sha256,
      "size" => node.size,
      "executable" => Bitwise.band(node.mode, 0o111) != 0,
      "group" => variant_group(plan.layout, op.target, strategy)
    }
  end

  defp variant_strategy(%{operation: :link_or_copy}, :live), do: "link"
  defp variant_strategy(%{sources: [_, _ | _]}, _kind), do: "dedup"
  defp variant_strategy(_, _kind), do: "copy"

  defp variant_group(layout, target, "link") do
    case Enum.find(Map.get(layout, :live_roots, []), &covered?(target, &1.target)) do
      nil -> nil
      group -> %{"source_root" => group.source, "target_root" => group.target}
    end
  end

  defp variant_group(_layout, _target, _strategy), do: nil

  defp roles(kind) do
    case kind do
      :compiled -> ["compile"]
      :test -> ["test", "verification"]
      :artifact_test -> ["test", "verification"]
      :native -> ["compile", "native", "runtime"]
      :metadata -> ["generation", "metadata", "structure"]
      :docs -> ["docs"]
      _ -> ["runtime"]
    end
  end

  defp origin_ref(plan, path) do
    prefix =
      if Facts.regular?(plan.facts, Path.join(plan.manifest.repo_root, path)),
        do: "file:",
        else: "absence:"

    prefix <> path
  end

  defp entry_roles(plan, entry) do
    (Enum.flat_map(entry.inputs, &declared_roles(plan, &1.source)) ++ roles(entry.kind))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp declared_roles(plan, path) do
    for watch <- plan.input_watches,
        input <- watch.entries,
        relative =
          if(watch.owner == ".", do: input.target, else: Path.join(watch.owner, input.target)),
        relative == path,
        role <- List.wrap(watch.declaration[:roles]),
        do: Atom.to_string(role)
  end

  defp owners_for(entry),
    do:
      entry.inputs |> Enum.map(& &1.owner) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

  defp layout_name(plan),
    do:
      %{package_projection: "components", monolith: "flat", source_project: "preserve"}[
        plan.artifact.mode
      ]

  defp layout_details(plan) do
    details =
      Map.take(plan.layout || %{}, [
        :file_remaps,
        :source_mappings,
        :migration_layout,
        :migration_remaps,
        :helper_transformations,
        :repo_infos,
        :test_support_projects,
        :empty_dirs
      ])

    Map.put(wire(details, plan.manifest.repo_root), "name", layout_name(plan))
  end

  defp wire(%MapSet{} = values, root),
    do:
      values
      |> MapSet.to_list()
      |> Enum.map(&wire(&1, root))
      |> Enum.sort_by(&Identity.canonical/1)

  defp wire(%Regex{} = regex, _root),
    do: %{"type" => "regex", "source" => Regex.source(regex), "options" => Regex.opts(regex)}

  defp wire(%_{} = value, root), do: value |> Map.from_struct() |> wire(root)

  defp wire(value, root) when is_map(value) do
    pairs = Enum.map(value, fn {key, item} -> {to_string(key), wire(item, root)} end)

    if length(Enum.uniq_by(pairs, &elem(&1, 0))) != length(pairs),
      do: raise(Error, "duplicate canonical key")

    Map.new(pairs)
  end

  defp wire(value, root) when is_list(value), do: Enum.map(value, &wire(&1, root))

  defp wire({:i, path}, root) when is_list(path) do
    case CoreInventory.portable_erlc_include(path, root) do
      nil -> ["i", wire(path, root)]
      descriptor -> ["i", descriptor]
    end
  end

  defp wire(value, root) when is_tuple(value), do: value |> Tuple.to_list() |> wire(root)
  defp wire(value, _root) when value in [nil, true, false], do: value
  defp wire(value, _root) when is_atom(value), do: Atom.to_string(value)

  defp wire(value, root) when is_binary(value) do
    if value == root or String.starts_with?(value, root <> "/"),
      do: Path.relative_to(value, root),
      else: value
  end

  defp wire(value, _root) when is_integer(value), do: value
  defp wire(_value, _root), do: raise(Error, "unsupported portable metadata value")

  @doc "Validate every closed inventory record and recompute semantic identities."
  def validate_portable!(inventory) do
    closed!(inventory, @inventory_keys)
    unless inventory["schema"] == "weld.inventory/2", do: raise(Error, "invalid inventory schema")
    for key <- ~w(input_id plan_id compiler_id), do: digest!(inventory[key])
    unique_sorted!(inventory["inputs"], "id")
    unique_sorted!(inventory["entries"], "target")

    validate_selection!(inventory["selection"])
    validate_policy!(inventory["qualification_policy"])

    unless is_map(inventory["layout"]) and
             inventory["layout"]["name"] in ~w(components flat preserve) and
             Map.keys(inventory["layout"]) --
               ~w(name file_remaps source_mappings migration_layout migration_remaps helper_transformations repo_infos test_support_projects empty_dirs) ==
               [],
           do: raise(Error, "invalid layout record")

    validate_inventory_references!(inventory)
    validate_frozen_records!(inventory)

    unless input_id(inventory) == inventory["input_id"] and
             plan_id(inventory) == inventory["plan_id"],
           do: raise(Error, "inventory identity mismatch")

    inventory
  end

  defp validate_selection!(selection) do
    closed!(
      selection,
      ~w(dependency_members compiled_owners verification_only inventory_only excluded reasons)
    )

    for key <- ~w(dependency_members compiled_owners verification_only inventory_only excluded),
        do: sets!(selection[key])
  end

  defp validate_policy!(policy) do
    closed!(
      policy,
      ~w(artifact_tests component_tests hex_build hex_publish_check smoke context)
    )

    for key <- ~w(component_tests hex_build hex_publish_check),
        not is_boolean(policy[key]),
        do: raise(Error, "invalid qualification policy")

    Enum.each(policy["artifact_tests"], &CoreInventory.validate_path!/1)
    sets!(policy["context"])

    if policy["smoke"] do
      closed!(policy["smoke"], ["entry_file"])
      CoreInventory.validate_path!(policy["smoke"]["entry_file"])
    end
  end

  defp validate_inventory_references!(inventory) do
    inputs = Map.new(inventory["inputs"], &{&1["id"], &1})
    for input <- inventory["inputs"], do: validate_input!(input, inputs)
    for {id, %{"kind" => "generated"}} <- inputs, do: generated_acyclic!(id, inputs, [])
    sets!(inventory["watches"])

    for id <- inventory["watches"],
        not Map.has_key?(inputs, id),
        do: raise(Error, "missing watch input")

    for entry <- inventory["entries"], do: validate_entry!(entry, inputs)
    _ = CoreInventory.validate!(Enum.map(inventory["entries"], &%{target: &1["target"]}))
  end

  defp validate_frozen_records!(inventory) do
    closed!(inventory["lock_slot"], ~w(path policy))

    unless inventory["lock_slot"]["path"] == "mix.lock" and
             inventory["lock_slot"]["policy"] in ~w(none resolve preserve),
           do: raise(Error, "invalid lock slot")

    for key <- ~w(frozen_project docs_entries), do: validate_file_records!(inventory[key])
    if inventory["package_entries"], do: validate_file_records!(inventory["package_entries"])
    for key <- ~w(empty_dirs docs_empty_dirs), do: paths!(inventory[key])
  end

  defp validate_input!(input, inputs) do
    closed!(input, ~w(id kind roles owners fact))
    sets!(input["roles"])
    sets!(input["owners"])
    unless Enum.all?(input["roles"], &(&1 in @roles)), do: raise(Error, "invalid input role")
    kind = input["kind"]
    fact = input["fact"]
    id = input["id"]

    unless is_binary(id) and id == input_identifier(kind, fact, id),
      do: raise(Error, "input identifier does not match its fact")

    validate_input_fact!(kind, fact, id, inputs)
  end

  defp input_identifier(kind, fact, _id) when kind in ~w(file absence),
    do: kind <> ":" <> to_string(fact["path"])

  defp input_identifier("tree", fact, _id), do: "tree:" <> to_string(fact["root"])

  defp input_identifier("glob", fact, _id),
    do: "glob:" <> to_string(fact["root"]) <> ":" <> to_string(fact["pattern"])

  defp input_identifier("external", fact, _id), do: "external:" <> to_string(fact["name"])
  defp input_identifier("generated", _fact, id), do: id
  defp input_identifier(_, _, _), do: nil

  defp validate_input_fact!("file", fact, _id, _inputs) do
    closed!(fact, ~w(path sha256 size executable mode))
    file!(Map.drop(fact, ["mode"]))
    mode!(fact["mode"])

    unless fact["executable"] == (Bitwise.band(fact["mode"], 0o111) != 0),
      do: raise(Error, "input mode mismatch")
  end

  defp validate_input_fact!("absence", fact, _id, _inputs) do
    closed!(fact, ["path"])
    CoreInventory.validate_path!(fact["path"])
  end

  defp validate_input_fact!(kind, fact, _id, inputs) when kind in ~w(tree glob) do
    closed!(fact, ~w(root pattern excludes matches))
    if fact["root"] != ".", do: CoreInventory.validate_path!(fact["root"])
    validate_watch_pattern!(kind, fact["pattern"])
    sets!(fact["excludes"])
    unique_sorted!(fact["matches"], "path")
    Enum.each(fact["matches"], &validate_watch_match!(&1, inputs))
  end

  defp validate_input_fact!("external", fact, _id, _inputs) do
    closed!(fact, ~w(name value_digest opaque))

    unless is_boolean(fact["opaque"]) and is_binary(fact["name"]),
      do: raise(Error, "invalid external fact")

    cond do
      fact["value_digest"] -> digest!(fact["value_digest"])
      fact["opaque"] -> :ok
      true -> raise Error, "missing external identity"
    end
  end

  defp validate_input_fact!("generated", fact, id, inputs) do
    unless String.starts_with?(id, "generated:"),
      do: raise(Error, "invalid generation identifier")

    CoreInventory.validate_path!(String.replace_prefix(id, "generated:", ""))
    closed!(fact, ~w(recipe version inputs))
    sets!(fact["inputs"])

    unless is_binary(fact["recipe"]) and fact["recipe"] != "" and
             is_integer(fact["version"]) and fact["version"] > 0,
           do: raise(Error, "invalid generation recipe")

    Enum.each(fact["inputs"], &reference!(inputs, &1))
  end

  defp validate_input_fact!(_, _, _, _), do: raise(Error, "unknown input kind")

  defp validate_watch_pattern!("tree", nil), do: :ok

  defp validate_watch_pattern!("glob", pattern) when is_binary(pattern),
    do: CoreInventory.validate_path!(pattern)

  defp validate_watch_pattern!(_, _), do: raise(Error, "invalid watch pattern")

  defp validate_watch_match!(match, inputs) do
    closed!(match, ~w(path type mode))
    CoreInventory.validate_path!(match["path"])
    mode!(match["mode"])
    unless match["type"] in ~w(file directory), do: raise(Error, "invalid watch kind")

    if match["type"] == "file" and not Map.has_key?(inputs, "file:" <> match["path"]),
      do: raise(Error, "missing watched file fact")
  end

  defp validate_entry!(entry, inputs) do
    closed!(entry, ~w(target kind roles owners origins full live package verify))
    CoreInventory.validate_path!(entry["target"])

    unless entry["kind"] == "file" and is_boolean(entry["package"]) and
             is_boolean(entry["verify"]) and
             (not entry["package"] or entry["verify"]),
           do: raise(Error, "invalid output role")

    sets!(entry["roles"])
    sets!(entry["owners"])
    sets!(entry["origins"])

    if entry["origins"] == [] or not Enum.all?(entry["roles"], &(&1 in @roles)),
      do: raise(Error, "missing output provenance or invalid role")

    for ref <- entry["origins"], do: reference!(inputs, ref)

    Enum.each(~w(full live), &validate_variant!(entry, &1, inputs))
  end

  defp validate_variant!(entry, kind, inputs) do
    value = entry[kind]
    closed!(value, ~w(strategy source content_sha256 size executable group))
    digest!(value["content_sha256"])
    size!(value["size"])

    unless is_boolean(value["executable"]) and value["strategy"] in ~w(copy write dedup link),
      do: raise(Error, "invalid output variant")

    if kind == "full" and value["strategy"] == "link",
      do: raise(Error, "full output cannot link")

    validate_variant_source!(value["strategy"], value, entry, inputs)
    validate_variant_group!(value["group"], value["strategy"])
  end

  defp validate_variant_source!("write", value, entry, _inputs) do
    unless is_nil(value["source"]), do: raise(Error, "write source must be null")

    unless ("generated:" <> entry["target"]) in entry["origins"],
      do: raise(Error, "write has no generation provenance")
  end

  defp validate_variant_source!(strategy, value, entry, inputs) do
    reference!(inputs, value["source"])

    unless input_describes_variant?(inputs[value["source"]], value),
      do: raise(Error, "output source mismatch")

    if strategy == "dedup" do
      originals = Enum.map(entry["origins"], &Map.fetch!(inputs, &1))

      unless length(originals) > 1 and Enum.all?(originals, &input_describes_variant?(&1, value)),
        do: raise(Error, "deduplicated origins differ")
    end
  end

  defp input_describes_variant?(%{"kind" => "file", "fact" => file}, value) do
    {file["sha256"], file["size"], file["executable"]} ==
      {value["content_sha256"], value["size"], value["executable"]}
  end

  defp input_describes_variant?(_, _), do: false

  defp validate_variant_group!(group, strategy) when group not in [false, nil] do
    closed!(group, ~w(source_root target_root))
    Enum.each(Map.values(group), &CoreInventory.validate_path!/1)
    unless strategy == "link", do: raise(Error, "invalid directory link group")
  end

  defp validate_variant_group!(_, _), do: :ok

  defp generated_acyclic!(id, inputs, ancestors) do
    if id in ancestors, do: raise(Error, "cyclic generation provenance")

    for reference <- inputs[id]["fact"]["inputs"],
        inputs[reference]["kind"] == "generated",
        do: generated_acyclic!(reference, inputs, [id | ancestors])

    :ok
  end

  def validate_file_records!(records) do
    unique_sorted!(records, "path")
    Enum.each(records, &file!/1)
    records
  end

  defp file!(file) do
    closed!(file, ~w(path sha256 size executable))
    CoreInventory.validate_path!(file["path"])
    digest!(file["sha256"])
    size!(file["size"])
    unless is_boolean(file["executable"]), do: raise(Error, "invalid file mode")
  end

  defp paths!(paths),
    do:
      (
        sets!(paths)
        Enum.each(paths, &CoreInventory.validate_path!/1)
      )

  defp digest!(value),
    do: unless(Identity.valid?(value), do: raise(Error, "invalid inventory digest"))

  defp size!(value),
    do: unless(is_integer(value) and value >= 0, do: raise(Error, "invalid size"))

  defp mode!(value),
    do:
      unless(is_integer(value) and value >= 0 and value <= 0o777,
        do: raise(Error, "invalid mode")
      )

  defp reference!(inputs, ref),
    do:
      unless(is_binary(ref) and Map.has_key?(inputs, ref),
        do: raise(Error, "missing input reference")
      )

  defp closed!(value, keys),
    do:
      unless(is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys),
        do: raise(Error, "invalid closed inventory record")
      )

  defp sets!(values),
    do:
      unless(
        is_list(values) and Enum.all?(values, &is_binary/1) and
          values == Enum.sort(Enum.uniq(values)),
        do: raise(Error, "invalid inventory set")
      )

  defp unique_sorted!(values, key) do
    unless is_list(values), do: raise(Error, "invalid inventory array")
    names = Enum.map(values, &Map.fetch!(&1, key))
    sets!(names)
  end
end
