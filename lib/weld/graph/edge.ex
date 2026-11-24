defmodule Weld.Graph.Edge do
  @moduledoc """
  Classified internal dependency edge between two workspace projects.
  """

  @enforce_keys [:from, :to, :app, :kind, :opts]
  defstruct @enforce_keys ++ [requirement: nil]

  @type kind :: :runtime | :compile | :test | :docs | :tooling | :dev_only

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          app: atom(),
          requirement: String.t() | nil,
          kind: kind(),
          opts: keyword()
        }
end
