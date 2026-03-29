defmodule RootWorkspace.Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :root_workspace_demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:root_workspace_web, path: "../../apps/web"}
      ]
    ]
  end
end
