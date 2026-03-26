defmodule WeldFixture.Runtime do
  @moduledoc false

  alias WeldFixture.Contracts

  def run do
    {:ok, Contracts.contract_name()}
  end
end
