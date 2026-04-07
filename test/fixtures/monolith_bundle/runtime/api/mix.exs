defmodule FixtureApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_api,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:fixture_store, path: "../../core/store"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Fixture.Api.Application, []}
    ]
  end
end
