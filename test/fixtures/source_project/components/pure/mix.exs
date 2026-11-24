defmodule Sprout.Pure.MixProject do
  use Mix.Project
  @version __DIR__ |> Path.join("../../VERSION") |> File.read!() |> String.trim()

  def project, do: [app: :sprout_pure, version: @version, elixir: "~> 1.18", deps: []]
end
