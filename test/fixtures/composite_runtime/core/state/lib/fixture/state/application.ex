defmodule Fixture.State.Application do
  use Application

  @impl Application
  def start(_type, _args) do
    Agent.start_link(fn -> :ready end, name: Fixture.State.Agent)
  end
end
