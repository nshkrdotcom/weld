defmodule WeldFixture.Runtime do
  @moduledoc false

  alias WeldFixture.Contracts

  def hello do
    Jason.encode!(%{contract: Contracts.contract_name()})
  end
end
