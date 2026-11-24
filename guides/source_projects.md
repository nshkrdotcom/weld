# Source-Root Artifacts

Use `mode: :source_project` when the repository root is already an authoritative Mix project (`roots: ["."]`) that owns its OTP application, dependencies, compiler inputs, and Hex `package.files`, while keeping internal components, extensions, or maintainer tooling in subprojects.

## Direct Consumption Versus Projections

A source-root repository works as a normal Mix project out of the box:

- **Direct Mix consumption:** Downstream projects can depend directly on the repository root via `path:`, `git:` / `github:`, or Hex. Ordinary `mix deps.get`, `mix compile`, and `mix test` runs use standard Mix state and require no Weld installation or `.weld/` directory.
- **Maintainer isolation:** Weld does not need to be added to the public root `mix.exs`. Maintainers can declare `{:weld, "~> 0.15.0", runtime: false}` in a separate non-published project (such as `tools/maintainer/mix.exs`) and pass the manifest path explicitly, keeping the root `mix.exs` and `mix.lock` completely free of maintainer packaging dependencies.
- **Projected views:** When maintainers or local/CI consumers want a symlinked development surface, an isolated portable copy, a verified release bundle, or a tracked `projection/<package_name>` branch, Weld projects those views from `build_support/weld.exs` under `.weld/`.

## Manifest Configuration

Define the artifact with `mode: :source_project`, `roots: ["."]`, and a `source_project` keyword list:

```elixir
[
  workspace: [
    root: "..",
    project_globs: ["components/*", "extensions/*", "tools/*"]
  ],
  artifacts: [
    sprout: [
      mode: :source_project,
      roots: ["."],
      source_project: [
        files: ~w(
          mix.exs mix.lock VERSION LICENSE README.md .formatter.exs
          components/pure/lib components/pure/test
          components/runtime/lib components/runtime/test
          priv test
        ),
        structural_inputs: ~w(mix.exs VERSION components/pure/mix.exs components/runtime/mix.exs)
      ],
      package: [
        name: "sprout",
        otp_app: :sprout,
        version: "0.1.0",
        elixir: "~> 1.18",
        description: "Sprout"
      ],
      verify: [hex_build: true, hex_publish: false]
    ]
  ]
]
```

### Inventory Rules (`source_project`)

- `files` *(required)*: Literal relative paths from the repository root. It must cover `mix.exs`, `mix.lock` (when present at the root), every existing path in the root project's `elixirc_paths`, `erlc_paths`, and `test_paths`, plus `priv`, `config`, and `include` when those directories exist at the root. Include any helper files (`VERSION`, `.formatter.exs`, guides, assets) read during compilation, testing, or documentation generation.
- **Disjoint, clean regular trees:** Listed paths must exist, contain only regular files and directories (no symlinks), have no duplicates or parent/child overlaps, and exclude `.git`, `.weld`, `deps`, `_build`, `weld.provenance.json`, `projection.lock.json`, and `.mix_sources.json`.
- **Portable path dependencies:** If the root `mix.exs` declares relative `path:` dependencies, those subprojects must live inside the repository root and have their `mix.exs` covered by `files`.
- **Static unique module names:** Weld parses `.ex` files across the root project's `elixirc_paths` and rejects dynamic `defmodule` names or duplicate module definitions across component source roots.
- **Package allowlist ownership:** The root `mix.exs` retains ownership of Hex `package.files`. A full verification candidate may include maintainer test suites or scripts in `source_project[:files]` while `mix.exs` keeps proof-only suites and independent extensions outside the published Hex tarball.
- `structural_inputs` *(optional, defaults to `[]`)*: Additional files (such as `VERSION` or component `mix.exs` files) hashed alongside `mix.exs`, `mix.lock`, and the Weld manifest to detect structural staleness in live projections.

## Generating Live And Full Projections

Initialize `.weld/` and normalize `.gitignore`, then generate live or full views:

```bash
mix weld.setup
git diff -- .gitignore
mix weld.project --artifact sprout --live
mix weld.project --artifact sprout
mix weld.verify --artifact sprout
```

*(When invoking from a separate maintainer directory such as `tools/maintainer`, pass the manifest path: `mix weld.project ../../build_support/weld.exs --artifact sprout --live`.)*

