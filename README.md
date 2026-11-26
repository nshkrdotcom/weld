<p align="center">
  <img src="assets/weld.svg" alt="Weld logo" width="200" />
</p>

<h1 align="center">Weld</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/weld"><img src="https://img.shields.io/badge/github-nshkrdotcom/weld-8da0cb?style=flat&logo=github" alt="GitHub" /></a>
  <a href="https://github.com/nshkrdotcom/weld/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-4c9f70.svg" alt="MIT License" /></a>
</p>

`Weld` is a deterministic projection and release-preparation tool for Elixir repositories.

Multi-project Elixir workspaces often split code across internal Mix projects for fast isolated testing, boundary enforcement, or optional extensions, while downstream consumers want a single ordinary Mix dependency or Hex package. `Weld` bridges that gap without turning generated output into a second hand-maintained source tree: it reads a repo-local manifest, resolves the workspace dependency graph, projects a standalone Mix project under `.weld/`, verifies that generated project with standard Mix commands, and prepares content-addressed release bundles and optional Git projection snapshots.

## When To Use Weld

Use `Weld` when maintainers want to:

- develop in a multi-project Elixir workspace while publishing or sharing a cohesive Mix package
- merge selected workspace applications, configs, migrations, and tests into a single deployable or testable monolith project
- preserve an existing root or nested Mix project (`mode: :source_project`) while producing portable full candidates, symlinked live development views, or immutable release bundles
- publish durable generated-source snapshots on an orphan `projection/<package_name>` branch without mixing generated files into `main`

Consumers of a root Mix project, a generated projection, a `projection/<package_name>` branch, or a published Hex package use ordinary `mix` commands (`path:`, `git:`/`github:`, or Hex) and **never need to install Weld**.

## Relationship To Ordinary Mix Workflows

