defmodule FixtureRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_runtime,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:fixture_state, path: "../../core/state"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end
end
