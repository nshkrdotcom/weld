# Architecture

`Weld` plans each artifact from the workspace Mix dependency graph and its
declared source inventory. Both live and full materialization use that
artifact selection.

## Core Stages

1. `Weld.Manifest` loads and validates a repo-local manifest.
2. `Weld.Workspace.Discovery` finds projects from manifest globs,
   `blitz_workspace`, or filesystem fallback.
3. `Weld.Workspace` loads each Mix project sequentially and normalizes
   dependencies.
4. `Weld.Graph` stores project nodes, classified edges, publication roles,
   external deps, and violations.
5. `Weld.Plan` resolves the artifact's dependency boundary, selected closure,
   source owners, layout inputs, and verification membership.
6. `Weld.Output` serializes checkout-root `.weld/` mutations, enforces `.owner`
   markers and `.gitignore` rules, rejects symlinks on managed roots, and swaps
   staged directories into place atomically.
7. `Weld.Projector` materializes the artifact with regular files or live
   source links. It writes the project's provenance, the projection lock,
   and any generated Mix, configuration, or application files.
8. `Weld.Verifier` validates the generated project using a mode-specific gate
   with per-projection, per-toolchain build/dependency caches under `.weld/cache/`.
9. `Weld.Release` prepares content-addressed release bundles under
   `.weld/releases/<artifact>/<identity>/`, tracks orphan `projection/<package_name>`
   branches, and archives released bundles under `.weld/archive/<artifact>/<identity>/`.

## Graph Model

Projects are classified independently from publication role.

Classification:

- `:runtime`
- `:tooling`
- `:proof`
- `:ignored`

Publication role:

- `:default`
- `:internal_only`
- `:separate`
- `{:optional, feature_id}`

Internal edges are classified by execution meaning:

- `:runtime`
- `:compile`
- `:test`
- `:docs`
- `:tooling`
- `:dev_only`

Views such as `:package`, `:test`, and `:docs` are computed by filtering those
edge kinds.

External dependencies are also normalized. If a selected workspace project
refers to an external package through `:path`, `:git`, or `:github`, the
manifest must declare the canonical publishable dependency shape. The graph and
plan operate on that normalized external edge, not the local transport detail.
Dependencies without a version requirement are permitted when `opts` includes
`:git` or `:github`.

### Artifact Membership and Package Boundaries

The workspace graph records actual Mix declarations. An artifact can absorb a
dependency closure, preserve a package that compiles sibling source trees, or
externalize a discoverable package with `external_projects`. Externalization
cuts traversal for that artifact and retains a separate Mix dependency.

Inspect the plan to distinguish the dependency-selected projects, owners
whose sources are compiled into the artifact, and projects present only
through inventory or verification. A root Mix file can list compiler paths
owned by private projects without starting their OTP apps. A selected
project's inventory can also carry another project's documentation without
compiling its modules. The inventory records linked files as well as
generated or copied files, and affected analysis uses ownership to attribute
Git paths even when files have moved or been removed.

Monolith planning labels its inventory targets `before_merge`. Final source
placement is recorded after materialization in `source_mappings`, `file_remaps`,
migration layout/remaps and helper transformations. Verification preserves those
records in the projection lock. Pre-materialization inspection does not expose
a complete final map for transformed files.

## Projection Modes

### Package-Projection Mode (default)

Artifacts with `mode: :package_projection` (or no `mode` key) generate a
component-preserving layout under `.weld/full/<artifact>/project/`:

```text
.weld/full/<artifact>/project/
  mix.exs
  projection.lock.json
  lib/<otp_app>/application.ex
  components/
    apps/core/
    apps/web/
    core/contracts/
  test/
```

This keeps the source graph legible inside the generated package without
turning the output into a second hand-maintained source tree.

Live views use the same component layout and link selected source
directories. Ordinary file edits, additions, and deletions within a linked
directory appear on the next compile. Generated configuration and Mix metadata
are kept in the projection and checked for staleness. With
`verify: [component_tests: true]`, the verification project also carries
declared component test roots and relative fixtures. Its Hex allowlist
covers published files.

