defmodule FixtureState.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_state,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Fixture.State.Application, []}
    ]
  end
end
