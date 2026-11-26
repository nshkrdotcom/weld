# Source-Project Artifacts

Use `mode: :source_project` when an existing Mix project owns its OTP
application, dependencies, compiler paths, and Hex file allowlist. Select
`roots: ["."]` for the repository root or name a discovered nested project
such as `roots: ["extensions/color"]`.

## Direct Consumption and Projections

A source project remains independently consumable with ordinary Mix.

- **Direct Mix consumption:** Depend on the package via `path:`, `git:` or
  `github:` with `subdir:` for a nested package, or via Hex after release.
- **Maintainer isolation:** A separate maintainer project, such as
  `tools/maintainer/mix.exs`, can declare
  `{:weld, "~> 0.19.0", runtime: false}` after publication and pass the
  manifest path explicitly.
- **Projected views:** When maintainers or local/CI consumers want a symlinked development surface, an isolated portable copy, a verified release bundle, or a tracked `projection/<package_name>` branch, Weld projects those views from `build_support/weld.exs` under `.weld/`.

## Manifest Configuration

Use a `source_project` keyword list to declare the files of the selected
project. For a repository-root package with embedded components, the manifest
at `build_support/weld.exs` can use this definition:

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

Omit `mix.lock` from `files` when the source project has no lockfile. A root
that compiles `components/pure/lib` and `components/runtime/lib` reports those
components as source members. Their Mix projects remain independently
buildable. If the root declares a real path dependency, the dependency
retains its own Mix application and must be covered by the inventory.

### A Separately Released Nested Package

Suppose `extensions/color/mix.exs` defines `:sprout_color` and declares the
ordinary Hex dependency `{:sprout, "~> 0.1.0"}`. Add this entry to the same
manifest's `artifacts` list:

```elixir
sprout_color: [
  mode: :source_project,
  roots: ["extensions/color"],
  external_projects: ["."],
  source_project: [
    files: ~w(mix.exs VERSION LICENSE README.md lib test),
    structural_inputs: ["VERSION"]
  ],
  package: [name: "sprout_color", otp_app: :sprout_color, version: "0.1.0"],
  verify: [hex_build: true, hex_publish: false]
]
```

The projected root is `extensions/color`'s own project. The `files` and nested
`structural_inputs` entries are relative to that directory, while the
manifest and output paths are resolved from the workspace. The portable
project includes its own version file and resolves `:sprout` as a package.
To try unreleased source together, set an explicit base `path:` with
`override: true` in the outer consumer. Verify the release package using its
normal versioned dependency.

### Inventory Rules (`source_project`)

- `files` *(required)*: Literal paths relative to the selected project.
  Cover `mix.exs`, `mix.lock` when present, existing compiler and test paths,
  and existing `priv`, `config`, and `include` directories. Include project
  helpers and metadata used during compilation, test, and docs.
- **Disjoint, clean regular trees:** Listed paths must exist, contain only regular files and directories (no symlinks), have no duplicates or parent/child overlaps, and exclude `.git`, `.weld`, `deps`, `_build`, `doc`, `weld.provenance.json`, `projection.lock.json`, and `.mix_sources.json`.
- **Portable path dependencies:** Declared relative path dependencies must
  remain inside the selected project directory. Include their Mix
  definitions and transitive source in the inventory. A nested standalone
  package should declare dependencies outside its directory as separately
  distributed packages.
- **Static unique module names:** Weld parses `.ex` files across the selected
  project's compiler roots and rejects dynamic module names and duplicate
  definitions.
- **Package allowlist ownership:** The selected `mix.exs` owns Hex
  `package.files`. The full verification project can include tests and
  support helpers beyond the published allowlist. Native directory and glob
  matches must be completely represented in the source inventory. An allowlist
  that also selects Weld's generated provenance or lock report is rejected.
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
- Generates a `mix.exs` wrapper that preserves the selected project module
  and callbacks. Compiler and test paths resolve into the selected source
  project, and project-local configuration remains available.
