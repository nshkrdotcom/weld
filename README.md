# Weld

<p align="center">
  <img src="assets/weld.svg" alt="Weld logo" width="200" />
</p>

<p align="center">
  <a href="https://hex.pm/packages/weld"><img src="https://img.shields.io/hexpm/v/weld.svg" alt="Hex.pm Version" /></a>
  <a href="https://hexdocs.pm/weld/"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="HexDocs" /></a>
  <a href="https://github.com/nshkrdotcom/weld"><img src="https://img.shields.io/badge/github-nshkrdotcom/weld-8da0cb?style=flat&logo=github" alt="GitHub" /></a>
</p>

`Weld` is a graph-native publication system for Elixir monorepos.

It keeps the source repo as a normal multi-project workspace, builds a
workspace graph, resolves one artifact boundary from a repo-local manifest,
projects a standalone Mix package, verifies that generated package with normal
Mix tooling, and prepares an archiveable release bundle for publication.

## What It Does

- discovers workspace projects from manifest globs, `blitz_workspace`, or filesystem fallback
- classifies projects as runtime, tooling, proof, or ignored
- separates publication role from project classification
- classifies internal edges by execution meaning
- exposes inspect, graph, query, affected, project, verify, and release tasks
- emits a deterministic `projection.lock.json`
- generates a standalone Mix package under `dist/hex/<package>/` (package-projection mode) or `dist/monolith/<package>/` (monolith mode)
- canonicalizes external workspace path or git deps into manifest-owned Hex deps
- synthesizes a merged application module when selected projects publish OTP children
- merges sources, tests, config, migrations, and priv from all selected projects in monolith mode
- supports explicit manifest-owned source-only monolith test support projects
- prepares a deterministic release bundle under `dist/release_bundles/<package>/...`
- archives released bundles without turning generated output into a long-lived source tree

## Installation

Add `weld` to the root project that owns the repo's packaging and release flow.

```elixir
def deps do
  [
    {:weld, "~> 0.3.2", runtime: false}
  ]
end
```

## Release Lifecycle

The intended lifecycle is:

1. run the normal source-repo checks
2. run `mix weld.release.prepare ...`
3. run `mix hex.publish` from the prepared bundle
4. run `mix weld.release.archive ...`

`weld` owns create, welded-package verification, and archive preparation. Hex
publish remains external.

## Example Manifest

Package-projection mode (default):

```elixir
[
  workspace: [
    root: "../..",
    project_globs: ["core/*", "runtime/*"]
  ],
  dependencies: [
    external_lib: [
      requirement: "~> 1.2",
      opts: []
    ]
  ],
  artifacts: [
    my_bundle: [
      roots: ["runtime/local"],
      package: [
        name: "my_bundle",
        otp_app: :my_bundle,
        version: "0.1.0",
        description: "My welded package"
      ],
      output: [
        docs: ["README.md", "guides/architecture.md"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/my_bundle/test"],
        smoke: [
          enabled: true,
          entry_file: "packaging/weld/my_bundle/smoke.ex"
        ]
      ]
    ]
  ]
]
```

Monolith mode:

```elixir
[
  workspace: [
    root: "../..",
    project_globs: ["core/*", "runtime/*"]
  ],
  artifacts: [
    my_monolith: [
      mode: :monolith,
      roots: ["runtime/api"],
      monolith_opts: [
        shared_test_configs: ["core/contracts"],
        test_support_projects: ["tooling/test_support"]
      ],
      package: [
        name: "my_monolith",
        otp_app: :my_monolith,
        version: "0.1.0",
        description: "My welded monolith"
      ],
      output: [
        docs: ["README.md"]
      ]
    ]
  ]
]
```

## Core Commands

```bash
mix weld.inspect packaging/weld/my_bundle.exs
mix weld.graph packaging/weld/my_bundle.exs --format dot
mix weld.query deps packaging/weld/my_bundle.exs runtime/local
mix weld.project packaging/weld/my_bundle.exs
mix weld.verify packaging/weld/my_bundle.exs
mix weld.release.prepare packaging/weld/my_bundle.exs
mix weld.release.archive packaging/weld/my_bundle.exs
mix weld.affected packaging/weld/my_bundle.exs --task verify.all --base main --head HEAD
```

## Generated Output

**Package-projection mode** (default) projects under `dist/hex/<package>/` using
a component-preserving layout:

```text
dist/
  hex/
    my_bundle/
      mix.exs
      projection.lock.json
      lib/
        my_bundle/
          application.ex
      components/
        core/contracts/
        runtime/local/
      test/
```

**Monolith mode** merges all selected packages into a single flat project under
`dist/monolith/<package>/`:

```text
dist/
  monolith/
    my_monolith/
      mix.exs
      projection.lock.json
      lib/
        my_monolith/
          application.ex
        fixture/
          store.ex
          api.ex
      test/
        core_store/
        runtime_api/
        support/
      config/
        config.exs
        sources/
        runtime_sources/
      priv/
        repo/migrations/
```

When selected projects expose OTP applications, `weld` synthesizes a merged
`lib/<otp_app>/application.ex` that starts those children inside the welded
package. In monolith mode this module also bootstraps per-package config at
startup via `Config.Reader`.

When selected-package tests depend on non-selected workspace projects, declare
those source-only support projects explicitly in
`monolith_opts[:test_support_projects]`. `weld` copies that support code under
`test/support/weld_projects/` and fails closed if the discovered support set
drifts from the manifest contract.

The welded artifact is a normal Mix project. `weld.verify` runs:

**Package-projection mode:**

- `mix deps.compile`
- `mix compile --warnings-as-errors --no-compile-deps`
- `mix test`
- `mix docs --warnings-as-errors`
- `mix hex.build`
- `mix hex.publish --dry-run --yes`
- optional smoke-app compilation

**Monolith mode:**

- per-package test baseline (asserts selected packages pass their own tests)
- `mix deps.get`
- `mix compile --warnings-as-errors`
- `mix test` (asserts test count ≥ baseline sum)
- `mix docs --warnings-as-errors`
- `mix hex.build`

## Guides

- [Getting Started](guides/getting_started.md)
- [Workflow](guides/workflow.md)
- [CLI Reference](guides/cli_reference.md)
- [Manifest Reference](guides/manifest_reference.md)
- [Architecture](guides/architecture.md)
- [Testing Strategy](guides/testing_strategy.md)
- [Release Process](guides/release_process.md)
- [Consumer Repo Integration](guides/consumer_repo_integration.md)

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
