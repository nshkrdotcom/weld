defmodule Fixture.Runtime do
  def ready? do
    Fixture.State.ready?()
  end
end
