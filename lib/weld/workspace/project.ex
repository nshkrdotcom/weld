defmodule Weld.Workspace.Project do
  @moduledoc """
  Loaded Mix project metadata for one workspace member.
  """

  @enforce_keys [
    :id,
    :abs_path,
    :app,
    :version,
    :elixir,
    :deps,
    :elixirc_paths,
    :erlc_paths,
    :copy_dirs,
    :classification,
    :publication_role
  ]
  defstruct @enforce_keys

  @type dep :: %{
          app: atom(),
          requirement: String.t() | nil,
          opts: keyword(),
          original: tuple()
        }

  @type classification :: :runtime | :tooling | :proof | :ignored
  @type publication_role :: :default | :internal_only | :separate | {:optional, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          abs_path: Path.t(),
          app: atom(),
          version: String.t(),
          elixir: String.t(),
          deps: [dep()],
          elixirc_paths: [String.t()],
          erlc_paths: [String.t()],
          copy_dirs: [String.t()],
          classification: classification(),
          publication_role: publication_role()
        }
end
