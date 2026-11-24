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
- maintain an authoritative root Mix project that compiles internal component directories (`mode: :source_project`) while producing portable full candidates, symlinked live development views, or immutable release bundles
- publish durable generated-source snapshots on an orphan `projection/<package_name>` branch without mixing generated files into `main`

Consumers of a root Mix project, a generated projection, a `projection/<package_name>` branch, or a published Hex package use ordinary `mix` commands (`path:`, `git:`/`github:`, or Hex) and **never need to install Weld**.

## Relationship To Ordinary Mix Workflows

- **Main-tree source authority:** `main` (and the repository's normal Mix projects) remains the single source of truth for code, tests, formatting, and static analysis.
- **Maintainer-only tooling:** `Weld` runs only when maintainers inspect the workspace graph, project views, verify packaged artifacts, or prepare/track releases. Ordinary `mix deps.get`, `mix compile`, and `mix test` workflows do not invoke `Weld`.
- **Isolated snapshot history:** `mix weld.release.track` commits prepared `project/` trees onto an orphan `projection/<package_name>` branch so downstream Git consumers can pin projected snapshots without coupling to workspace layout or polluting `main`.

## Projection Modes And Lifecycle

`Weld` supports three artifact composition modes declared per artifact in the manifest:

| Mode | Purpose | Generated Output |
| --- | --- | --- |
| `:package_projection` *(default)* | Projects a selected closure of workspace projects under `components/<project_id>/`, rewrites workspace deps to canonical external deps, and synthesizes a merged OTP application module when needed. | `.weld/full/<artifact>/project/` |
| `:monolith` | Merges `lib/`, `priv/`, migrations, configs, and declared `:test_paths` from selected projects into one flat Mix project with conflict renaming and runtime config bootstrap. | `.weld/full/<artifact>/project/` |
| `:source_project` | Preserves an authoritative root `mix.exs` (`roots: ["."]`) that already owns its OTP app, compiler paths, and Hex file list, materializing either a portable copy or a symlinked live view. | `.weld/full/<artifact>/project/` and `.weld/live/<artifact>/` |

### Live Versus Full Projections

- **Full projection (`mix weld.project`):** Copies declared or selected files into `.weld/full/<artifact>/project/` with zero symlinks, writes `weld.provenance.json` (`kind: "full"` and SHA-256 `artifact_id`) plus `projection.lock.json`, and serves as the input to `mix weld.verify` and `mix release.prepare`. Full projections are self-contained and portable outside the checkout.
- **Live projection (`mix weld.project --live`, `:source_project` only):** Creates `.weld/live/<artifact>/` with symlinked source/asset paths and a generated `mix.exs` wrapper whose compiler and test paths resolve back into the source checkout. Edits under existing directories take effect immediately on a path consumer's next `mix compile`, while fingerprints over `mix.exs`, `mix.lock`, the Weld manifest, and `structural_inputs` fail fast with an explicit refresh command if structural metadata changes. Live views refuse `mix hex.build` and `mix hex.publish`.
- **Prepared release bundle (`mix release.prepare`):** Verifies a full projection from a clean checkout and writes an immutable bundle at `.weld/releases/<artifact>/<identity>/` (updating `.weld/releases/<artifact>/CURRENT`), binding verified `project/`, rendered `docs/`, optional Hex tarball, lock digest, source revision, and toolchain into `release.json`.

## Installation For Maintainers

Add `weld` either to the workspace root `mix.exs` or—when keeping a public `:source_project` root completely free of packaging tooling—to a dedicated maintainer Mix project (for example `tools/maintainer/mix.exs`):

```elixir
def deps do
  [
    {:weld, "~> 0.15.0", only: [:dev, :test], runtime: false}
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
mix weld.inspect
mix weld.graph --format dot
mix weld.query deps runtime/local
mix weld.project
mix weld.project --live
mix weld.verify
mix weld.agents.verify
mix release.prepare
mix release.track
mix release.archive
mix weld.affected --task verify.all --base main --head HEAD
```

Pass an explicit manifest path (and `--artifact <name>` when a manifest defines multiple artifacts) when running from a nested maintainer project or a repo with multiple manifests.

## Repository-Root `.weld/` Layout

All Weld-managed state lives under `<checkout_root>/.weld/`, serialized by an exclusive checkout lock (`.weld/.lock`) and guarded by ownership markers (`.owner`):

```text
.weld/
  .owner                              # ownership marker ("weld-output/v1")
  .lock/owner                         # active writer PID and node while mutating
  live/<artifact>/                    # symlinked live view (:source_project only)
  full/<artifact>/project/            # standalone full Mix project + provenance/lock
  cache/<projection_id>/<toolchain>/  # warm Mix deps/ and build/ for verification
  releases/<artifact>/
    CURRENT                           # pointer to the latest verified <identity>
    <identity>/                       # immutable release.json, project/, docs/, *.tar
  archive/<artifact>/<identity>/      # archived post-release bundle copy
  staging/                            # atomic staging directories during mutation
  smoke/                              # temporary consumer smoke-test projects
  worktrees/                          # temporary Git worktrees during release.track
```

`Weld` rejects symlinks along managed output roots, refuses to overwrite unmanaged directories, and preserves any legacy `dist/` directories untouched for manual migration.

## Example Manifests

### Package-Projection Mode (Default)

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
        description: "My welded package",
        docs: [
          logo: "assets/my_bundle.svg",
          source_url: "https://github.com/example/my_bundle",
          source_ref: "v0.1.0",
          extra_titles: %{"README.md" => "Overview"},
          groups_for_extras: [
            {"Start Here", ["README.md"]},
            {"Release", ["CHANGELOG.md", "LICENSE"]}
          ]
        ]
      ],
      output: [
        docs: ["README.md", "CHANGELOG.md", "LICENSE", "guides/architecture.md"],
        assets: ["assets/my_bundle.svg"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/my_bundle/test"],
        hex_build: true,
        hex_publish: true,
        smoke: [
          enabled: true,
          entry_file: "packaging/weld/my_bundle/smoke.ex"
        ]
      ]
    ]
  ]
]
```

### Source-Project Mode

```elixir
[
  workspace: [
    root: "..",
    project_globs: ["components/*", "extensions/*"]
  ],
  artifacts: [
    my_sdk: [
      mode: :source_project,
      roots: ["."],
      source_project: [
        files: ~w(mix.exs mix.lock VERSION LICENSE README.md components/core/lib components/runtime/lib priv test),
        structural_inputs: ~w(mix.exs VERSION components/core/mix.exs components/runtime/mix.exs)
      ],
      package: [
        name: "my_sdk",
        otp_app: :my_sdk,
        version: "0.1.0",
        elixir: "~> 1.18",
        description: "Source-root Mix package"
      ],
      verify: [hex_build: true, hex_publish: false]
    ]
  ]
]
```

### Monolith Mode

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
      ],
      verify: [
        hex_build: false
      ]
    ]
  ]
]
```

