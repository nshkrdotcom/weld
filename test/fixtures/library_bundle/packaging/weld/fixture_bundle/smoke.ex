defmodule WeldSmoke do
  @moduledoc false

  def ready? do
    String.contains?(WeldFixture.Runtime.hello(), "fixture_contracts")
  end
end
