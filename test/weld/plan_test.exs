defmodule Weld.PlanTest do
  use ExUnit.Case, async: false

  alias Weld.FixtureCase
  alias Weld.Graph
  alias Weld.Plan

  test "computes a runtime closure from roots" do
    plan = Plan.build!(FixtureCase.manifest_path("library_bundle", "fixture_bundle"))

    assert plan.selected_ids == ["core/contracts", "runtime/local"]
    assert plan.excluded_ids == []
    assert plan.violations == []
  end

  test "keeps test-only tooling out of the selected closure while preserving the edge" do
    plan =
      Plan.build!(FixtureCase.manifest_path("root_workspace", "artifacts"),
        artifact: "web_bundle"
      )

    assert plan.selected_ids == ["apps/core", "apps/web"]
    refute "tooling/test_support" in plan.selected_ids

    assert Enum.any?(Graph.edges(plan.graph), fn edge ->
             edge.from == "apps/web" and edge.to == "tooling/test_support" and edge.kind == :test
           end)
  end

  test "explains why one runtime project depends on another" do
    result =
      Weld.query_why!(
        FixtureCase.manifest_path("root_workspace", "artifacts"),
        "apps/web",
        "apps/core",
        artifact: "web_bundle"
      )

    assert result.path == ["apps/web", "apps/core"]
  end

  test "rewrites external path and scm deps through manifest dependency declarations" do
    manifest_path = external_dependency_manifest!()
    plan = Plan.build!(manifest_path)

    assert plan.violations == []

    assert Enum.map(plan.external_deps, & &1.app) == [:external_lib, :git_only]

    assert Enum.any?(plan.external_deps, fn dep ->
             dep.app == :external_lib and dep.requirement == "~> 1.2.0" and
               dep.original == {:external_lib, "~> 1.2.0"}
           end)

    assert Enum.any?(plan.external_deps, fn dep ->
             dep.app == :git_only and dep.requirement == "~> 0.5.0" and
               dep.original == {:git_only, "~> 0.5.0"}
           end)
  end

  test "ignores tooling-only violations outside the selected artifact closure" do
    manifest_path = tooling_violation_manifest!()
    plan = Plan.build!(manifest_path)

    assert plan.selected_ids == ["apps/runtime"]
    assert plan.violations == []
  end

  test "does not treat test-only cycles as package graph cycles" do
    manifest_path = test_cycle_manifest!()
    plan = Plan.build!(manifest_path)

    assert plan.selected_ids == ["apps/runtime", "core/contracts"]
    assert plan.violations == []
  end

  defp external_dependency_manifest! do
    repo_root = FixtureCase.unique_tmp_dir("weld_external_dependencies")
    external_root = Path.join(Path.dirname(repo_root), "external_lib")

    File.mkdir_p!(Path.join([repo_root, "core", "shared", "lib"]))
    File.mkdir_p!(Path.join([repo_root, "apps", "app", "lib"]))
    File.mkdir_p!(Path.join([repo_root, "packaging", "weld"]))
    File.mkdir_p!(external_root)

    File.write!(Path.join(repo_root, "README.md"), "# External Dependency Fixture\n")

    File.write!(
      Path.join([repo_root, "core", "shared", "mix.exs"]),
      """
      defmodule Shared.MixProject do
        use Mix.Project

        def project do
          [
            app: :shared,
            version: "0.1.0",
            elixir: "~> 1.18",
            deps: []
          ]
        end
      end
      """
    )

    File.write!(
      Path.join([repo_root, "core", "shared", "lib", "shared.ex"]),
      """
      defmodule Shared do
        def ping, do: :pong
      end
      """
    )

    File.write!(
      Path.join([repo_root, "apps", "app", "mix.exs"]),
      """
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
      """
    )

    File.write!(
      Path.join([repo_root, "apps", "app", "lib", "app.ex"]),
      """
      defmodule App do
        def ping, do: Shared.ping()
      end
      """
    )

    File.write!(
      Path.join([external_root, "mix.exs"]),
      """
      defmodule ExternalLib.MixProject do
        use Mix.Project

        def project do
          [
            app: :external_lib,
            version: "1.2.0",
            elixir: "~> 1.18",
            deps: []
          ]
        end
      end
      """
    )

    manifest_path = Path.join([repo_root, "packaging", "weld", "app_bundle.exs"])

    File.write!(
      manifest_path,
      """
      [
        workspace: [
          root: "../..",
          project_globs: ["core/*", "apps/*"]
        ],
        dependencies: [
          external_lib: [requirement: "~> 1.2.0"],
          git_only: [requirement: "~> 0.5.0"]
        ],
        artifacts: [
          app_bundle: [
            roots: ["apps/app"],
            package: [
              name: "app_bundle",
              otp_app: :app_bundle,
              version: "0.1.0",
              description: "External dependency fixture"
            ],
            output: [
              docs: ["README.md"]
            ]
          ]
        ]
      ]
      """
    )

    manifest_path
  end

  defp tooling_violation_manifest! do
    repo_root = FixtureCase.unique_tmp_dir("weld_tooling_violation")
    external_root = Path.join(Path.dirname(repo_root), "tooling_external")

    File.mkdir_p!(Path.join([repo_root, "apps", "runtime", "lib"]))
    File.mkdir_p!(Path.join([repo_root, "tooling", "root", "lib"]))
    File.mkdir_p!(Path.join([repo_root, "packaging", "weld"]))
    File.mkdir_p!(external_root)

    File.write!(Path.join(repo_root, "README.md"), "# Tooling Violation Fixture\n")

    File.write!(
      Path.join([repo_root, "apps", "runtime", "mix.exs"]),
      """
      defmodule Runtime.MixProject do
        use Mix.Project

        def project do
          [
            app: :runtime_app,
            version: "0.1.0",
            elixir: "~> 1.18",
            deps: []
          ]
        end
      end
      """
    )

    File.write!(
      Path.join([repo_root, "apps", "runtime", "lib", "runtime_app.ex"]),
      """
      defmodule RuntimeApp do
      end
      """
    )

    File.write!(
      Path.join([repo_root, "tooling", "root", "mix.exs"]),
      """
      defmodule ToolingRoot.MixProject do
        use Mix.Project

        def project do
          [
            app: :tooling_root,
            version: "0.1.0",
            elixir: "~> 1.18",
            deps: [{:outside_dep, path: "../../../tooling_external"}]
          ]
        end
      end
      """
    )

    File.write!(
      Path.join([repo_root, "tooling", "root", "lib", "tooling_root.ex"]),
      """
      defmodule ToolingRoot do
      end
      """
    )

    File.write!(
      Path.join([external_root, "mix.exs"]),
      """
      defmodule OutsideDep.MixProject do
        use Mix.Project

        def project do
          [
            app: :outside_dep,
            version: "0.1.0",
            elixir: "~> 1.18",
            deps: []
          ]
        end
      end
      """
    )

    manifest_path = Path.join([repo_root, "packaging", "weld", "runtime_bundle.exs"])

    File.write!(
      manifest_path,
      """
      [
        workspace: [
          root: "../..",
          project_globs: ["apps/*", "tooling/*"]
        ],
        classify: [
          tooling: ["tooling/root"]
        ],
        artifacts: [
          runtime_bundle: [
            roots: ["apps/runtime"],
            package: [
              name: "runtime_bundle",
              otp_app: :runtime_bundle,
              version: "0.1.0",
              description: "Tooling violation fixture"
            ],
            output: [
              docs: ["README.md"]
            ]
          ]
        ]
      ]
      """
    )

    manifest_path
  end

  defp test_cycle_manifest! do
    repo_root = FixtureCase.unique_tmp_dir("weld_test_cycle")

    File.mkdir_p!(Path.join([repo_root, "apps", "runtime", "lib"]))
    File.mkdir_p!(Path.join([repo_root, "core", "contracts", "lib"]))
    File.mkdir_p!(Path.join([repo_root, "packaging", "weld"]))
    File.write!(Path.join(repo_root, "README.md"), "# Test Cycle Fixture\n")

    File.write!(
      Path.join([repo_root, "core", "contracts", "mix.exs"]),
      """
      defmodule Contracts.MixProject do
        use Mix.Project

        def project do
          [
            app: :contracts,
            version: "0.1.0",
            elixir: "~> 1.18",
            deps: [{:runtime_app, path: "../../apps/runtime", only: [:dev, :test]}]
          ]
        end
      end
      """
    )

    File.write!(
      Path.join([repo_root, "core", "contracts", "lib", "contracts.ex"]),
      """
      defmodule Contracts do
      end
      """
    )

    File.write!(
      Path.join([repo_root, "apps", "runtime", "mix.exs"]),
      """
      defmodule RuntimeCycle.MixProject do
        use Mix.Project

        def project do
          [
            app: :runtime_app,
            version: "0.1.0",
            elixir: "~> 1.18",
            deps: [{:contracts, path: "../../core/contracts"}]
          ]
        end
      end
      """
    )

    File.write!(
      Path.join([repo_root, "apps", "runtime", "lib", "runtime_app.ex"]),
      """
      defmodule RuntimeApp do
      end
      """
    )

    manifest_path = Path.join([repo_root, "packaging", "weld", "cycle_bundle.exs"])

    File.write!(
      manifest_path,
      """
      [
        workspace: [
          root: "../..",
          project_globs: ["apps/*", "core/*"]
        ],
        artifacts: [
          cycle_bundle: [
            roots: ["apps/runtime"],
            package: [
              name: "cycle_bundle",
              otp_app: :cycle_bundle,
              version: "0.1.0",
              description: "Test cycle fixture"
            ],
            output: [
              docs: ["README.md"]
            ]
          ]
        ]
      ]
      """
    )

    manifest_path
  end
end