## Verification And Release Lifecycle

`mix weld.verify` regenerates `.weld/full/<artifact>/project/` and runs a mode-specific verification gate using isolated build/dependency caches under `.weld/cache/`:

- **Package-projection and source-project modes:** `mix deps.get`, `mix deps.compile`, `mix compile --warnings-as-errors --no-compile-deps`, `mix test`, `mix docs --warnings-as-errors`, optional external smoke-app compilation, `mix hex.build` (when `verify.hex_build` is `true`), and `mix hex.publish --dry-run --yes` (when both `hex_build` and `hex_publish` are `true`).
- **Monolith mode:** per-selected-project `mix test` baseline, `mix deps.get`, `mix compile --warnings-as-errors`, `mix test` (enforcing `test_count >= baseline`), `mix docs --warnings-as-errors`, `mix hex.build` (when `hex_build` is `true`), and `mix hex.publish --dry-run --yes` (when both `hex_build` and `hex_publish` are `true`).

Set `verify: [hex_build: false]` for internal artifacts that intentionally use non-Hex Git dependencies, or `verify: [hex_publish: false]` to build a Hex tarball without running `hex.publish --dry-run`.

The standard release flow separates deterministic bundle preparation from credentialed publication:

1. Run the source workspace's own test and quality gates on a clean Git working tree.
2. Run `mix release.prepare` to verify and write `.weld/releases/<artifact>/<identity>/`.
3. Optionally run `mix release.track` to update the orphan `projection/<package_name>` branch (and optionally `--tag` / `--push`).
4. When publishing to Hex, run `mix hex.publish` from the prepared bundle's `project/` directory.
5. Run `mix release.archive` to preserve the verified bundle under `.weld/archive/<artifact>/<identity>/`.

Prepared `project/` trees and tracked Git projections retain `weld.provenance.json` and `projection.lock.json` for auditability; Hex tarballs omit `projection.lock.json`.

## Guides

- [Getting Started](guides/getting_started.md)
- [Workflow](guides/workflow.md)
- [Source-Root Artifacts](guides/source_projects.md)
- [CLI Reference](guides/cli_reference.md)
- [Manifest Reference](guides/manifest_reference.md)
- [Architecture](guides/architecture.md)
- [Testing Strategy](guides/testing_strategy.md)
- [Release Process](guides/release_process.md)
- [Consumer Repo Integration](guides/consumer_repo_integration.md)

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
