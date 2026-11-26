defmodule Weld.Manifest do
  @moduledoc """
  Loads and validates a repo-local weld manifest.
  """

  alias Weld.Error

  defmodule Artifact do
    @moduledoc """
    Normalized artifact configuration.
    """

    @enforce_keys [
      :id,
      :mode,
      :monolith_opts,
      :roots,
      :include,
      :optional_features,
      :package,
      :output,
      :verify
    ]
    defstruct @enforce_keys ++
                [source_project: [], external_projects: [], structural_inputs: [], inputs: []]

    @type t :: %__MODULE__{
            id: String.t(),
            mode: :package_projection | :monolith | :source_project,
            source_project: keyword(),
            monolith_opts: keyword(),
            roots: [String.t()],
            include: [String.t()],
            optional_features: [String.t()],
            external_projects: [String.t()],
            structural_inputs: [String.t()],
            package: Weld.Manifest.Package.t() | nil,
            output: Weld.Manifest.Output.t(),
            verify: Weld.Manifest.Verify.t()
          }
  end

  defmodule Docs do
    @moduledoc """
    HexDocs metadata for a generated artifact.
    """

    @enforce_keys [
      :main,
      :logo,
      :homepage_url,
      :source_url,
      :source_ref,
      :assets,
      :extra_titles,
      :groups_for_extras,
      :mermaid,
      :hook_file
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            main: String.t(),
            logo: String.t() | nil,
            homepage_url: String.t() | nil,
            source_url: String.t() | nil,
            source_ref: String.t() | nil,
            assets: %{optional(String.t()) => String.t()},
            extra_titles: %{optional(String.t()) => String.t()},
            groups_for_extras: [{String.t(), [String.t()]}],
            mermaid: boolean(),
            hook_file: String.t() | nil
          }
  end

  defmodule Package do
    @moduledoc """
    Package metadata for a generated artifact.
    """

    @enforce_keys [
      :name,
      :otp_app,
      :version,
      :elixir,
      :description,
      :licenses,
      :maintainers,
      :links,
      :docs_main,
      :docs,
      :development_dependencies
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            otp_app: atom(),
            version: String.t(),
            elixir: String.t(),
            description: String.t(),
            licenses: [String.t()],
            maintainers: [String.t()],
            links: %{optional(String.t()) => String.t()},
            docs_main: String.t(),
            docs: Weld.Manifest.Docs.t(),
            development_dependencies: [tuple()]
          }
  end

  defmodule Output do
    @moduledoc """
    Projection output configuration.
    """

    @enforce_keys [:dist_root, :layout, :docs, :assets]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            dist_root: String.t(),
            layout: :components,
            docs: [String.t()],
            assets: [String.t()]
          }
  end

  defmodule Verify do
    @moduledoc """
    Verification configuration for a generated artifact.
    """

    @enforce_keys [:artifact_tests, :smoke, :hex_build, :hex_publish]
    defstruct @enforce_keys ++ [component_tests: false, context: []]

    @type smoke_config :: %{
            enabled: boolean(),
            entry_file: String.t() | nil
          }

    @type t :: %__MODULE__{
            artifact_tests: [String.t()],
            component_tests: boolean(),
            smoke: smoke_config(),
            hex_build: boolean(),
            hex_publish: boolean()
          }
  end

  @enforce_keys [
    :manifest_path,
    :repo_root,
    :workspace,
    :classify,
    :publication,
    :dependencies,
    :artifacts
  ]
  defstruct @enforce_keys ++ [project_inputs: %{}]

  @type workspace_config :: %{
          root: String.t(),
          project_globs: [String.t()]
        }

  @type classify_config :: %{
          tooling: MapSet.t(String.t()),
          proofs: MapSet.t(String.t()),
          ignored: MapSet.t(String.t())
        }

  @type publication_config :: %{
          internal_only: MapSet.t(String.t()),
          separate: MapSet.t(String.t()),
          optional: %{optional(String.t()) => MapSet.t(String.t())}
        }

  @type dependency_config :: %{
          optional(atom()) => %{
            requirement: String.t() | nil,
            opts: keyword()
          }
        }

  @type t :: %__MODULE__{
          manifest_path: Path.t(),
          repo_root: Path.t(),
          workspace: workspace_config(),
          classify: classify_config(),
          publication: publication_config(),
          dependencies: dependency_config(),
          artifacts: %{optional(String.t()) => Artifact.t()}
        }

  @classify_schema [
    tooling: [type: {:list, :string}, default: []],
    proofs: [type: {:list, :string}, default: []],
    ignored: [type: {:list, :string}, default: []]
  ]

  @publication_schema [
    internal_only: [type: {:list, :string}, default: []],
    separate: [type: {:list, :string}, default: []],
    optional: [type: :keyword_list, default: []]
  ]

  @dependency_schema [
    requirement: [type: :any, default: nil],
    opts: [type: :keyword_list, default: []]
  ]

  @docs_schema [
    main: [type: :string],
    logo: [type: :string],
    homepage_url: [type: :string],
    source_url: [type: :string],
    source_ref: [type: :string],
    assets: [type: :any, default: %{}],
    extra_titles: [type: :any, default: %{}],
    groups_for_extras: [type: :any, default: []],
    mermaid: [type: :boolean, default: false],
    hook_file: [type: :string]
  ]

  @spec load!(Path.t()) :: t()
  def load!(manifest_path) do
    manifest_path = Path.expand(manifest_path)

    unless File.regular?(manifest_path) do
      raise Error, "manifest not found: #{manifest_path}"
    end

    {raw, _binding} = Code.eval_file(manifest_path)

    unless Keyword.keyword?(raw) do
      raise Error, "manifest must evaluate to a keyword list: #{manifest_path}"
    end

    config = Weld.Core.Manifest.normalize!(raw)
    manifest_dir = Path.dirname(manifest_path)
    workspace = normalize_workspace(config[:workspace], manifest_dir)

    %__MODULE__{
      manifest_path: manifest_path,
      repo_root: Path.expand(workspace.root, manifest_dir),
      workspace: workspace,
      classify: normalize_classify(config[:classify]),
      publication: normalize_publication(config[:publication]),
      dependencies: normalize_dependencies(config[:dependencies]),
      project_inputs: config[:project_inputs],
      artifacts: normalize_artifacts(config[:artifacts])
    }
    |> validate!()
  end

  @spec artifact!(t(), nil | String.t() | atom()) :: Artifact.t()
  def artifact!(%__MODULE__{artifacts: artifacts}, nil) do
    case Map.values(artifacts) do
      [artifact] -> artifact
      _many -> raise Error, "manifest defines multiple artifacts; pass --artifact"
    end
  end

  def artifact!(%__MODULE__{artifacts: artifacts}, artifact_name) do
    key = normalize_key(artifact_name)

    case Map.fetch(artifacts, key) do
      {:ok, artifact} -> artifact
      :error -> raise Error, "unknown artifact #{key}"
    end
  end

  defp validate!(%__MODULE__{} = manifest) do
    if map_size(manifest.artifacts) == 0 do
      raise Error, "manifest must define at least one artifact"
    end

    manifest
  end

  defp normalize_workspace(workspace, manifest_dir) do
    %{
      root: Path.expand(workspace[:root], manifest_dir),
      project_globs: Enum.sort(workspace[:projects])
    }
  end

  defp normalize_classify(classify) do
    classify = NimbleOptions.validate!(classify, @classify_schema)

    %{
      tooling: classify[:tooling] |> MapSet.new(),
      proofs: classify[:proofs] |> MapSet.new(),
      ignored: classify[:ignored] |> MapSet.new()
    }
  end

  defp normalize_publication(publication) do
    publication = NimbleOptions.validate!(publication, @publication_schema)

    %{
      internal_only: publication[:internal_only] |> MapSet.new(),
      separate: publication[:separate] |> MapSet.new(),
      optional: normalize_optional_features(publication[:optional])
    }
  end

  defp normalize_dependencies(dependencies) do
    dependencies
    |> Enum.map(fn {app, config} ->
      unless is_atom(app) do
        raise Error, "manifest dependency keys must be atoms"
      end

      normalized = NimbleOptions.validate!(config, @dependency_schema)
      opts = normalized[:opts]

      if Keyword.has_key?(opts, :path) do
        raise Error, "manifest dependency opts must not contain :path"
      end

      requirement = normalized[:requirement]

      unless is_nil(requirement) or is_binary(requirement) do
        raise Error,
              "manifest dependency #{inspect(app)} requirement must be a string when present"
      end

      if is_nil(requirement) and is_nil(opts[:git]) and is_nil(opts[:github]) do
        raise Error,
              "manifest dependency #{inspect(app)} must declare a requirement unless opts include :git or :github"
      end

      {app, %{requirement: requirement, opts: opts}}
    end)
    |> Map.new()
  end

  defp normalize_optional_features(optional_features) do
    optional_features
    |> Enum.map(fn {feature, projects} ->
      unless is_list(projects) and Enum.all?(projects, &is_binary/1) do
        raise Error, "publication.optional entries must be lists of project ids"
      end

      {normalize_key(feature), MapSet.new(projects)}
    end)
    |> Map.new()
  end

  defp normalize_artifacts(artifacts) do
    artifacts
    |> Enum.map(fn {artifact_name, config} ->
      artifact_id = normalize_key(artifact_name)
      layout = config[:layout]

      mode =
        %{components: :package_projection, flat: :monolith, preserve: :source_project}[layout]

      preserve = config[:preserve] || []
      flat = config[:flat] || []
      package = if config[:package], do: normalize_package(config[:package], config[:docs] || [])
      output = config[:files] || []
      verify = config[:verify]

      artifact = %Artifact{
        id: artifact_id,
        mode: mode,
        source_project:
          if(layout == :preserve,
            do: [
              files: preserve[:files],
              inputs: preserve[:inputs],
              structural_inputs: Enum.map(preserve[:inputs], & &1[:path])
            ],
            else: []
          ),
        monolith_opts: normalize_monolith_opts(flat),
        roots: Enum.sort(config[:roots]),
        include: Enum.sort(config[:include]),
        optional_features: Enum.sort(config[:features]),
        external_projects: normalize_external_projects!(config[:external]),
        structural_inputs: Enum.map(config[:inputs], & &1[:path]),
        inputs: config[:inputs],
        package: package,
        output: %Output{
          dist_root: ".weld",
          layout: :components,
          docs: Enum.sort(output[:docs] || []),
          assets: Enum.sort(output[:assets] || [])
        },
        verify: %Verify{
          artifact_tests: Enum.sort(verify[:artifact_tests]),
          component_tests: verify[:component_tests],
          hex_build: verify[:hex_build],
          hex_publish: verify[:hex_publish_check],
          context: verify[:context],
          smoke: %{
            enabled: not is_nil(verify[:smoke]),
            entry_file: if(verify[:smoke], do: verify[:smoke][:entry_file])
          }
        }
      }

      artifact = if package, do: validate_docs_output!(artifact), else: artifact

      {artifact_id, artifact}
    end)
    |> Map.new()
  end

  defp normalize_external_projects!(ids) do
    if Enum.uniq(ids) != ids, do: raise(Error, "duplicate external_projects project id")

    for id <- ids, id != "." do
      if Path.type(id) != :relative or String.contains?(id, ["\\", <<0>>]) or
           Enum.any?(String.split(id, "/"), &(&1 in ["", ".", "..", ".git", ".weld"])) do
        raise Error, "invalid external_projects project id: #{inspect(id)}"
      end
    end

    Enum.sort(ids)
  end

  @doc false
  def bind_native(%Artifact{mode: :source_project, roots: [id]} = artifact, projects) do
    project = Map.get(projects, id) || raise(Error, "preserve root was not discovered: #{id}")

    package =
      normalize_package(
        [
          name: project.package_name,
          otp_app: project.app,
          version: project.version,
          elixir: project.elixir,
          description: project.description,
          licenses: [],
          links: %{},
          dev_deps: []
        ],
        []
      )

    %{
      artifact
      | package: %{package | docs: %{package.docs | source_ref: project.docs_source_ref}}
    }
  end

  def bind_native(artifact, _projects), do: artifact

  defp normalize_package(package, doc_options) do
    for name <- [package[:name], Atom.to_string(package[:otp_app])] do
      unless Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name),
        do: raise(Error, "invalid package name: #{name}")
    end

    unless match?({:ok, _}, Version.parse(package[:version])),
      do: raise(Error, "invalid package version")

    docs = normalize_docs(doc_options, "readme")

    links =
      Map.new(package[:links], fn {label, url} ->
        unless is_binary(label) and label != "" and is_binary(url) and url != "" do
          raise Error, "package links must contain non-empty string keys and values"
        end

        {label, url}
      end)

    %Package{
      name: package[:name],
      otp_app: package[:otp_app],
      version: package[:version],
      elixir: package[:elixir],
      description: package[:description],
      licenses: package[:licenses],
      maintainers: [],
      links: links,
      docs_main: docs.main,
      docs: docs,
      development_dependencies: normalize_development_dependencies(package[:dev_deps])
    }
  end

  defp normalize_development_dependencies(dependencies) do
    Enum.map(dependencies, fn
      {app, requirement, opts}
      when is_atom(app) and is_binary(requirement) and is_list(opts) ->
        validate_development_dependency!(app, opts)
        {app, requirement, opts}

      dependency ->
        raise Error,
              "package development_dependencies must use " <>
                "{:app, \"requirement\", only: ..., runtime: false}; got #{inspect(dependency)}"
    end)
  end

  defp validate_development_dependency!(app, opts) do
    only = opts |> Keyword.get(:only) |> List.wrap()
    source_keys = Keyword.keys(opts) -- [:only, :runtime, :optional, :override]

    if only == [] or Enum.any?(only, &(&1 not in [:dev, :test])) or opts[:runtime] != false or
         source_keys != [] do
      raise Error,
            "package development dependency #{inspect(app)} must be Hex-only, scoped to " <>
              ":dev/:test, and runtime: false"
    end
  end

  defp normalize_docs(docs, legacy_main) do
    docs = NimbleOptions.validate!(docs, @docs_schema)

    %Docs{
      main: docs[:main] || legacy_main,
      logo: docs[:logo],
      homepage_url: docs[:homepage_url],
      source_url: docs[:source_url],
      source_ref: docs[:source_ref],
      assets: normalize_string_map!(docs[:assets], "package.docs.assets"),
      extra_titles: normalize_string_map!(docs[:extra_titles], "package.docs.extra_titles"),
      groups_for_extras: normalize_extra_groups!(docs[:groups_for_extras]),
      mermaid: docs[:mermaid],
      hook_file: docs[:hook_file]
    }
  end

  defp normalize_string_map!(entries, label) when is_map(entries) or is_list(entries) do
    Map.new(entries, fn
      {key, value}
      when is_binary(key) and key != "" and is_binary(value) and value != "" ->
        {key, value}

      entry ->
        raise Error,
              "#{label} must contain non-empty string keys and values, got: #{inspect(entry)}"
    end)
  end

  defp normalize_string_map!(entries, label) do
    raise Error, "#{label} must be a map or keyword-style list, got: #{inspect(entries)}"
  end

  defp normalize_extra_groups!(groups) when is_list(groups) do
    Enum.map(groups, fn
      {label, paths} when (is_binary(label) or is_atom(label)) and is_list(paths) ->
        normalized_label = to_string(label)

        unless normalized_label != "" and paths != [] and
                 Enum.all?(paths, &(is_binary(&1) and &1 != "")) do
          raise Error,
                "package.docs.groups_for_extras entries require a non-empty label and non-empty path list"
        end

        {normalized_label, Enum.uniq(paths)}

      entry ->
        raise Error,
              "package.docs.groups_for_extras must contain {label, paths} entries, got: #{inspect(entry)}"
    end)
  end

  defp normalize_extra_groups!(groups) do
    raise Error,
          "package.docs.groups_for_extras must be a list, got: #{inspect(groups)}"
  end

  @doc false
  def docs_paths(%Artifact{mode: :monolith, monolith_opts: opts, output: output}) do
    if opts[:readme], do: ["README.md" | output.docs], else: output.docs
  end

  def docs_paths(%Artifact{output: output}), do: output.docs

  defp validate_docs_output!(%Artifact{} = artifact) do
    docs = artifact.package.docs
    output_docs = MapSet.new(docs_paths(artifact))

    referenced_docs =
      Map.keys(docs.extra_titles) ++
        Enum.flat_map(docs.groups_for_extras, fn {_label, paths} -> paths end)

    missing_docs = referenced_docs |> Enum.uniq() |> Enum.reject(&MapSet.member?(output_docs, &1))

    if missing_docs != [] do
      raise Error,
            "package.docs references paths not declared in output.docs: #{Enum.join(missing_docs, ", ")}"
    end

    if docs.logo && !output_path_covered?(docs.logo, artifact.output.assets) do
      raise Error,
            "package.docs.logo must be copied by output.assets: #{docs.logo}"
    end

    missing_asset_roots =
      docs.assets
      |> Map.keys()
      |> Enum.reject(&asset_root_covered?(&1, artifact.output.assets))

    if missing_asset_roots != [] do
      raise Error,
            "package.docs.assets roots must be copied by output.assets: #{Enum.join(missing_asset_roots, ", ")}"
    end

    artifact
  end

  defp output_path_covered?(path, output_paths) do
    Enum.any?(output_paths, fn output_path ->
      path == output_path or String.starts_with?(path, output_path <> "/")
    end)
  end

  defp asset_root_covered?(root, output_paths) do
    Enum.any?(output_paths, fn output_path ->
      output_path == root or String.starts_with?(output_path, root <> "/")
    end)
  end

  defp normalize_monolith_opts(monolith_opts) do
    opts = monolith_opts

    normalized = [
      shared_test_configs: normalize_project_refs(opts[:shared_test_configs] || []),
      extra_test_deps: Enum.uniq(opts[:extra_test_deps] || []) |> Enum.sort(),
      test_support_projects: normalize_project_refs(opts[:test_support] || [])
    ]

    if Enum.all?(normalized, fn {_key, value} -> value == [] end) do
      []
    else
      normalized
    end
    |> then(fn normalized ->
      case opts[:readme] do
        nil -> normalized
        path -> Keyword.put(normalized, :readme, path)
      end
    end)
  end

  defp normalize_project_refs(entries) do
    entries
    |> Enum.map(fn
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      other -> to_string(other)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
end
