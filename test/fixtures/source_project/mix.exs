defmodule Sprout.MixProject do
  use Mix.Project

  @version __DIR__ |> Path.join("VERSION") |> File.read!() |> String.trim()
  def project do
    [
      app: :sprout,
      version: @version,
      elixir: "~> 1.18",
      description: "Neutral source-project integration fixture",
      elixirc_paths: ["components/pure/lib", "components/runtime/lib"],
      deps: [{:ex_doc, "~> 0.40", only: :dev, runtime: false}],
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://example.test/sprout"},
        files: ~w(mix.exs VERSION components/pure/lib components/runtime/lib priv README.md)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
