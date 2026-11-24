defmodule Weld.Graph.View do
  @moduledoc """
  Edge-kind filters for graph traversal and task planning.
  """

  alias Weld.Graph.Edge

  @type t :: :all | :runtime | :compile | :docs | :test | :package | :smoke

  @spec allowed?(Edge.kind(), t()) :: boolean()
  def allowed?(kind, :all), do: kind in [:runtime, :compile, :test, :docs, :tooling, :dev_only]
  def allowed?(kind, :runtime), do: kind == :runtime
  def allowed?(kind, :compile), do: kind in [:runtime, :compile]
  def allowed?(kind, :docs), do: kind in [:runtime, :compile, :docs]
  def allowed?(kind, :test), do: kind in [:runtime, :compile, :test, :dev_only]
  def allowed?(kind, :package), do: kind in [:runtime, :compile]
  def allowed?(kind, :smoke), do: kind in [:runtime, :compile]
end
