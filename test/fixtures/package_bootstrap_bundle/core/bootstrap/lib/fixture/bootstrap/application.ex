defmodule Fixture.Bootstrap.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :configured = Application.fetch_env!(:fixture_bootstrap, :required_value)

    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
