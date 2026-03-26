defmodule Weld.MixProject do
  use Mix.Project

  def project do
    [
      app: :weld,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      preferred_cli_env: preferred_cli_env(),
      dialyzer: dialyzer(),
      deps: deps(),
      description: "Deterministic Hex package projection for Elixir monorepos",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/weld"},
      files: ~w(lib assets guides mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/weld.svg",
      homepage_url: "https://github.com/nshkrdotcom/weld",
      source_url: "https://github.com/nshkrdotcom/weld",
      assets: %{"assets" => "assets"},
      extras: [
        "README.md": [title: "Overview"],
        "guides/getting_started.md": [title: "Getting Started"],
        "guides/architecture.md": [title: "Architecture"],
        "guides/manifest_reference.md": [title: "Manifest Reference"],
        "guides/consumer_repo_integration.md": [title: "Consumer Repo Integration"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_modules: [
        "Public API": [
          Weld,
          Weld.Manifest,
          Weld.ProjectGraph,
          Weld.Audit,
          Weld.Audit.Report
        ],
        "Build Pipeline": [
          Weld.Builder,
          Weld.ProjectGraph.Project,
          Weld.Error
        ],
        "Mix Tasks": [
          Mix.Tasks.Weld.Build,
          Mix.Tasks.Weld.Audit,
          Mix.Tasks.Weld.Verify
        ]
      ],
      groups_for_extras: [
        Guides: ~r/guides\//,
        "Project Documents": ~r/README.md|CHANGELOG.md|LICENSE/
      ]
    ]
  end

  defp preferred_cli_env do
    [
      credo: :test,
      dialyzer: :dev
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_local_path: "priv/plts",
      flags: [:error_handling, :missing_return, :underspecs, :unknown]
    ]
  end
end
