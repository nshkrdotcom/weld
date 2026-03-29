defmodule Fixture.Runtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_runtime,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:fixture_contracts, path: "../../core/contracts"},
        {:jason, "~> 1.4"}
      ]
    ]
  end
end
