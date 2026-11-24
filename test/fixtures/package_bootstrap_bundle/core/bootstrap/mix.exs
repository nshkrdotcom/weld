defmodule FixtureBootstrap.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_bootstrap,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Fixture.Bootstrap.Application, []}
    ]
  end
end
