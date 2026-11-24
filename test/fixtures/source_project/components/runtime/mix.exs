defmodule Sprout.Runtime.MixProject do
  use Mix.Project
  @version __DIR__ |> Path.join("../../VERSION") |> File.read!() |> String.trim()

  def project,
    do: [
      app: :sprout_runtime,
      version: @version,
      elixir: "~> 1.18",
      deps: [{:sprout_pure, path: "../pure"}]
    ]
end
