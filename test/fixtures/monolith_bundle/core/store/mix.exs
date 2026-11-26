defmodule FixtureStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_store,
      version: "0.1.0",
      elixir: "~> 1.18",
      test_ignore_filters: ["test/test_helper.exs", "test/support/store_case.exs"],
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Fixture.Store.Application, []}
    ]
  end
end
