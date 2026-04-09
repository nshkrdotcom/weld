defmodule Weld.MixProject do
  use Mix.Project

  def project do
    [
      app: :weld,
      version: "0.4.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(Mix.env()),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp test_paths(:test), do: ["test/weld"]
  defp test_paths(_env), do: ["test"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:libgraph, "~> 0.16.1-mg.1", hex: :multigraph},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"}
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
      name: "Weld",
      main: "readme",
      logo: "assets/weld.svg",
      homepage_url: "https://github.com/nshkrdotcom/weld",
      source_url: "https://github.com/nshkrdotcom/weld",
      assets: %{"assets" => "assets"},
      extras: [
        "README.md": [title: "Overview"],
        "guides/getting_started.md": [title: "Getting Started"],
        "guides/workflow.md": [title: "Workflow"],
        "guides/cli_reference.md": [title: "CLI Reference"],
        "guides/architecture.md": [title: "Architecture"],
        "guides/manifest_reference.md": [title: "Manifest Reference"],
        "guides/testing_strategy.md": [title: "Testing Strategy"],
        "guides/release_process.md": [title: "Release Process"],
        "guides/consumer_repo_integration.md": [title: "Consumer Repo Integration"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_modules: [
        "Public API": [
          Weld,
          Weld.Manifest,
          Weld.Plan,
          Weld.Workspace,
          Weld.Graph
        ],
        "Projection And Release": [
          Weld.Projector,
          Weld.Verifier,
          Weld.Release,
          Weld.Lockfile,
          Weld.SmokeApp,
          Weld.Affected
        ],
        "Workspace And Graph": [
          Weld.Workspace.Project,
          Weld.Workspace.Discovery,
          Weld.Graph.Edge,
          Weld.Graph.View,
          Weld.Violation,
          Weld.Hash,
          Weld.Git,
          Weld.Error
        ],
        "Mix Tasks": [
          Mix.Tasks.Weld.Inspect,
          Mix.Tasks.Weld.Graph,
          Mix.Tasks.Weld.Query,
          Mix.Tasks.Weld.Affected,
          Mix.Tasks.Weld.Project,
          Mix.Tasks.Weld.Verify,
          Mix.Tasks.Weld.Release.Prepare,
          Mix.Tasks.Weld.Release.Archive
        ]
      ],
      groups_for_extras: [
        "Start Here": ~r/README.md|guides\/getting_started.md|guides\/workflow.md/,
        Reference: ~r/guides\/cli_reference.md|guides\/manifest_reference.md/,
        "Deep Dive":
          ~r/guides\/architecture.md|guides\/testing_strategy.md|guides\/consumer_repo_integration.md/,
        Release: ~r/guides\/release_process.md|CHANGELOG.md|LICENSE/
      ]
    ]
  end

  defp preferred_cli_env do
    [
      credo: :test,
      dialyzer: :dev,
      docs: :dev
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