### Live View (`.weld/live/<artifact>/`)

`mix weld.project --live` creates a lightweight development view for local path consumers:

- Copies `mix.lock` (when present), symlinks all other declared `files` entries back to the source checkout, and writes `weld.provenance.json` (`kind: "live"`) plus `projection.lock.json`.
- Generates a `mix.exs` wrapper that preserves the root project module (`application/0`, docs callbacks, lexical helpers, and `__DIR__` anchored to the source root) while overriding `project/0` so `elixirc_paths`, `erlc_paths`, `test_paths`, and `erlc_include_path` expand directly into the source checkout.
- **Immediate code visibility:** Editing, adding, or deleting source files or `priv/` assets under existing directories is immediately visible on a path consumer's next `mix compile` without re-running Weld.
- **Fail-fast structural staleness:** Every Mix evaluation of the live project verifies that required directories still exist and checks SHA-256 digests of `mix.exs`, `mix.lock`, the Weld manifest, and `structural_inputs`. When any structural input changes, Mix raises with the exact refresh command (`mix weld.project --artifact <name> --live`).
- **Non-packagable by design:** Live projections require filesystem symlink support and override `mix hex.build` and `mix hex.publish` to raise an error directing callers to generate a full candidate instead.

### Full Projection (`.weld/full/<artifact>/project/`)

`mix weld.project` (without `--live`) copies the declared inventory as regular files into `.weld/full/<artifact>/project/`:

- Contains no symlinks and can be copied or moved outside the source checkout.
- Records `weld.provenance.json` with `schema: "weld.projection/v1"`, `kind: "full"`, and a content-addressed SHA-256 `artifact_id` computed over the staged project files prior to writing provenance and `projection.lock.json`.
- Downstream source-selection helpers can inspect `weld.provenance.json` to key isolated Mix build/lock contexts by `artifact_id` when consuming refreshable full candidates.

## `.weld/` Ownership, Locking, And Release Identities

All Weld mutations resolve to `<checkout_root>/.weld/` (including when invoked from nested subprojects or Git worktrees):

- **Ignore rule safety:** Explicit Weld mutations (`weld.setup`, `weld.project`, `weld.verify`, `release.*`) normalize `.weld/` in the checkout-root `.gitignore`, verify with `git check-ignore` that `.weld/` subtrees are ignored, and fail closed if `.weld` has tracked files in the Git index or conflicting `!` negation rules in `.gitignore`. Commit any `.gitignore` update before running `mix release.prepare`, which requires a clean committed Git tree.
- **Checkout-wide writer serialization:** Weld acquires `.weld/.lock` (recording `pid` and `node` in `.weld/.lock/owner`) and verifies `.weld/.owner` (`weld-output/v1`) before mutating output. Staging builds in `.weld/staging/<nonce>` and swaps into place atomically, rolling back if activation fails. If a writer process is killed abruptly (`SIGKILL`), verify that the PID in `.weld/.lock/owner` has exited and inspect `.weld/staging/` before removing `.weld/.lock`.
- **Consumer concurrency:** Ordinary Mix consumers reading `.weld/live/<artifact>` or `.weld/full/<artifact>/project` do not acquire `.weld/.lock`. Quiesce active path consumers before regenerating refreshable views, or point consumers at an immutable prepared release path (`.weld/releases/<artifact>/<identity>/project`).
- **Prepared release identities:** `mix release.prepare --artifact sprout` verifies the full candidate from a committed clean Git revision and writes `.weld/releases/sprout/<identity>/`, then atomically updates `.weld/releases/sprout/CURRENT`. Re-preparing identical inputs reuses the verified bundle; changing source revision, manifest, lockfile, verified output, or Elixir/OTP toolchain produces a distinct `<identity>`. `mix release.track` syncs the prepared `project/` onto `projection/<package_name>` (creating no commit when unchanged), and `mix release.archive` copies the verified bundle to `.weld/archive/<artifact>/<identity>/`.
- **Legacy paths:** Historical `dist/`, `tmp/weld_smoke/`, and `_build/weld/` directories are never deleted automatically. `output.dist_root` remains accepted in manifests with a deprecation warning, while all generated output writes to `.weld/`.
