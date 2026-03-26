defmodule Weld.ProjectGraph do
  @moduledoc """
  Loads selected Mix projects and normalizes their dependency relationships.
  """

  alias Weld.Manifest

  @enforce_keys [:projects, :external_deps]
  defstruct @enforce_keys

  defmodule Project do
    @moduledoc """
    Loaded metadata for one selected Mix project inside a projection graph.
    """

    @enforce_keys [
      :path,
      :abs_path,
      :app,
      :version,
      :deps,
      :elixirc_paths,
      :erlc_paths,
      :copy_dirs,
      :internal_deps
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            path: String.t(),
            abs_path: Path.t(),
            app: atom(),
            version: String.t(),
            deps: [tuple()],
            elixirc_paths: [String.t()],
            erlc_paths: [String.t()],
            copy_dirs: [String.t()],
            internal_deps: [atom()]
          }
  end

  @type t :: %__MODULE__{
          projects: %{String.t() => Project.t()},
          external_deps: [tuple()]
        }

  @spec load!(Manifest.t()) :: t()
  def load!(%Manifest{} = manifest) do
    projects =
      manifest.source_projects
      |> Enum.map(fn path -> load_project!(manifest, path) end)
      |> Map.new(fn project -> {project.path, project} end)

    selected_by_abs =
      projects
      |> Map.values()
      |> Map.new(fn project -> {project.abs_path, project.path} end)

    {projects, external_deps} =
      Enum.reduce(manifest.source_projects, {%{}, %{}}, fn path,
                                                           {acc_projects, acc_external_deps} ->
        project = Map.fetch!(projects, path)
        {internal_deps, external_deps} = classify_deps!(manifest, project, selected_by_abs)

        normalized_project = %{project | internal_deps: internal_deps}
        merged_external = merge_external_deps!(acc_external_deps, external_deps)

        {Map.put(acc_projects, path, normalized_project), merged_external}
      end)

    %__MODULE__{
      projects: projects,
      external_deps:
        external_deps
        |> Map.to_list()
        |> Enum.sort_by(fn {app, _dep} -> Atom.to_string(app) end)
        |> Enum.map(&elem(&1, 1))
    }
  end

  defp load_project!(manifest, path) do
    abs_path = Path.join(manifest.repo_root, path)
    mixfile = Path.join(abs_path, "mix.exs")

    unless File.regular?(mixfile) do
      raise Weld.Error, "source project #{path} is missing mix.exs"
    end

    config =
      case :persistent_term.get({__MODULE__, :config, abs_path}, :not_found) do
        :not_found ->
          loaded =
            Mix.Project.in_project(unique_probe_app(path), abs_path, [], fn _module ->
              Mix.Project.config()
            end)

          :persistent_term.put({__MODULE__, :config, abs_path}, loaded)
          loaded

        cached ->
          cached
      end

    %Project{
      path: path,
      abs_path: abs_path,
      app: Keyword.fetch!(config, :app),
      version: Keyword.fetch!(config, :version),
      deps: Keyword.get(config, :deps, []),
      elixirc_paths: normalize_paths(Keyword.get(config, :elixirc_paths, ["lib"])),
      erlc_paths: normalize_paths(Keyword.get(config, :erlc_paths, ["src"])),
      copy_dirs: copy_dirs(abs_path),
      internal_deps: []
    }
  end

  defp unique_probe_app(path) do
    suffix =
      path
      |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
      |> String.downcase()

    String.to_atom("weld_probe_#{suffix}_#{System.unique_integer([:positive])}")
  end

  defp normalize_paths(paths) when is_list(paths), do: paths
  defp normalize_paths(path) when is_binary(path), do: [path]

  defp copy_dirs(abs_path) do
    ["lib", "priv", "src", "c_src", "include"]
    |> Enum.filter(&File.dir?(Path.join(abs_path, &1)))
  end

  defp classify_deps!(manifest, project, selected_by_abs) do
    Enum.reduce(project.deps, {[], []}, fn dep, {internal_acc, external_acc} ->
      normalized = normalize_dep(dep)
      opts = normalized.opts

      cond do
        opts[:path] ->
          handle_path_dep!(
            manifest,
            project,
            normalized,
            selected_by_abs,
            internal_acc,
            external_acc
          )

        opts[:git] || opts[:github] ->
          raise Weld.Error,
                "project #{project.path} has unsupported git dependency #{normalized.app}"

        true ->
          {internal_acc, [normalized.original | external_acc]}
      end
    end)
    |> then(fn {internal_deps, external_deps} ->
      {Enum.reverse(internal_deps), Enum.reverse(external_deps)}
    end)
  end

  defp handle_path_dep!(
         manifest,
         project,
         normalized,
         selected_by_abs,
         internal_acc,
         external_acc
       ) do
    dep_path = Path.expand(normalized.opts[:path], project.abs_path)
    relative_dep_path = Path.relative_to(dep_path, manifest.repo_root)

    cond do
      Map.has_key?(selected_by_abs, dep_path) ->
        {[normalized.app | internal_acc], external_acc}

      String.starts_with?(relative_dep_path, "..") ->
        raise Weld.Error,
              "project #{project.path} has unsupported external path dependency #{normalized.app}"

      File.regular?(Path.join(dep_path, "mix.exs")) ->
        raise Weld.Error,
              "project #{project.path} depends on unselected sibling project #{relative_dep_path}"

      true ->
        raise Weld.Error,
              "project #{project.path} has unresolved path dependency #{normalized.app}"
    end
  end

  defp merge_external_deps!(acc, deps) do
    Enum.reduce(deps, acc, fn dep, dep_acc ->
      {app, req, opts} = dep_to_triplet(dep)
      comparable = {req, Keyword.drop(opts, [:path, :git, :github])}

      merge_external_dep!(dep_acc, dep, app, comparable)
    end)
  end

  defp merge_external_dep!(dep_acc, dep, app, comparable) do
    case Map.get(dep_acc, app) do
      nil ->
        Map.put(dep_acc, app, dep)

      existing ->
        if comparable == comparable_dep(existing) do
          dep_acc
        else
          raise Weld.Error, "conflicting external dependency requirements for #{app}"
        end
    end
  end

  defp comparable_dep(dep) do
    {_app, req, opts} = dep_to_triplet(dep)
    {req, Keyword.drop(opts, [:path, :git, :github])}
  end

  defp dep_to_triplet({app, requirement, opts}) when is_atom(app) and is_list(opts),
    do: {app, requirement, opts}

  defp dep_to_triplet({app, opts}) when is_atom(app) and is_list(opts),
    do: {app, nil, opts}

  defp normalize_dep({app, requirement, opts}) when is_atom(app) and is_list(opts) do
    %{app: app, requirement: requirement, opts: opts, original: {app, requirement, opts}}
  end

  defp normalize_dep({app, opts}) when is_atom(app) and is_list(opts) do
    %{app: app, requirement: nil, opts: opts, original: {app, opts}}
  end

  defp normalize_dep(other) do
    raise Weld.Error, "unsupported dependency shape: #{inspect(other)}"
  end
end
