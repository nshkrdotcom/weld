defmodule Sprout.Probe.MixProject do
  use Mix.Project

  def project do
    [
      app: :sprout_probe,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [{:jason, "~> 1.4", only: :test}]
    ]
  end
end
