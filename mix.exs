defmodule Weld.MixProject do
  use Mix.Project

  @version "0.20.3"

  def project do
    [
      app: :weld,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      build_path: System.get_env("WELD_CI_BUILD_ROOT", "_build"),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["test/weld"],
      aliases: aliases(),
      dialyzer: dialyzer(),
      deps: deps(),
      description: "Deterministic Mix project composition and release preparation",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key]
    ]
  end

  def cli do
    [preferred_envs: preferred_cli_env()]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:blitz, "~> 0.5.0", only: :test, runtime: false},
      {:credo, "~> 1.7", runtime: false},
      {:dialyxir, "~> 1.4.9", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40.5", only: :dev, runtime: false},
      {:hex_core, "~> 0.21.1"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.2"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/weld"},
      files: ~w(lib assets guides mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      name: "Weld",
      main: "readme",
      logo: "assets/weld.svg",
      homepage_url: "https://github.com/nshkrdotcom/weld",
      source_url: "https://github.com/nshkrdotcom/weld",
      source_ref: "v#{@version}",
      assets: %{"assets" => "assets"},
      extras: [
        "README.md": [title: "Overview"],
        "guides/getting_started.md": [title: "Getting Started"],
        "guides/workflow.md": [title: "Workflow"],
        "guides/cli_reference.md": [title: "CLI Reference"],
        "guides/architecture.md": [title: "Architecture"],
        "guides/source_projects.md": [title: "Source-Project Artifacts"],
        "guides/manifest_reference.md": [title: "Manifest Reference"],
        "guides/testing_strategy.md": [title: "Testing Strategy"],
        "guides/qc/acceptance.md": [title: "0.20.3 Acceptance and Evidence"],
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
        "Compiler, Projection And Release": [
          Weld.Output,
          Weld.Core.Compiler,
          Weld.Core.Facts,
          Weld.Core.Identity,
          Weld.Core.Inventory,
          Weld.Plan.Inventory,
          Weld.Layout.Components,
          Weld.Layout.Flat,
          Weld.Layout.Preserve,
          Weld.Projector,
          Weld.Verifier,
          Weld.Release,
          Weld.ReleaseReceipt,
          Weld.ReleaseStatus,
          Weld.SmokeApp,
          Weld.Affected,
          Weld.AgentsVerifier
        ],
        "Workspace And Graph": [
          Weld.Workspace.Project,
          Weld.Workspace.Discovery,
          Weld.Workspace.Probe,
          Weld.Graph.Edge,
          Weld.Graph.View,
          Weld.Violation,
          Weld.Hash,
          Weld.Git,
          Weld.Error
        ],
        "Mix Tasks": [Mix.Tasks.Weld]
      ],
      groups_for_extras: [
        "Start Here": ~r/README.md|guides\/getting_started.md|guides\/workflow.md/,
        Reference:
          ~r/guides\/cli_reference.md|guides\/manifest_reference.md|guides\/source_projects.md/,
        "Deep Dive":
          ~r/guides\/architecture.md|guides\/testing_strategy.md|guides\/consumer_repo_integration.md|guides\/qc\/acceptance.md/,
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

  defp aliases do
    [
      ci: [
        "cmd mix format --check-formatted",
        "cmd mix compile --warnings-as-errors",
        "cmd env MIX_ENV=test mix run --no-start scripts/test_ci.exs",
        "cmd env MIX_ENV=test mix credo --strict",
        "cmd mix dialyzer",
        "cmd mix docs --warnings-as-errors"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :credo],
      flags: [:error_handling, :missing_return, :underspecs, :unknown]
    ]
  end
end