- **Immediate code visibility:** Editing, adding, or deleting source files or `priv/` assets under existing directories is immediately visible on a path consumer's next `mix compile` without re-running Weld.
- **Structural refresh:** At project evaluation, the live view checks
  required directories, project metadata, lockfile presence and digest,
  and declared structural inputs. If one changes, run the refresh command
  printed by Mix.
- **Hex packaging:** Live views require filesystem symlink support. Use a
  full candidate for `mix hex.build` or `mix hex.publish`, including dry runs.
- **Mutable destinations:** Build, dependency, lock and ExDoc output paths must
  stay in the generated project. They cannot overlap a linked source path in
  either direction. Keep generated `doc` output outside the source inventory.

### Full Projection (`.weld/full/<artifact>/project/`)

`mix weld.project` (without `--live`) copies the declared inventory as regular files into `.weld/full/<artifact>/project/`:

- Contains no symlinks and can be copied or moved outside the source checkout.
- Records `weld.provenance.json` with `schema: "weld.projection/v1"`, `kind: "full"`, and a content-addressed SHA-256 `artifact_id` computed over the staged project files prior to writing provenance and `projection.lock.json`.
- After successful verification, atomically updates that ID from the exact
  portable inventory and resolved standalone `mix.lock`. Build caches,
  generated docs, the Hex tarball and provenance reports are outside this ID.
- Downstream source-selection helpers can inspect `weld.provenance.json` to key isolated Mix build/lock contexts by `artifact_id` when consuming refreshable full candidates.

## `.weld/` Ownership, Locking, And Release Identities

All Weld mutations resolve to `<checkout_root>/.weld/` (including when invoked from nested subprojects or Git worktrees):

- **Ignore rule safety:** Explicit Weld mutations (`weld.setup`, `weld.project`, `weld.verify`, `release.*`) normalize `.weld/` in the checkout-root `.gitignore`, verify with `git check-ignore` that `.weld/` subtrees are ignored, and fail closed if `.weld` has tracked files in the Git index or conflicting `!` negation rules in `.gitignore`. Commit any `.gitignore` update before running `mix release.prepare`, which requires a clean committed Git tree.
- **Checkout-wide writer serialization:** Weld acquires `.weld/.lock` (recording `pid` and `node` in `.weld/.lock/owner`) and verifies `.weld/.owner` (`weld-output/v1`) before mutating output. Staging builds in `.weld/staging/<nonce>` and swaps into place atomically, rolling back if activation fails. If a writer process is killed abruptly (`SIGKILL`), verify that the PID in `.weld/.lock/owner` has exited and inspect `.weld/staging/` before removing `.weld/.lock`.
- **Consumer concurrency:** Ordinary Mix consumers reading `.weld/live/<artifact>` or `.weld/full/<artifact>/project` do not acquire `.weld/.lock`. Quiesce active path consumers before regenerating refreshable views, or point consumers at an immutable prepared release path (`.weld/releases/<artifact>/<identity>/project`).
- **Prepared release identities:** `mix release.prepare --artifact sprout` verifies the full candidate from a committed clean Git revision and writes `.weld/releases/sprout/<identity>/`, then atomically updates `.weld/releases/sprout/CURRENT`. Re-preparing identical inputs reuses the verified bundle; changing source revision, manifest, lockfile, verified output, or Elixir/OTP toolchain produces a distinct `<identity>`. `mix release.track` syncs the prepared `project/` onto `projection/<package_name>` (creating no commit when unchanged), and `mix release.archive` copies the verified bundle to `.weld/archive/<artifact>/<identity>/`.
- **Legacy paths:** Historical `dist/`, `tmp/weld_smoke/`, and `_build/weld/` directories are never deleted automatically. `output.dist_root` remains accepted in manifests with a deprecation warning, while all generated output writes to `.weld/`.
