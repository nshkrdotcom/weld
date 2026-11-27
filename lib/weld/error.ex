defmodule Weld.Error do
  defexception [:message, :code, :phase, :diagnostics, details: %{}]
end
