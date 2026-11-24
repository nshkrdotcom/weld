defmodule RootWorkspace.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :root_workspace_web,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:root_workspace_core, path: "../core"},
        {:root_workspace_test_support, path: "../../tooling/test_support", only: :test}
      ]
    ]
  end
end
