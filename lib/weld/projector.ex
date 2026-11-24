defmodule Weld.Projector do
  @moduledoc """
  Generates the welded Mix project and its initial lockfile.
  """

  @root_tooling_files [".formatter.exs", ".credo.exs", ".dialyzer_ignore.exs"]

  alias Weld.Config.Generator
  alias Weld.Error
  alias Weld.Git
  alias Weld.Hash
  alias Weld.Lockfile
  alias Weld.Output
  alias Weld.Plan
  alias Weld.Plan.Inventory
  alias Weld.Projector.Monolith
  alias Weld.Projector.Live
  alias Weld.Projector.SourceProject
  alias Weld.SourceFormatter

  @spec project!(Plan.t(), keyword()) :: map()
  def project!(%Plan{} = plan, opts \\ []) do
    Weld.Output.with_lock(plan.manifest.repo_root, fn -> project_locked!(plan, opts) end)
  end

  defp project_locked!(plan, opts) do
    Plan.ensure_valid!(plan)
    kind = if opts[:live], do: :live, else: :full

    root = plan.manifest.repo_root
    validate_inputs!(plan)
    target = build_path(plan, kind)
    stage = Output.temporary!(root, "staging")

    try do
      projection =
        case plan.artifact.mode do
          :source_project -> SourceProject.project!(plan, stage, kind)
          _ -> project_by_mode!(plan, stage, kind)
        end

      linked = Map.get(projection, :linked_files, [])
      inventory =
        (Hash.list_files(stage) |> Enum.map(&Path.relative_to(&1, stage)))
        |> Kernel.++(linked)
        |> Enum.uniq()
        |> Enum.sort()

      files = inventory -- linked
      tree_digest = write_marker!(stage, plan.artifact.id, kind)

      projection =
        Map.merge(projection, %{
          copied_files: files,
          linked_files: linked,
          verification_files: inventory,
          build_path: target,
          git_revision: Git.revision(root),
          tree_digest: tree_digest
        })

      lockname = "projection.lock.json"
      lockfile = Lockfile.build(plan, projection, [])
      File.write!(Path.join(stage, lockname), Lockfile.encode!(lockfile), [:exclusive])
      reject_published_reports!(stage, projection)
      Output.activate!(stage, target, &managed?(&1, plan.artifact.id, kind))
      Map.put(projection, :lockfile_path, Path.join(target, lockname))
    after
      File.rm_rf!(stage)
    end
  end

  defp reject_published_reports!(stage, %{package_patterns: patterns}) do
    paths = Enum.flat_map(patterns, fn pattern ->
      Path.wildcard(Path.join(stage, pattern), match_dot: true)
      |> Enum.flat_map(fn path -> if File.dir?(path), do: Hash.list_files(path), else: [path] end)
    end)

    for report <- ~w(weld.provenance.json projection.lock.json), Path.join(stage, report) in paths do
      raise Error, "native package allowlist includes generated publication metadata: #{report}"
    end
  end

  defp reject_published_reports!(_stage, _projection), do: :ok

  defp write_marker!(stage, artifact, kind) do
    marker = %{schema: "weld.projection/v1", artifact: artifact, kind: kind}
    {marker, digest} = projection_digests!(stage, kind, marker)

    File.write!(Path.join(stage, "weld.provenance.json"), Jason.encode!(marker, pretty: true), [
      :exclusive
    ])

    digest
  end

  defp projection_digests!(stage, :full, marker) do
    Output.reject_tree_links!(stage)
    {Map.put(marker, :artifact_id, Hash.content_identity(stage)), Hash.sha256_tree(stage)}
  end

  defp projection_digests!(_stage, :live, marker), do: {marker, nil}

  defp validate_inputs!(plan) do
    root = plan.manifest.repo_root
    artifact = plan.artifact

    if artifact.mode != :source_project do
      for path <- artifact.output.docs ++ artifact.output.assets do
        if hd(Path.split(path)) in ~w(mix.exs mix.lock doc config components test lib src c_src include weld.provenance.json projection.lock.json) do
          raise Error, "output path overlaps generated project files: #{path}"
        end
      end
    end

    for path <-
          artifact.output.docs ++
            artifact.output.assets ++
            artifact.verify.artifact_tests ++
            List.wrap(artifact.verify.smoke.entry_file) do
      root |> Output.source!(path) |> Output.reject_tree_links!()
    end

    if artifact.mode != :source_project do
      for project <- Plan.projects_for_view(plan, :test) do
        include_suite? = artifact.mode == :monolith or Plan.selected?(plan, project.id)
        validate_project_inputs!(root, project, include_suite?)
      end
    end
  end

  defp validate_project_inputs!(root, project, include_suite?) do
    if project.id != ".", do: Output.source!(root, project.id)

    suite_paths =
      if include_suite? do
        project.test_elixirc_paths ++ project.test_erlc_paths ++ project.test_paths ++ ["config", "test"]
      else
        []
      end

    for dir <- Enum.uniq(project.copy_dirs ++ project.elixirc_paths ++ project.erlc_paths ++
                 [project.erlc_include_path] ++ suite_paths) do
      relative = Path.relative_to(Path.expand(dir, project.abs_path), project.abs_path)
      project.abs_path |> Output.source!(relative) |> Output.reject_tree_links!()
    end
  end

  defp managed?(target, artifact, kind) do
    path = Path.join(target, "weld.provenance.json")
    Output.reject_link!(path)

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"schema" => "weld.projection/v1", "artifact" => ^artifact, "kind" => value}} <-
           Jason.decode(bytes) do
      value == Atom.to_string(kind)
    else
      _ -> false
    end
  end

  @doc false
  def with_output_lock(%Plan{} = plan, fun), do: Output.with_lock(plan.manifest.repo_root, fun)

  @spec build_path(Plan.t(), :live | :full) :: Path.t()
  def build_path(plan, kind \\ :full)

  def build_path(%Plan{} = plan, :full),
    do: Output.path(plan.manifest.repo_root, ["full", plan.artifact.id, "project"])

  def build_path(%Plan{} = plan, :live),
    do: Output.path(plan.manifest.repo_root, ["live", plan.artifact.id])

  @spec package_files(Plan.t(), keyword()) :: [String.t()]
  def package_files(%Plan{} = plan, opts \\ []) do
    component_roots =
      plan.selected_projects
      |> Enum.flat_map(fn project ->
        runtime_roots(project)
        |> Enum.map(&Path.join(["components", component_dir(project), &1]))
      end)

    ["mix.exs"]
    |> Kernel.++(generated_root_paths(plan, opts))
    |> Kernel.++(component_roots)
    |> Kernel.++(root_tooling_files(plan))
    |> Kernel.++(plan.artifact.output.docs)
    |> Kernel.++(plan.artifact.output.assets)
    |> Enum.uniq()
    |> List.delete("projection.lock.json")
    |> Enum.sort()
  end

  @spec root_tooling_candidates() :: [String.t()]
  def root_tooling_candidates, do: @root_tooling_files

  @spec root_tooling_files(Plan.t()) :: [String.t()]
  def root_tooling_files(%Plan{} = plan) do
    @root_tooling_files
    |> Enum.filter(&File.regular?(Path.join(plan.manifest.repo_root, &1)))
  end

  @doc false
  @spec docs_options(Plan.t()) :: keyword()
  def docs_options(%Plan{} = plan) do
    docs = plan.artifact.package.docs

    extras =
      Enum.map(plan.artifact.output.docs, fn path ->
        case docs.extra_titles do
          %{^path => title} -> {path, [title: title]}
          _titles -> path
        end
      end)

    [main: docs.main, extras: extras]
    |> maybe_put_docs_option(:logo, docs.logo)
    |> maybe_put_docs_option(:homepage_url, docs.homepage_url)
    |> maybe_put_docs_option(:source_url, docs.source_url)
    |> maybe_put_docs_option(:source_ref, docs.source_ref)
    |> maybe_put_docs_option(:assets, docs.assets)
    |> maybe_put_docs_option(:groups_for_extras, docs.groups_for_extras)
  end

  @doc false
  def render_docs_options(%Plan{} = plan) do
    options = inspect(docs_options(plan), pretty: true, limit: :infinity)

    if plan.artifact.package.docs.mermaid do
      hook = """
      <script src="https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js"></script>
      <script>
      document.addEventListener("DOMContentLoaded", () => {
        const diagrams = document.querySelectorAll("pre code.mermaid");
        if (!diagrams.length || !window.mermaid) return;
        mermaid.initialize({startOnLoad: false, securityLevel: "strict"});
        for (const code of diagrams) {
          const diagram = document.createElement("div");
          diagram.className = "mermaid";
          diagram.textContent = code.textContent;
          code.parentElement.replaceWith(diagram);
        }
        mermaid.run();
      });
      </script>
      """

      "Keyword.put(#{options}, :before_closing_body_tag, fn :html -> #{inspect(hook)}; _ -> \"\" end)"
    else
      options
    end
  end

  defp copy_artifact_tests!(plan, build_path, relative_path) do
    source = Path.join(plan.manifest.repo_root, relative_path)

    unless File.dir?(source) do
      raise Error, "artifact test path not found: #{relative_path}"
    end

    target = Path.join(build_path, "test")
    File.mkdir_p!(target)

    source
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn child ->
      child_source = Path.join(source, child)
      child_target = Path.join(target, child)

      if File.exists?(child_target),
        do: raise(Error, "artifact test collision at test/#{child}")

      if File.dir?(child_source) do
        File.cp_r!(child_source, child_target)
      else
        File.cp!(child_source, child_target)
      end

      child_target
      |> list_copied_paths()
      |> Enum.map(&Path.relative_to(&1, build_path))
    end)
  end

  defp project_by_mode!(%Plan{artifact: %{mode: :monolith}} = plan, build_path, kind) do
    Monolith.project!(plan, build_path, kind: kind)
  end

  defp project_by_mode!(%Plan{} = plan, build_path, kind) do
    validate_component_test_paths!(plan)
    validate_include_paths!(Plan.projects_for_view(plan, :test))
    compiler_roots = Enum.flat_map(plan.selected_projects, fn project ->
      Enum.map(project.elixirc_paths, &Path.expand(&1, project.abs_path))
    end)
    SourceProject.validate_modules!(compiler_roots)
    repo_infos = detect_repo_infos(plan.selected_projects)

    config_merge =
      Generator.generate!(
        plan.selected_projects,
        build_path,
        repo_infos,
        package_repo_layout(plan.selected_projects),
        shared_test_configs: Enum.map(plan.selected_projects, & &1.id),
        root_config_overlays:
          List.wrap(root_ecto_repos_overlay(repo_infos, plan.artifact.package.otp_app))
      )

    roots = Enum.reject(plan.source_roots, &(&1.target == "test" and not plan.artifact.verify.component_tests))
    materialized = Enum.flat_map(roots, &materialize_root!(plan, build_path, &1, kind))

    copied_tests = if plan.artifact.verify.component_tests do
      []
    else
      Enum.flat_map(plan.artifact.verify.artifact_tests, &copy_artifact_tests!(plan, build_path, &1))
    end

    test_paths = projected_test_paths(plan)
    for path <- test_paths do
      unless File.regular?(Path.join([build_path, path, "test_helper.exs"])),
        do: raise(Error, "projected test path requires test_helper.exs: #{path}")
    end

    ensure_readme!(plan, build_path)

    generation_opts = [
        bootstrapped_apps: config_merge.bootstrapped_apps,
        bootstrapped_config_sources: config_merge.bootstrapped_sources,
        generate_config?: true,
        live?: kind == :live,
        live_guard: if(kind == :live, do: Live.guard_source(plan,
          directories: Enum.map(roots, &Path.join(plan.manifest.repo_root, &1.source)),
          digests: Enum.flat_map(plan.artifact.verify.artifact_tests, fn path ->
            if plan.artifact.verify.component_tests, do: [], else: Hash.list_files(Path.join(plan.manifest.repo_root, path))
          end),
          topology: if(plan.artifact.verify.component_tests, do: [], else: Enum.map(plan.artifact.verify.artifact_tests, &Path.join(plan.manifest.repo_root, &1)))
        ), else: "")
      ]

    generated_files = render_generated_files!(plan, build_path, generation_opts)

    render_mixfile!(plan, build_path, generation_opts)

    %{
      copied_files:
        (materialized ++
           copied_tests ++
           config_merge.copied_files ++ generated_files)
        |> Enum.uniq()
        |> Enum.sort(),
      package_files:
        package_files(plan, generation_opts),
      linked_files: if(kind == :live, do: Enum.sort(materialized), else: [])
    }
  end

  defp render_mixfile!(plan, build_path, opts) do
    File.write!(
      Path.join(build_path, "mix.exs"),
      mixfile_contents(plan, opts) |> SourceFormatter.format!(),
      [:exclusive]
    )
  end

  defp materialize_root!(plan, build_path, entry, kind) do
    source = Output.source!(plan.manifest.repo_root, entry.source)
    target = Output.source!(build_path, entry.target)
    Output.reject_tree_links!(source)

    unless File.exists?(source), do: raise(Error, "missing planned source: #{entry.source}")
    if File.exists?(target), do: raise(Error, "projection path collision: #{entry.target}")
    File.mkdir_p!(Path.dirname(target))

    files = if File.dir?(source), do: Hash.list_files(source), else: [source]
    projected = Enum.map(files, fn path ->
      if path == source, do: entry.target, else: Path.join(entry.target, Path.relative_to(path, source))
    end)

    case kind do
      :full -> File.cp_r!(source, target)
      :live ->
        case File.ln_s(source, target) do
          :ok -> :ok
          {:error, reason} -> raise Error, "live projection needs symlink support for #{entry.target}: #{reason}"
        end
    end

    projected
  end

  defp runtime_roots(project) do
    Inventory.normalize_paths(project,
      project.copy_dirs ++ project.elixirc_paths ++ project.erlc_paths ++ [project.erlc_include_path])
    |> Enum.uniq()
    |> Enum.filter(&File.dir?(Path.expand(&1, project.abs_path)))
    |> then(fn roots ->
      Enum.reject(roots, fn path ->
        Enum.any?(roots, &(&1 != path and String.starts_with?(path, &1 <> "/")))
      end)
    end)
    |> Enum.sort()
  end

  defp projected_test_paths(%Plan{artifact: %{verify: %{component_tests: false}}} = plan) do
    if plan.artifact.verify.artifact_tests == [], do: [], else: ["test"]
  end

  defp projected_test_paths(plan) do
    components =
      plan.selected_projects
      |> Enum.flat_map(fn project ->
        Inventory.normalize_paths(project, project.test_paths)
        |> Enum.filter(&File.dir?(Path.expand(&1, project.abs_path)))
        |> Enum.map(&Path.join(["components", component_dir(project), &1]))
      end)

    artifacts =
      plan.artifact.verify.artifact_tests
      |> Enum.with_index(1)
      |> Enum.map(fn {_path, index} -> "test/artifact_#{index}" end)

    Enum.uniq(components ++ artifacts)
  end

  defp component_test_compile_paths(%Plan{artifact: %{verify: %{component_tests: false}}}), do: []

  defp component_test_compile_paths(plan) do
    Plan.projects_for_view(plan, :test)
    |> Enum.flat_map(fn project ->
      paths = if Plan.selected?(plan, project.id), do: project.test_elixirc_paths, else: project.elixirc_paths

      project
      |> Inventory.normalize_paths(paths)
      |> Enum.filter(&File.dir?(Path.expand(&1, project.abs_path)))
      |> Enum.map(&Path.join(["components", component_dir(project), &1]))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp component_test_erlc_paths(%Plan{artifact: %{verify: %{component_tests: false}}}, runtime), do: runtime

  defp component_test_erlc_paths(plan, _runtime) do
    Plan.projects_for_view(plan, :test)
    |> Enum.flat_map(fn project ->
      paths = if Plan.selected?(plan, project.id), do: project.test_erlc_paths, else: project.erlc_paths

      project
      |> Inventory.normalize_paths(paths)
      |> Enum.map(&Path.join(["components", component_dir(project), &1]))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp package_external_deps(%Plan{artifact: %{verify: %{component_tests: false}}} = plan), do: plan.external_deps

  defp package_external_deps(plan) do
    runtime_apps = Enum.map(plan.external_deps, & &1.app)

    test_deps =
      plan
      |> Plan.external_deps_for_view(:test)
      |> Enum.reject(&(&1.app in runtime_apps))
      |> Enum.map(fn dep ->
        opts = Keyword.put_new(dep.opts, :only, :test)
        original = if dep.requirement, do: {dep.app, dep.requirement, opts}, else: {dep.app, opts}
        %{dep | opts: opts, original: original}
      end)

    plan.external_deps ++ test_deps
  end

  defp validate_component_test_paths!(%Plan{artifact: %{verify: %{component_tests: false}}}), do: :ok

  defp validate_component_test_paths!(plan) do
    for project <- plan.selected_projects do
      compiled = Inventory.normalize_paths(project, project.elixirc_paths ++ project.erlc_paths)
      test_compiled = Inventory.normalize_paths(project,
        project.test_elixirc_paths ++ project.test_erlc_paths) -- compiled
      tests = Inventory.normalize_paths(project, project.test_paths) ++ test_compiled

      for runtime <- runtime_roots(project), test <- tests,
          Inventory.covered?(test, runtime) or Inventory.covered?(runtime, test) do
        raise Error,
              "component #{project.id} test input overlaps a published runtime root: #{test}"
      end
    end
  end

  defp render_paths(paths, opts) do
    if opts[:live?] do
      "Enum.map(#{inspect(paths)}, &Path.expand(&1, __DIR__))"
    else
      inspect(paths)
    end
  end

  defp render_generated_files!(plan, build_path, opts) do
    case generated_application(plan, opts) do
      %{module: nil} ->
        []

      application ->
        relative_path = generated_application_relative_path(plan)
        target = Path.join(build_path, relative_path)
        File.mkdir_p!(Path.dirname(target))

        File.write!(
          target,
          application_module_contents(application, plan.artifact.package.otp_app)
          |> SourceFormatter.format!(),
          [:exclusive]
        )

        [relative_path]
    end
  end

  defp ensure_readme!(plan, build_path) do
    readme = Path.join(build_path, "README.md")

    unless File.exists?(readme) do
      File.write!(readme, "# #{plan.artifact.package.name}\n")
    end
  end

  defp mixfile_contents(plan, opts) do
    package = plan.artifact.package
    module_name = "#{Macro.camelize(to_string(package.otp_app))}.MixProject"
    application = generated_application(plan, opts)
    elixirc_paths = component_paths(plan.selected_projects, & &1.elixirc_paths, plan, opts)
    erlc_paths = component_paths(plan.selected_projects, & &1.erlc_paths)
    test_paths = projected_test_paths(plan)
    test_compile_paths = component_test_compile_paths(plan)
    test_elixirc_paths =
      if plan.artifact.verify.component_tests,
        do: Enum.uniq(generated_root_paths(plan, opts) ++ test_compile_paths),
        else: elixirc_paths
    test_erlc_paths = component_test_erlc_paths(plan, erlc_paths)
    include_paths = component_include_paths(plan.selected_projects)
    test_include_paths = if plan.artifact.verify.component_tests,
      do: component_include_paths(Plan.projects_for_view(plan, :test)), else: include_paths
    deps = render_deps(package_external_deps(plan), package.development_dependencies)
    files = package_files(plan, opts) |> Enum.map_join(",\n        ", &inspect/1)
    docs = render_docs_options(plan)
    links = package.links |> fallback_links(plan.manifest.repo_root) |> inspect(pretty: true)
    application_config = application_config_literal(application)

    """
    defmodule #{module_name} do
      use Mix.Project

      def project do
        #{opts[:live_guard] || ""}
        [
          app: #{inspect(package.otp_app)},
          version: #{inspect(package.version)},
          #{if(opts[:live?], do: "", else: "build_path: \"_build\",")}
          elixir: #{inspect(package.elixir)},
          start_permanent: Mix.env() == :prod,
          elixirc_paths: elixirc_paths(Mix.env()),
          erlc_paths: erlc_paths(Mix.env()),
          erlc_options: erlc_options(Mix.env()),
          test_paths: #{render_paths(test_paths, opts)},
          #{if(opts[:live?], do: "aliases: #{Live.aliases_source()},", else: "")}
          deps: deps(),
          description: #{inspect(package.description)},
          package: package(),
          docs: docs()
        ]
      end

      def application do
        #{application_config}
      end

      def elixirc_paths(:test) do
        base = #{render_paths(test_elixirc_paths, opts)}

        if File.dir?(Path.expand("test/support", __DIR__)) do
          base ++ [#{if(opts[:live?], do: "Path.expand(\"test/support\", __DIR__)", else: "\"test/support\"")}]
        else
          base
        end
      end

      def elixirc_paths(_env), do: #{render_paths(elixirc_paths, opts)}

      defp erlc_paths(:test), do: #{render_paths(test_erlc_paths, opts)}
      defp erlc_paths(_env), do: #{render_paths(erlc_paths, opts)}

      defp erlc_options(env) do
        paths = if env == :test, do: #{inspect(test_include_paths)}, else: #{inspect(include_paths)}
        Enum.map(paths, fn path -> {:i, path |> Path.expand(__DIR__) |> String.to_charlist()} end)
      end

      defp deps do
        [
    #{deps}
        ]
      end

      defp package do
        [
          licenses: #{inspect(package.licenses)},
          maintainers: #{inspect(package.maintainers)},
          links: #{links},
          files: [
            #{files}
          ]
        ]
      end

      defp docs do
        #{docs}
      end
    end
    """
  end

  defp component_paths(projects, path_fun, plan \\ nil, opts \\ []) do
    root_paths =
      case generated_root_paths(plan, opts) do
        [] -> []
        root_paths -> root_paths
      end

    root_paths ++
      (projects
       |> Enum.flat_map(fn project ->
         project
         |> Inventory.normalize_paths(path_fun.(project))
         |> Enum.map(fn relative ->
           Path.join(["components", component_dir(project), relative])
         end)
       end)
       |> Enum.uniq()
       |> Enum.sort())
  end

  defp component_include_paths(projects) do
    for project <- projects,
        relative <- Inventory.normalize_paths(project, [project.erlc_include_path]),
        File.dir?(Path.expand(relative, project.abs_path)),
        do: Path.join(["components", component_dir(project), relative])
  end

  defp validate_include_paths!(projects) do
    headers = for project <- projects,
      root = Path.expand(project.erlc_include_path, project.abs_path),
      File.dir?(root), path <- Hash.list_files(root),
      do: {Path.relative_to(path, root), path}

    for {relative, files} <- Enum.group_by(headers, &elem(&1, 0), &elem(&1, 1)) do
      if length(Enum.uniq_by(files, &Hash.sha256_file/1)) > 1,
        do: raise(Error, "conflicting Erlang include #{relative} across selected projects")
    end
  end

  defp render_deps(external_deps, development_dependencies) do
    external = Enum.map(external_deps, fn dep -> dep.original end)

    (external ++ development_dependencies ++ [{:ex_doc, "~> 0.40", only: :dev, runtime: false}])
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map_join(",\n      ", &inspect/1)
  end

  defp fallback_links(links, _repo_root) when map_size(links) > 0, do: links

  defp fallback_links(_links, repo_root) do
    case Git.remote_url(repo_root) do
      nil -> %{"Source" => "https://github.com/nshkrdotcom/weld"}
      remote -> %{"Source" => remote}
    end
  end

  defp maybe_put_docs_option(options, _key, nil), do: options
  defp maybe_put_docs_option(options, _key, empty) when empty in [%{}, []], do: options
  defp maybe_put_docs_option(options, key, value), do: Keyword.put(options, key, value)

  defp generated_root_paths(nil, _opts), do: []

  defp generated_root_paths(plan, opts) do
    []
    |> maybe_add_generated_root_path(
      case generated_application(plan, opts) do
        %{module: nil} -> nil
        _application -> "lib"
      end
    )
    |> maybe_add_generated_root_path(
      if(Keyword.get(opts, :generate_config?, false), do: "config")
    )
  end

  defp generated_application(%Plan{} = plan, opts) do
    children =
      plan.selected_projects
      |> Enum.map(& &1.application.mod)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    bootstrapped_apps =
      opts
      |> Keyword.get(:bootstrapped_apps, [])
      |> Enum.uniq()
      |> Enum.sort()

    bootstrapped_sources =
      opts
      |> Keyword.get(:bootstrapped_config_sources, [])
      |> Enum.uniq()

    %{
      module:
        if(children == [] and bootstrapped_sources == [],
          do: nil,
          else:
            Module.concat([
              Macro.camelize(to_string(plan.artifact.package.otp_app)),
              "Application"
            ])
        ),
      bootstrapped_apps: bootstrapped_apps,
      bootstrapped_sources: bootstrapped_sources,
      children: children,
      extra_applications:
        plan.selected_projects
        |> Enum.flat_map(& &1.application.extra_applications)
        |> Kernel.++([:logger])
        |> Enum.uniq()
        |> Enum.sort(),
      included_applications:
        plan.selected_projects
        |> Enum.flat_map(& &1.application.included_applications)
        |> Enum.uniq()
        |> Enum.sort(),
      registered:
        plan.selected_projects
        |> Enum.flat_map(& &1.application.registered)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp application_config_literal(application) do
    [
      extra_applications: application.extra_applications
    ]
    |> maybe_put_config(:included_applications, application.included_applications)
    |> maybe_put_config(:registered, application.registered)
    |> maybe_put_config(:mod, if(application.module, do: {application.module, []}))
    |> inspect(pretty: true, limit: :infinity)
  end

  defp maybe_put_config(config, _key, nil), do: config
  defp maybe_put_config(config, _key, []), do: config
  defp maybe_put_config(config, key, value), do: Keyword.put(config, key, value)

  defp generated_application_relative_path(plan) do
    otp_app = to_string(plan.artifact.package.otp_app)
    Path.join(["lib", otp_app, "application.ex"])
  end

  defp application_module_contents(
         %{
           module: module,
           bootstrapped_apps: bootstrapped_apps,
           bootstrapped_sources: bootstrapped_sources,
           children: children
         },
         _artifact_otp_app
       ) do
    rendered_children =
      children
      |> Enum.map_join(",\n      ", fn {child_module, args} ->
        """
        %{
          id: #{inspect(child_module)},
          start: {#{inspect(child_module)}, :start, [:normal, #{inspect(args)}]},
          type: :supervisor
        }\
        """
      end)

    bootstrap_helpers =
      if bootstrapped_sources == [] do
        ""
      else
        """

          @boot_env Mix.env()
          @bootstrapped_apps #{inspect(bootstrapped_apps)}
          @bootstrapped_sources #{inspect(bootstrapped_sources, pretty: true, limit: :infinity)}

          defp bootstrap_workspace_app_env! do
            Enum.each(@bootstrapped_sources, fn source ->
              source
              |> bootstrap_source_paths()
              |> Enum.each(&apply_bootstrap_source!/1)
            end)
          end

          defp bootstrap_source_paths(%{
                 config_path: config_path,
                 env_path_fallbacks: env_path_fallbacks,
                 runtime_path: runtime_path
               }) do
            []
            |> maybe_add_bootstrap_path(config_path || Map.get(env_path_fallbacks, @boot_env))
            |> maybe_add_bootstrap_path(runtime_path)
          end

          defp maybe_add_bootstrap_path(paths, nil), do: paths
          defp maybe_add_bootstrap_path(paths, path), do: paths ++ [path]

          defp apply_bootstrap_source!(relative_path) do
            absolute_path = artifact_path(relative_path)

            unless File.regular?(absolute_path) do
              raise "missing projected workspace config source: \#{absolute_path}"
            end

            {config, _imports} = Config.Reader.read_imports!(absolute_path, env: @boot_env)

            config
            |> Enum.filter(fn {app, _value} -> app in @bootstrapped_apps end)
            |> case do
              [] -> :ok
              workspace_config -> Application.put_all_env(workspace_config, persistent: true)
            end
          end

          defp artifact_path(relative_path) do
            Path.expand(Path.join(["..", "..", relative_path]), __DIR__)
          end
        """
      end

    """
    defmodule #{inspect(module)} do
      @moduledoc false

      use Application

      def start(_type, _args) do
        #{if(bootstrapped_sources == [], do: ":ok", else: "bootstrap_workspace_app_env!()")}

        children = [
          #{rendered_children}
        ]

        Supervisor.start_link(children,
          strategy: :one_for_one,
          name: __MODULE__.Supervisor
        )
      end
    #{bootstrap_helpers}
    end
    """
  end

  def detect_repo_infos(projects) do
    projects
    |> Enum.flat_map(fn project ->
      lib_root = Path.join(project.abs_path, "lib")

      if File.dir?(lib_root) do
        lib_root
        |> Hash.list_files()
        |> Enum.filter(&(Path.extname(&1) == ".ex"))
        |> Enum.flat_map(&repo_info_from_file(&1, project))
      else
        []
      end
    end)
  end

  defp root_ecto_repos_overlay([], _artifact_otp_app), do: nil

  defp root_ecto_repos_overlay(repo_infos, artifact_otp_app) do
    """
    config #{inspect(artifact_otp_app)},
      ecto_repos: #{inspect(Enum.map(repo_infos, & &1.module))}
    """
  end

  defp package_repo_layout(projects) do
    repo_paths =
      projects
      |> Enum.filter(&File.dir?(Path.join(&1.abs_path, "priv/repo")))
      |> Map.new(fn project ->
        {project.id, Path.join(["components", component_dir(project), "priv/repo"])}
      end)

    %{repo_paths: repo_paths}
  end

  defp maybe_add_generated_root_path(paths, nil), do: paths
  defp maybe_add_generated_root_path(paths, path), do: paths ++ [path]

  defp repo_info_from_file(path, project) do
    contents = File.read!(path)

    if String.contains?(contents, "use Ecto.Repo") do
      module =
        case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)\s+do/, contents, capture: :all_but_first) do
          [module] -> Module.concat([module])
          _ -> raise Error, "unable to parse Ecto repo module from #{path}"
        end

      otp_app =
        case Regex.run(~r/otp_app:\s*:(\w+)/, contents, capture: :all_but_first) do
          [otp_app] -> String.to_atom(otp_app)
          _ -> raise Error, "unable to parse Ecto repo otp_app from #{path}"
        end

      [
        %{
          project_id: project.id,
          module: module,
          otp_app: otp_app
        }
      ]
    else
      []
    end
  end

  defp component_dir(%{id: "."}), do: "root"
  defp component_dir(%{id: id}), do: id

  defp list_copied_paths(path) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> Weld.Hash.list_files(path)
      true -> []
    end
  end
end
