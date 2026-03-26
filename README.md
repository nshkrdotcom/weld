# Weld

<p align="center">
  <img src="assets/weld.svg" alt="Weld logo" width="200" />
</p>

<p align="center">
  <a href="https://hex.pm/packages/weld"><img src="https://img.shields.io/hexpm/v/weld.svg" alt="Hex.pm Version" /></a>
  <a href="https://hexdocs.pm/weld/"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="HexDocs" /></a>
  <a href="https://github.com/nshkrdotcom/weld"><img src="https://img.shields.io/badge/github-nshkrdotcom/weld-8da0cb?style=flat&logo=github" alt="GitHub" /></a>
</p>

Deterministic Hex package projection for Elixir monorepos.

`Weld` lets a source monorepo keep multiple internal Mix projects while
shipping one external Hex package. It audits the selected projects, assembles a
generated standalone package under `dist/hex/<package_name>/`, and verifies the
result with normal Mix tooling.

## What It Does

- Loads a projection manifest from `packaging/hex_projections/*.exs`
- Reads selected child Mix projects directly from the source monorepo
- Internalizes selected sibling `path:` dependencies instead of publishing them
- Rejects unsupported `git` and unresolved sibling dependencies
- Copies source trees into a generated package projection
- Renders a standalone `mix.exs` with compile paths over copied sources
- Audits app-identity-sensitive code for strict bundle modes
- Verifies generated packages with `mix compile`, `mix docs`, and `mix hex.build`

## Installation

Add `weld` to the root project that owns your monorepo packaging workflow.

```elixir
def deps do
  [
    {:weld, "~> 0.1.0", runtime: false}
  ]
end
```

`runtime: false` is the intended default because `Weld` is a build and release
tool, not a runtime dependency for the published package.

## Quick Start

Create a projection manifest in your source repo:

```elixir
%{
  package_name: "jido_integration",
  otp_app: :jido_integration,
  version: "0.1.0",
  mode: :library_bundle,
  source_projects: [
    "core/contracts",
    "core/platform",
    "runtime/local"
  ],
  public_entry_modules: [
    Jido.Integration
  ],
  copy: %{
    docs: [
      "README.md",
      "CHANGELOG.md",
      "guides/architecture.md"
    ],
    assets: ["guides/assets"],
    priv: :auto
  },
  docs: %{
    main: "readme"
  }
}
```

Then run:

```bash
mix weld.audit packaging/hex_projections/jido_integration.exs
mix weld.build packaging/hex_projections/jido_integration.exs
mix weld.verify packaging/hex_projections/jido_integration.exs
```

Generated output lands in:

```text
dist/
  hex/
    jido_integration/
      mix.exs
      README.md
      CHANGELOG.md
      vendor/
        core_contracts/
        core_platform/
        runtime_local/
```

## Public API

`Weld` exposes a small library surface:

```elixir
Weld.audit!("packaging/hex_projections/jido_integration.exs")
Weld.build!("packaging/hex_projections/jido_integration.exs")
Weld.verify!("packaging/hex_projections/jido_integration.exs")
```

Use the Mix tasks for normal CI and release automation. Use the library API when
you want to compose projection behavior inside repo-local tooling.

## Bundle Modes

- `:library_bundle` assembles a generated package and reports audit findings
  without blocking the build.
- `:strict_library_bundle` blocks when app-identity-sensitive code is detected.
- `:runtime_bundle` is reserved for future explicit runtime assembly support.

## TDD / RGR

This repo is built fixture-first:

- manifest loading is covered by acceptance-style tests
- project graph loading is covered against real fixture monorepos
- generated projections are compiled in tests
- strict audit behavior is tested with a failing fixture

That keeps the implementation honest and gives consumer repos a stable contract
to integrate against.

## Initial Version Boundary

`Weld` 0.1 intentionally stays narrow:

- one monorepo
- many internal Mix projects
- one generated publishable package
- deterministic docs and packaging
- explicit failure on unsupported strict bundle shapes

It does not try to solve release assembly, multiple packages per manifest, or
automatic rewrites of incompatible OTP app identity assumptions.

## Guides

- [Getting Started](guides/getting_started.md)
- [Architecture](guides/architecture.md)
- [Manifest Reference](guides/manifest_reference.md)
- [Consumer Repo Integration](guides/consumer_repo_integration.md)
