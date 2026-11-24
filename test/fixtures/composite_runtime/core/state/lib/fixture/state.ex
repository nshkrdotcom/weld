defmodule Fixture.State do
  def ready? do
    Process.whereis(Fixture.State.Agent) != nil
  end
end