- **Main-tree source authority:** `main` (and the repository's normal Mix projects) remains the single source of truth for code, tests, formatting, and static analysis.
- **Maintainer-only tooling:** `Weld` runs only when maintainers inspect the workspace graph, project views, verify packaged artifacts, or prepare/track releases. Ordinary `mix deps.get`, `mix compile`, and `mix test` workflows do not invoke `Weld`.
- **Isolated snapshot history:** `mix weld.release.track` commits prepared `project/` trees onto an orphan `projection/<package_name>` branch so downstream Git consumers can pin projected snapshots without coupling to workspace layout or polluting `main`.

## Projection Modes And Lifecycle

`Weld` supports three artifact composition modes declared per artifact in the manifest:

| Mode | What the artifact builds |
| --- | --- |
| `:package_projection` *(default)* | Composes a selected Mix dependency closure under `components/` and generates one Mix project. |
| `:monolith` | Merges selected sources, assets, migrations, configuration, and tests into a flat Mix project. |
| `:source_project` | Preserves the existing Mix project at one workspace root or subdirectory, including its own package metadata and compiler inputs. |

Every mode supports two projection kinds:

- **Live** (`mix weld.project --live`) links source into `.weld/live/<artifact>/` for local Mix path consumers. In a package or source-project view, edits, additions, and deletions within existing linked directories are visible on the next build. A live monolith links individual files, so file additions, removals, or remaps require refresh. Each mode checks the metadata and inputs that determine its layout. Live views reject Hex build and publication tasks.
- **Full** (`mix weld.project`) writes a portable project of regular files to `.weld/full/<artifact>/project/`. `mix weld.verify` and `mix release.prepare` verify full projects. A prepared release binds the verified project, docs, optional Hex tarball, lock, source revision, and toolchain beneath `.weld/releases/<artifact>/<identity>/`.

## Installation For Maintainers

These examples target Weld 0.19.0. Resolve the Hex dependency once that version is published. Add it to the workspace `mix.exs` or to a dedicated maintainer project such as `tools/maintainer/mix.exs`.

```elixir
def deps do
  [
    {:weld, "~> 0.19.0", only: [:dev, :test], runtime: false}
  ]
end
```

Initialize the repository's `.weld/` directory and `.gitignore` rule before running clean-tree release preparation:

```bash
mix weld.setup
```

## Core Commands

When `[manifest_path]` is omitted, `Weld` auto-discovers `build_support/weld.exs`, then `build_support/weld_contract.exs`, then a single `packaging/weld/*.exs`:

```bash
mix weld.setup
mix weld.explain
mix weld.doctor
mix weld.status
mix weld.inspect
mix weld.graph --format dot
mix weld.query deps runtime/local
mix weld.project
mix weld.project --live
mix weld.verify
mix weld.agents.verify
mix release.prepare
mix release.status
mix release.track --tag-release --push
mix release.verify_tag <tag>
mix release.stage --fresh
mix release.publish
mix release.archive --identity <sha>
mix weld.affected --task verify.all --base main --head HEAD
```

Start with `mix release.status` to list the repository's release artifacts and
see their source roots, projection paths, bundle identities, and default tags.
Use `--artifact <name>` to select an artifact for a release operation in a
multi-artifact repository. Pass the manifest path explicitly when discovery
finds multiple manifests or the manifest is in a custom location.

## Repository-Root `.weld/` Layout

All Weld-managed state lives under `<checkout_root>/.weld/`, serialized by an exclusive checkout lock (`.weld/.lock`) and guarded by ownership markers (`.owner`):

```text
.weld/
  .owner                              # ownership marker ("weld-output/v1")
  .lock/owner                         # active writer PID and node while mutating
  live/<artifact>/                    # symlinked live view
  full/<artifact>/project/            # standalone full Mix project + provenance/lock
  cache/<projection_id>/<toolchain>/  # warm Mix deps/ and build/ for verification
  releases/<artifact>/
    CURRENT                           # pointer to the latest verified <identity>
    <identity>/                       # immutable release.json, project/, docs/, *.tar
  publish/<artifact>/<identity>/project/ # writable Hex publish workspace
  archive/<artifact>/<identity>/      # archived post-release bundle copy
  staging/                            # atomic staging directories during mutation
  smoke/                              # temporary consumer smoke-test projects
  worktrees/                          # temporary Git worktrees during release.track
```

`Weld` rejects symlinks along managed output roots, refuses to overwrite unmanaged directories, and preserves any legacy `dist/` directories untouched for manual migration.

## Compose Two Artifacts From One Workspace

Suppose `core/engine` owns the reusable engine and `apps/console` declares
`{:engine, path: "../../core/engine"}`. Add `build_support/weld.exs` in the
workspace root:

```elixir
[
  workspace: [root: "..", project_globs: ["core/*", "apps/*"]],
  artifacts: [
    engine_bundle: [
      roots: ["core/engine"],
      package: [name: "engine_bundle", otp_app: :engine_bundle, version: "0.1.0"]
    ],
    console_bundle: [
      roots: ["apps/console"],
      package: [name: "console_bundle", otp_app: :console_bundle, version: "0.1.0"]
    ]
  ]
]
```

Weld follows the console's declared dependency and includes both projects in
`console_bundle`. `engine_bundle` includes only the engine. Use each artifact
as an alternative package, since both contain the engine's modules. If console
should depend on a separately released engine, declare an artifact-local
boundary as described in the [manifest reference](guides/manifest_reference.md).

```bash
mix weld.setup build_support/weld.exs
mix weld.project build_support/weld.exs --artifact console_bundle --live
mix weld.project build_support/weld.exs --artifact console_bundle
mix weld.project build_support/weld.exs --artifact engine_bundle
```

In a sibling consumer, declare
`{:console_bundle, path: "../workspace/.weld/live/console_bundle"}`
and run `mix deps.get` and `mix compile`. Use the corresponding full project
for a portable copy and a prepared project for an immutable input. The
[getting started guide](guides/getting_started.md) covers artifact verification
and release preparation.

## Verification And Release Lifecycle

`mix weld.verify` regenerates `.weld/full/<artifact>/project/` and runs a mode-specific verification gate using isolated build/dependency caches under `.weld/cache/`:

- **Package-projection and source-project modes:** `mix deps.get`, `mix deps.compile`, `mix compile --warnings-as-errors --no-compile-deps`, `mix test`, `mix docs --warnings-as-errors --output doc`, optional external smoke-app compilation, `mix hex.build` (when `verify.hex_build` is `true`), and `mix hex.publish --dry-run --yes` (when both `hex_build` and `hex_publish` are `true`).
- **Monolith mode:** per-selected-project `mix test` baseline, `mix deps.get`, `mix compile --warnings-as-errors`, `mix test` (enforcing `test_count >= baseline`), `mix docs --warnings-as-errors --output doc`, `mix hex.build` (when `hex_build` is `true`), and `mix hex.publish --dry-run --yes` (when both `hex_build` and `hex_publish` are `true`).

A repeated `mix weld.project` validates the source and generated output before
reusing an unchanged view. Use `--no-cache` to rebuild it. Locked source-project
artifacts can also opt into verified bundle reuse with
`mix release.prepare --reuse CONTEXT`. See the [release process](guides/release_process.md)
for eligibility and how to choose a context.

Set `verify: [hex_build: false]` for internal artifacts that intentionally use non-Hex Git dependencies, or `verify: [hex_publish: false]` to build a Hex tarball without running `hex.publish --dry-run`.

The standard release flow separates deterministic bundle preparation from credentialed publication:

1. Run the source workspace's own test and quality gates on a clean Git working tree.
2. Run `mix release.prepare` to verify and write `.weld/releases/<artifact>/<identity>/`.
3. Run `mix release.status` to confirm the artifact and bundle identity.
4. Run `mix release.track --identity <sha> --tag-release --push` to record it on `projection/<package_name>` and create the annotated release tag.
5. Run `mix release.publish --identity <sha> --tag <tag>` for the interactive Hex handoff.
6. Run `mix release.archive --identity <sha>` to preserve the same verified bundle under `.weld/archive/<artifact>/<identity>/`.

Also create and push an annotated `v<version>` tag on the qualified source commit on `main`. The separate `<package>-v<version>` tag points to the projection commit and carries the Weld receipt. If several packages of the same version come from the same source commit, one `v<version>` tag records that source commit.

Prepared `project/` trees and tracked Git projections retain `weld.provenance.json` and `projection.lock.json` for auditability; Hex tarballs omit `projection.lock.json`.

## Guides

- [Getting Started](guides/getting_started.md)
- [Workflow](guides/workflow.md)
- [Source-Project Artifacts](guides/source_projects.md)
- [CLI Reference](guides/cli_reference.md)
- [Manifest Reference](guides/manifest_reference.md)
- [Architecture](guides/architecture.md)
- [Testing Strategy](guides/testing_strategy.md)
- [Release Process](guides/release_process.md)
- [Consumer Repo Integration](guides/consumer_repo_integration.md)

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
