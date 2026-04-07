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
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            mode: :package_projection | :monolith,
            monolith_opts: keyword(),
            roots: [String.t()],
            include: [String.t()],
            optional_features: [String.t()],
            package: Weld.Manifest.Package.t(),
            output: Weld.Manifest.Output.t(),
            verify: Weld.Manifest.Verify.t()
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
      :docs_main
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
            docs_main: String.t()
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

    @enforce_keys [:artifact_tests, :smoke]
    defstruct @enforce_keys

    @type smoke_config :: %{
            enabled: boolean(),
            entry_file: String.t() | nil
          }

    @type t :: %__MODULE__{
            artifact_tests: [String.t()],
            smoke: smoke_config()
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
  defstruct @enforce_keys

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

  @root_schema [
    workspace: [type: :keyword_list, required: true],
    classify: [type: :keyword_list, default: []],
    publication: [type: :keyword_list, default: []],
    dependencies: [type: :keyword_list, default: []],
    artifacts: [type: :keyword_list, required: true]
  ]

  @workspace_schema [
    root: [type: :string, required: true],
    project_globs: [type: {:list, :string}, default: []]
  ]

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
    requirement: [type: :string],
    opts: [type: :keyword_list, default: []]
  ]

  @artifact_schema [
    mode: [type: {:in, [:package_projection, :components, :monolith]}, default: :package_projection],
    monolith_opts: [type: :keyword_list, default: []],
    roots: [type: {:list, :string}, required: true],
    include: [type: {:list, :string}, default: []],
    optional_features: [type: {:list, :string}, default: []],
    package: [type: :keyword_list, required: true],
    output: [type: :keyword_list, required: true],
    verify: [type: :keyword_list, default: []]
  ]

  @package_schema [
    name: [type: :string, required: true],
    otp_app: [type: :atom, required: true],
    version: [type: :string, required: true],
    elixir: [type: :string, default: "~> 1.18"],
    description: [type: :string, default: "Generated by weld"],
    licenses: [type: {:list, :string}, default: ["MIT"]],
    maintainers: [type: {:list, :string}, default: []],
    links: [type: :any, default: %{}],
    docs_main: [type: :string, default: "readme"]
  ]

  @output_schema [
    dist_root: [type: :string, default: "dist"],
    layout: [type: {:in, [:components]}, default: :components],
    docs: [type: {:list, :string}, default: []],
    assets: [type: {:list, :string}, default: []]
  ]

  @verify_schema [
    artifact_tests: [type: {:list, :string}, default: []],
    smoke: [type: :keyword_list, default: []]
  ]

  @smoke_schema [
    enabled: [type: :boolean, default: false],
    entry_file: [type: :string]
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

    config = NimbleOptions.validate!(raw, @root_schema)
    manifest_dir = Path.dirname(manifest_path)
    workspace = normalize_workspace(config[:workspace], manifest_dir)

    %__MODULE__{
      manifest_path: manifest_path,
      repo_root: Path.expand(workspace.root, manifest_dir),
      workspace: workspace,
      classify: normalize_classify(config[:classify]),
      publication: normalize_publication(config[:publication]),
      dependencies: normalize_dependencies(config[:dependencies]),
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
    workspace = NimbleOptions.validate!(workspace, @workspace_schema)

    %{
      root: Path.expand(workspace[:root], manifest_dir),
      project_globs: Enum.sort(workspace[:project_globs])
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
      normalized = NimbleOptions.validate!(config, @artifact_schema)
      artifact_id = normalize_key(artifact_name)

      artifact =
        %Artifact{
          id: artifact_id,
          mode: normalize_mode(normalized[:mode]),
          monolith_opts: normalized[:monolith_opts],
          roots: Enum.sort(normalized[:roots]),
          include: Enum.sort(normalized[:include]),
          optional_features: Enum.sort(normalized[:optional_features]),
          package: normalize_package(normalized[:package]),
          output: normalize_output(normalized[:output]),
          verify: normalize_verify(normalized[:verify])
        }

      {artifact_id, artifact}
    end)
    |> Map.new()
  end

  defp normalize_package(package) do
    package = NimbleOptions.validate!(package, @package_schema)

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
      maintainers: package[:maintainers],
      links: links,
      docs_main: package[:docs_main]
    }
  end

  defp normalize_output(output) do
    output = NimbleOptions.validate!(output, @output_schema)

    %Output{
      dist_root: output[:dist_root],
      layout: output[:layout],
      docs: Enum.sort(output[:docs]),
      assets: Enum.sort(output[:assets])
    }
  end

  defp normalize_verify(verify) do
    verify = NimbleOptions.validate!(verify, @verify_schema)
    smoke = NimbleOptions.validate!(verify[:smoke], @smoke_schema)

    %Verify{
      artifact_tests: Enum.sort(verify[:artifact_tests]),
      smoke: %{
        enabled: smoke[:enabled],
        entry_file: smoke[:entry_file]
      }
    }
  end

  defp normalize_mode(:components), do: :package_projection
  defp normalize_mode(mode), do: mode

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
end
