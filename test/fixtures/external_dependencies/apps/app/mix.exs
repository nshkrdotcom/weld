defmodule App.MixProject do
  use Mix.Project

  def project do
    [
      app: :app,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:shared, path: "../../core/shared"},
      {:external_lib, path: "../../../external_lib"},
      {:git_only, github: "example/git_only"}
    ]
  end
end
