<p align="center">
  <img src="assets/weld.svg" alt="Weld logo" width="200" />
</p>

<h1 align="center">Weld</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/weld"><img src="https://img.shields.io/badge/github-nshkrdotcom/weld-8da0cb?style=flat&logo=github" alt="GitHub" /></a>
  <a href="https://github.com/nshkrdotcom/weld/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-4c9f70.svg" alt="MIT License" /></a>
</p>

Weld is an artifact compiler for Elixir workspaces. It resolves explicitly declared Mix projects, plans standalone artifacts, materializes development views, qualifies detached copies, and prepares immutable release bundles. Downstream consumers use ordinary Mix and do not install Weld.

## Install

These examples target Weld 0.20.0. Resolve the Hex dependency after publication.

```elixir
{:weld, "~> 0.20.0", only: [:dev, :test], runtime: false}
```

## Start here

Weld 0.20.0 is a breaking release. Use schema 2 manifests and the single `mix weld` command. Prior manifest schemas, dotted commands, and prior state formats are not supported.

```bash
mix weld setup
mix weld plan --artifact weld
mix weld project --artifact weld --kind full
mix weld verify --artifact weld
mix weld prepare --artifact weld
mix weld status --artifact weld
mix weld path --artifact weld --kind bundle
```

`setup` initializes managed state in `.weld/v2/` and the checkout ignore rule. Commit the ignore rule before preparing a release. The default manifest is `build_support/weld.exs`; use `--manifest PATH` for another manifest.

Three layouts share a semantic plan: `:components` embeds selected workspace components, `:flat` merges their sources into a single project, and `:preserve` copies a declared existing project. Full projects are detached regular-file copies; live views link source for development and are not releasable. Qualification operates on a separate copy. A prepared bundle includes the qualified project, documentation and, when enabled, the exact package archive. Git tracking, staging and publication are distinct operations. Never publish from a mutable development project.

See the [manifest reference](guides/manifest_reference.md), [CLI reference](guides/cli_reference.md), [architecture](guides/architecture.md), and [release process](guides/release_process.md).

## Maintainer quality gates

Run `mix ci` and qualify the detached artifact and its consumers before release. The 0.20.0 source revision must pass these gates, not merely generate output.

License: MIT.
