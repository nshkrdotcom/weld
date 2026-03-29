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
    :application,
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

  @type application_config :: %{
          extra_applications: [atom()],
          included_applications: [atom()],
          registered: [atom()],
          mod: nil | {module(), term()}
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
          application: application_config(),
          elixirc_paths: [String.t()],
          erlc_paths: [String.t()],
          copy_dirs: [String.t()],
          classification: classification(),
          publication_role: publication_role()
        }
end
