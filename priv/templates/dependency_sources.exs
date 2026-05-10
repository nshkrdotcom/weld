defmodule DependencySources do
  @moduledoc false

  @helper_version 1
  @source_keys [:path, :github, :hex]

  def helper_version, do: @helper_version

  def deps(repo_root \\ Path.dirname(__DIR__), opts \\ []) do
    repo_root = Path.expand(repo_root)
    config = load_config!(Path.join(repo_root, "build_support/dependency_sources.config.exs"))
    overrides = load_local_overrides(repo_root)
    publish? = Keyword.get(opts, :publish?, publish_mode?())

    config
    |> deps_config()
    |> Enum.map(fn {app, dep_config} ->
      app = normalize_app!(app)
      dep_config = normalize_dep_config!(dep_config)
      source = selected_source!(app, dep_config, overrides, publish?, repo_root)
      dep_tuple(app, dep_config, source, repo_root)
    end)
  end

  defp load_config!(path) do
    {config, _binding} = Code.eval_file(path)

    unless is_map(config) or Keyword.keyword?(config) do
      raise ArgumentError, "dependency source config must evaluate to a map or keyword list"
    end

    config
  end

  defp load_local_overrides(repo_root) do
    path = Path.join(repo_root, ".dependency_sources.local.exs")

    if File.regular?(path) do
      {overrides, _binding} = Code.eval_file(path)
      Map.new(overrides[:deps] || overrides["deps"] || %{})
    else
      %{}
    end
  end

  defp deps_config(config) do
    deps = config[:deps] || config["deps"] || config
    Map.new(deps)
  end

  defp normalize_app!(app) when is_atom(app), do: app
  defp normalize_app!(app) when is_binary(app), do: String.to_atom(app)

  defp normalize_dep_config!(config) when is_map(config), do: config
  defp normalize_dep_config!(config) when is_list(config), do: Map.new(config)

  defp selected_source!(app, config, overrides, publish?, repo_root) do
    override = overrides[app] || overrides[Atom.to_string(app)] || %{}
    override_source = override[:source] || override["source"]

    cond do
      override_source ->
        normalize_source!(override_source)

      publish? ->
        source_from_order!(
          app,
          config,
          config[:publish_order] || config["publish_order"] || [:hex],
          repo_root
        )

      true ->
        source_from_order!(
          app,
          config,
          config[:default_order] || config["default_order"] || [:path, :github, :hex],
          repo_root
        )
    end
  end

  defp source_from_order!(app, config, order, repo_root) do
    order
    |> Enum.map(&normalize_source!/1)
    |> Enum.find(fn
      :path -> configured_path_available?(config, repo_root)
      source -> configured?(config, source)
    end)
    |> case do
      nil -> raise ArgumentError, "no dependency source is available for #{app}"
      source -> source
    end
  end

  defp configured_path_available?(config, repo_root) do
    case config[:path] || config["path"] do
      nil ->
        false

      path when is_binary(path) ->
        File.exists?(Path.expand(path, repo_root))

      paths when is_list(paths) ->
        Enum.any?(paths, &File.exists?(Path.expand(&1, repo_root)))

      _other ->
        false
    end
  end

  defp configured?(config, source),
    do: not is_nil(config[source] || config[Atom.to_string(source)])

  defp dep_tuple(app, config, :path, repo_root) do
    path = config[:path] || config["path"]

    path =
      if is_list(path), do: Enum.find(path, &File.exists?(Path.expand(&1, repo_root))), else: path

    {app, path: path}
  end

  defp dep_tuple(app, config, :github, _repo_root) do
    github = Map.new(config[:github] || config["github"] || %{})
    repo = github[:repo] || github["repo"]

    opts =
      github
      |> Enum.flat_map(fn
        {key, value} when key in [:branch, "branch", :ref, "ref", :tag, "tag"] ->
          [{normalize_option_key(key), value}]

        _other ->
          []
      end)

    {app, Keyword.merge([github: repo], opts)}
  end

  defp dep_tuple(app, config, :hex, _repo_root) do
    requirement = config[:hex] || config["hex"]
    {app, requirement}
  end

  defp normalize_source!(source) when source in @source_keys, do: source
  defp normalize_source!(source) when is_binary(source), do: String.to_existing_atom(source)

  defp normalize_option_key(key) when is_atom(key), do: key
  defp normalize_option_key(key) when is_binary(key), do: String.to_existing_atom(key)

  defp publish_mode? do
    System.argv()
    |> Enum.join(" ")
    |> String.contains?("hex.")
  end
end
