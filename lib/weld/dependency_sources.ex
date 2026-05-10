defmodule Weld.DependencySources do
  @moduledoc """
  Verifies repo-local dependency source bootstrap helpers and manifests.
  """

  @template_path Path.expand("../../priv/templates/dependency_sources.exs", __DIR__)
  @external_resource @template_path
  @canonical_helper File.read!(@template_path)

  @source_keys [:path, :github, :hex]

  @type violation :: %{
          code: atom(),
          message: String.t(),
          path: String.t() | nil,
          dependency: atom() | nil
        }

  @spec canonical_helper() :: String.t()
  def canonical_helper, do: @canonical_helper

  def verify(repo_root, opts \\ []) do
    report = report(repo_root, opts)

    if report.violations == [] do
      {:ok, report}
    else
      {:error, report}
    end
  end

  def report(repo_root, opts \\ []) do
    repo_root = Path.expand(repo_root)
    helper_path = Path.join(repo_root, "build_support/dependency_sources.exs")
    config_path = Path.join(repo_root, "build_support/dependency_sources.config.exs")

    {helper_status, helper_violations} = verify_helper(helper_path)
    {config_status, deps, config_violations} = verify_config(config_path)

    publish_violations =
      if Keyword.get(opts, :publish?, false), do: publish_violations(deps), else: []

    violations =
      Enum.uniq_by(
        helper_violations ++ config_violations ++ publish_violations,
        &{&1.code, &1.path, &1.dependency}
      )

    %{
      ok: violations == [],
      repo_root: repo_root,
      helper: %{path: helper_path, status: helper_status},
      config: %{path: config_path, status: config_status},
      deps: deps,
      publish: %{
        status: if(publish_violations == [], do: :ok, else: :blocked),
        checked?: Keyword.get(opts, :publish?, false)
      },
      violations: violations
    }
  end

  @spec load_deps(Path.t()) :: {:ok, %{optional(atom()) => map()}} | {:error, [violation()]}
  def load_deps(repo_root) do
    config_path = Path.join(Path.expand(repo_root), "build_support/dependency_sources.config.exs")
    {_status, deps, violations} = verify_config(config_path)

    if violations == [] do
      {:ok, deps}
    else
      {:error, violations}
    end
  end

  defp verify_helper(path) do
    cond do
      not File.regular?(path) ->
        {:missing,
         [violation(:helper_missing, "missing canonical dependency source helper", path)]}

      File.read!(path) != @canonical_helper ->
        {:drifted,
         [violation(:helper_drift, "dependency source helper differs from Weld template", path)]}

      true ->
        {:ok, []}
    end
  end

  defp verify_config(path) do
    case File.regular?(path) do
      true ->
        verify_existing_config(path)

      false ->
        {:missing, %{}, [violation(:config_missing, "missing dependency source config", path)]}
    end
  end

  defp verify_existing_config(path) do
    with {:ok, raw} <- eval_config(path),
         {:ok, deps, violations} <- normalize_deps(raw, path) do
      status = if violations == [], do: :ok, else: :invalid
      {status, deps, violations}
    else
      {:error, violation} -> {:invalid, %{}, [violation]}
    end
  end

  defp eval_config(path) do
    {raw, _binding} = Code.eval_file(path)
    {:ok, raw}
  rescue
    error ->
      {:error, violation(:config_eval_failed, Exception.message(error), path)}
  end

  defp normalize_deps(raw, path) when is_map(raw) or is_list(raw) do
    deps = raw[:deps] || raw["deps"] || raw

    case is_map(deps) or is_list(deps) do
      true ->
        normalize_dep_entries(deps, path)

      false ->
        {:error,
         violation(:deps_manifest_invalid, "dependency config must contain a deps map", path)}
    end
  end

  defp normalize_deps(_raw, path) do
    {:error, violation(:deps_manifest_invalid, "dependency config must evaluate to a map", path)}
  end

  defp normalize_dep_entries(deps, path) do
    {normalized, violations} =
      deps
      |> Map.new()
      |> Enum.reduce({%{}, []}, &normalize_dep_entry(&1, &2, path))

    {:ok, normalized, violations}
  end

  defp normalize_dep_entry({app, config}, {deps_acc, violations_acc}, path) do
    app = normalize_app(app)

    case normalize_dep(app, config, path) do
      {:ok, dep, violations} -> {Map.put(deps_acc, app, dep), violations_acc ++ violations}
      {:error, violation} -> {deps_acc, violations_acc ++ [violation]}
    end
  end

  defp normalize_dep(app, config, path) when is_map(config) or is_list(config) do
    config = Map.new(config)

    default_order =
      normalize_order(config[:default_order] || config["default_order"] || [:path, :github, :hex])

    publish_order = normalize_order(config[:publish_order] || config["publish_order"] || [:hex])

    dep = %{
      app: app,
      path: normalize_paths(config[:path] || config["path"]),
      github: normalize_github(config[:github] || config["github"]),
      hex: config[:hex] || config["hex"],
      default_order: default_order,
      publish_order: publish_order
    }

    violations =
      []
      |> add_order_violations(app, path, dep, default_order)
      |> add_order_violations(app, path, dep, publish_order)

    {:ok, Map.put(dep, :sources, configured_sources(dep)), violations}
  end

  defp normalize_dep(app, _config, path) do
    {:error, violation(:dep_config_invalid, "dependency #{app} config must be a map", path, app)}
  end

  defp normalize_app(app) when is_atom(app), do: app
  defp normalize_app(app) when is_binary(app), do: String.to_atom(app)

  defp normalize_order(order) when is_list(order), do: Enum.map(order, &normalize_source/1)
  defp normalize_order(_order), do: []

  defp normalize_source(source) when source in @source_keys, do: source
  defp normalize_source(source) when is_binary(source), do: String.to_atom(source)
  defp normalize_source(source), do: source

  defp normalize_paths(nil), do: nil
  defp normalize_paths(path) when is_binary(path), do: [path]

  defp normalize_paths(paths) when is_list(paths) do
    if Enum.all?(paths, &is_binary/1), do: paths, else: nil
  end

  defp normalize_paths(_paths), do: nil

  defp normalize_github(nil), do: nil
  defp normalize_github(github) when is_map(github) or is_list(github), do: Map.new(github)
  defp normalize_github(_github), do: nil

  defp add_order_violations(violations, app, path, dep, order) do
    Enum.reduce(order, violations, fn source, acc ->
      cond do
        source not in @source_keys ->
          [
            violation(:unknown_source, "unknown dependency source #{inspect(source)}", path, app)
            | acc
          ]

        not source_configured?(dep, source) ->
          [
            violation(
              missing_source_code(source),
              "missing #{source} source for #{app}",
              path,
              app
            )
            | acc
          ]

        source == :github and not valid_github?(dep.github) ->
          [
            violation(
              :github_source_invalid,
              "github source for #{app} must include repo owner/name",
              path,
              app
            )
            | acc
          ]

        source == :hex and not is_binary(dep.hex) ->
          [
            violation(
              :hex_source_invalid,
              "hex source for #{app} must be a requirement string",
              path,
              app
            )
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp source_configured?(dep, :path), do: is_list(dep.path) and dep.path != []
  defp source_configured?(dep, :github), do: is_map(dep.github)
  defp source_configured?(dep, :hex), do: not is_nil(dep.hex)

  defp missing_source_code(:path), do: :path_source_missing
  defp missing_source_code(:github), do: :github_source_missing
  defp missing_source_code(:hex), do: :hex_source_missing

  defp valid_github?(github) when is_map(github) do
    repo = github[:repo] || github["repo"]
    is_binary(repo) and String.match?(repo, ~r/^[^\/\s]+\/[^\/\s]+$/)
  end

  defp valid_github?(_github), do: false

  defp configured_sources(dep) do
    Enum.filter(@source_keys, &source_configured?(dep, &1))
  end

  defp publish_violations(deps) do
    Enum.flat_map(deps, fn {app, dep} ->
      if dep.publish_order == [:hex] and source_configured?(dep, :hex) do
        []
      else
        [
          violation(
            :publish_requires_hex_source,
            "publish mode for #{app} must use a configured Hex source only",
            nil,
            app
          )
        ]
      end
    end)
  end

  defp violation(code, message, path, dependency \\ nil) do
    %{code: code, message: message, path: path, dependency: dependency}
  end
end
