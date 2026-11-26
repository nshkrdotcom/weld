Code.require_file("build_support/package.exs", __DIR__)

defmodule Workshop.Palette.MixProject do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()

  def project do
    [
      app: :workshop_palette,
      version: @version,
      elixirc_paths: ["source"],
      test_paths: ["checks"],
      deps: [{:workshop, "~> 0.1.0"}],
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://example.test/workshop"},
        files: Workshop.Palette.Package.files()
      ],
      aliases: [shade: &shade/1]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp shade(_args), do: File.read!(Path.join(__DIR__, "priv/shade.txt")) |> IO.write()
end
