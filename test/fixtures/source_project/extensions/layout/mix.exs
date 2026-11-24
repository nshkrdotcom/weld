defmodule Sprout.Layout.MixProject do
  use Mix.Project

  @packaged File.regular?(Path.join(__DIR__, "VERSION"))
  @version_file if @packaged, do: "VERSION", else: "../../VERSION"
  @version __DIR__ |> Path.join(@version_file) |> File.read!() |> String.trim()

  def project do
    [
      app: :sprout_layout,
      version: @version,
      elixir: "~> 1.18",
      description: "Independent layout extension for Sprout",
      deps: [dependency()],
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://example.test/sprout"},
        files: ~w(lib mix.exs VERSION)
      ]
    ]
  end

  defp dependency do
    if @packaged, do: {:sprout, "~> 0.1.0"}, else: {:sprout, "~> 0.1.0", path: "../.."}
  end
end
