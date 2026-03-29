defmodule RootWorkspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :root_workspace,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [],
      blitz_workspace: [
        projects: ["apps/*", "proofs/*", "tooling/*"]
      ]
    ]
  end
end
