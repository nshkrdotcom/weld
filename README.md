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
- generates a standalone Mix package under `dist/hex/<package>/`
- prepares a deterministic release bundle under `dist/release_bundles/<package>/...`
- archives released bundles without turning generated output into a long-lived source tree

## Installation

Add `weld` to the root project that owns the repo's packaging and release flow.

```elixir
def deps do
  [
    {:weld, "~> 0.1.0", runtime: false}
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

```elixir
[
  workspace: [
    root: "../..",
    project_globs: ["core/*", "runtime/*"]
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

`Weld` projects a standalone package under `dist/hex/<package>/` using a
component-preserving layout:

```text
dist/
  hex/
    my_bundle/
      mix.exs
      projection.lock.json
      components/
        core/contracts/
        runtime/local/
      test/
```

The welded artifact is a normal Mix project. `weld.verify` runs:

- `mix compile --warnings-as-errors`
- `mix test`
- `mix docs --warnings-as-errors`
- `mix hex.build`
- `mix hex.publish --dry-run --yes`
- optional smoke-app compilation

## Guides

- [Getting Started](guides/getting_started.md)
- [Workflow](guides/workflow.md)
- [CLI Reference](guides/cli_reference.md)
- [Manifest Reference](guides/manifest_reference.md)
- [Architecture](guides/architecture.md)
- [Testing Strategy](guides/testing_strategy.md)
- [Release Process](guides/release_process.md)
- [Consumer Repo Integration](guides/consumer_repo_integration.md)
