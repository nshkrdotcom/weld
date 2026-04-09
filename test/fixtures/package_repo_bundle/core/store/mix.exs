defmodule FixtureStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_store,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:ecto_sql, "~> 3.13"},
        {:postgrex, "~> 0.21"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ecto_sql]
    ]
  end
end