### Monolith Mode

Artifacts with `mode: :monolith` merge all selected packages into a single flat
project under `.weld/full/<artifact>/project/`:

```text
.weld/full/<artifact>/project/
  mix.exs
  projection.lock.json
  lib/<otp_app>/application.ex
  lib/
    (merged sources from all selected packages)
  test/
    <package_slug>/
      (tests per selected package)
    support/
      <package_slug>/
        (test support per selected package)
      weld_helpers/
        <slug>_test_helper.exs
  config/
    config.exs
    dev.exs / test.exs / prod.exs
    sources/
      <slug>/config.exs  (sanitized: workspace-app config calls stripped)
    runtime_sources/
      <slug>/config.exs  (original, used at runtime bootstrap)
  priv/
    repo/migrations/          (single-repo layout)
    weld_repos/<slug>/        (multi-repo layout)
```

Key behaviors in monolith mode:

- **File merging**: conflicting source files are renamed with a `<slug>__` prefix.
  A `file_remaps` list in the projection result records all renames.
- **Config sanitization**: static config copies strip workspace-app config calls
  so they do not interfere with the merged config tree. Original files are kept
  under `runtime_sources/` for bootstrap reads at startup.
- **Migration merging**: migrations with the same timestamp prefix are
  re-stamped with a deterministic offset derived from `project_id`, `filename`,
  and sort index. A `.weld_remap.json` records any renames.
- **Test helper synthesis**: each selected package's `test_helper.exs` is parsed,
  `ExUnit.start` calls are extracted and merged, and a root `test/test_helper.exs`
  is generated that dispatches to per-package helper fragments.
- **Explicit source-only test support**: when monolith tests depend on
  non-selected workspace projects, `monolith_opts[:test_support_projects]`
  turns that source-only support set into an explicit manifest contract and the
  copied support code is staged under `test/support/weld_projects/`.
- **Monolith application module**: the generated `Application` module bootstraps
  per-package config at startup using `Config.Reader.read_imports!` before
  starting any OTP application children, and the bootstrap app allowlist is
  derived only from staged bootstrap sources.
- **Test baseline gate**: verification runs each selected package's own test suite
  first, then asserts the monolith test count is at least the baseline sum.

In the live monolith, an unchanged source file's target is a link. Edits to
linked files appear on the next compile. Adding, removing, or renaming a file
can change the merged inventory and requires refresh. The live guard also
checks inputs used for remaps, deduplication, migrations, helpers, and
generated config.

### Source-Project Mode

Artifacts with `mode: :source_project` materialize the Mix file of one
discovered project. The selected project can be the repository root or a
nested package. Its Mix file owns the OTP application, compiler paths,
dependencies, and Hex package metadata.

- **Full projection (`.weld/full/<artifact>/project/`):** Copies the explicit `source_project[:files]` inventory as regular files, validates in a fresh Elixir process that the staged `mix.exs` matches the declared `{otp_app, version}` and keeps all compiler roots inside the staged tree, and records a SHA-256 `artifact_id` in `weld.provenance.json`.
- **Live projection (`.weld/live/<artifact>/`):** Symlinks declared inventory entries (copying `mix.lock` when present) and wraps the root `Mix.Project` module so `elixirc_paths`, `erlc_paths`, `test_paths`, and `erlc_include_path` resolve directly into the source checkout while SHA-256 fingerprints guard `mix.exs`, `mix.lock`, the manifest, and `structural_inputs`.

See [Source-Project Artifacts](source_projects.md) for inventory constraints
and live refresh behavior.

## Constraints

- project probing stays sequential because `Mix.Project.in_project/4` mutates
  global Mix state
- file copying and verification are deterministic
- publish-unsafe external transports must be rewritten through manifest
  dependency declarations
- the generated artifact is normal Mix, not a custom runtime
- monolith mode rejects source files that use `Application.ensure_all_started/1`
  or `Application.app_dir/1` targeting a selected package's OTP app, as these
  assume standalone package identity that is lost in the merge
