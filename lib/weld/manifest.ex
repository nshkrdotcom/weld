defmodule Weld.Manifest do
  @moduledoc """
  Loads and normalizes a projection manifest from `packaging/hex_projections`.
  """

  @enforce_keys [
    :manifest_path,
    :repo_root,
    :package_name,
    :otp_app,
    :version,
    :mode,
    :source_projects,
    :public_entry_modules,
    :description,
    :licenses,
    :maintainers,
    :links,
    :copy,
    :docs
  ]
  defstruct @enforce_keys

  @type copy_config :: %{
          docs: [String.t()],
          assets: [String.t()],
          priv: :auto | [String.t()]
        }

  @type docs_config :: %{
          main: String.t()
        }

  @type t :: %__MODULE__{
          manifest_path: Path.t(),
          repo_root: Path.t(),
          package_name: String.t(),
          otp_app: atom(),
          version: String.t(),
          mode: :library_bundle | :strict_library_bundle | :runtime_bundle,
          source_projects: [String.t()],
          public_entry_modules: [module()],
          description: String.t(),
          licenses: [String.t()],
          maintainers: [String.t()],
          links: %{optional(String.t()) => String.t()},
          copy: copy_config(),
          docs: docs_config()
        }

  @allowed_modes [:library_bundle, :strict_library_bundle, :runtime_bundle]

  @spec load!(Path.t()) :: t()
  def load!(manifest_path) do
    manifest_path = Path.expand(manifest_path)

    unless File.regular?(manifest_path) do
      raise Weld.Error, "manifest not found: #{manifest_path}"
    end

    {raw, _binding} = Code.eval_file(manifest_path)

    unless is_map(raw) do
      raise Weld.Error, "manifest must evaluate to a map: #{manifest_path}"
    end

    repo_root =
      manifest_path
      |> Path.dirname()
      |> Path.join("../..")
      |> Path.expand()

    copy = normalize_copy(Map.get(raw, :copy, %{}))
    docs = normalize_docs(Map.get(raw, :docs, %{}))

    manifest = %__MODULE__{
      manifest_path: manifest_path,
      repo_root: repo_root,
      package_name: fetch_string!(raw, :package_name),
      otp_app: fetch_atom!(raw, :otp_app),
      version: fetch_string!(raw, :version),
      mode: fetch_mode!(raw),
      source_projects: fetch_paths!(raw, :source_projects),
      public_entry_modules: Map.get(raw, :public_entry_modules, []),
      description: Map.get(raw, :description, "Generated package projection assembled by Weld"),
      licenses: normalize_string_list(Map.get(raw, :licenses, ["MIT"])),
      maintainers: normalize_string_list(Map.get(raw, :maintainers, [])),
      links: normalize_links(Map.get(raw, :links, %{})),
      copy: copy,
      docs: docs
    }

    validate!(manifest)
  end

  defp validate!(manifest) do
    if manifest.source_projects == [] do
      raise Weld.Error, "manifest must include at least one source project"
    end

    manifest
  end

  defp normalize_copy(copy) when is_map(copy) do
    %{
      docs: normalize_string_list(Map.get(copy, :docs, [])),
      assets: normalize_string_list(Map.get(copy, :assets, [])),
      priv: Map.get(copy, :priv, :auto)
    }
  end

  defp normalize_copy(_copy) do
    raise Weld.Error, "manifest copy config must be a map"
  end

  defp normalize_docs(docs) when is_map(docs) do
    %{
      main: Map.get(docs, :main, "readme")
    }
  end

  defp normalize_docs(_docs) do
    raise Weld.Error, "manifest docs config must be a map"
  end

  defp fetch_mode!(raw) do
    mode = Map.get(raw, :mode, :library_bundle)

    if mode in @allowed_modes do
      mode
    else
      raise Weld.Error, "unsupported bundle mode: #{inspect(mode)}"
    end
  end

  defp fetch_string!(raw, key) do
    value = Map.fetch!(raw, key)

    if is_binary(value) and value != "" do
      value
    else
      raise Weld.Error, "manifest #{key} must be a non-empty string"
    end
  end

  defp fetch_atom!(raw, key) do
    value = Map.fetch!(raw, key)

    if is_atom(value) do
      value
    else
      raise Weld.Error, "manifest #{key} must be an atom"
    end
  end

  defp fetch_paths!(raw, key) do
    raw
    |> Map.fetch!(key)
    |> normalize_string_list()
  end

  defp normalize_string_list(list) when is_list(list) do
    Enum.map(list, fn item ->
      if is_binary(item) and item != "" do
        item
      else
        raise Weld.Error, "expected a non-empty string list entry, got: #{inspect(item)}"
      end
    end)
  end

  defp normalize_string_list(_value) do
    raise Weld.Error, "expected a list of strings"
  end

  defp normalize_links(links) when is_map(links) do
    Map.new(links, fn {key, value} ->
      unless is_binary(key) and key != "" and is_binary(value) and value != "" do
        raise Weld.Error, "manifest links must contain non-empty string keys and values"
      end

      {key, value}
    end)
  end

  defp normalize_links(_value) do
    raise Weld.Error, "manifest links must be a map"
  end
end
