defmodule Weld.Violation do
  @moduledoc """
  Structured machine-readable policy or graph violation.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :project, :dependency, details: %{}]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          project: String.t() | nil,
          dependency: atom() | nil,
          details: map()
        }

  @spec new(atom(), String.t(), keyword()) :: t()
  def new(code, message, opts \\ []) do
    %__MODULE__{
      code: code,
      message: message,
      project: Keyword.get(opts, :project),
      dependency: Keyword.get(opts, :dependency),
      details: Keyword.get(opts, :details, %{})
    }
  end
end
