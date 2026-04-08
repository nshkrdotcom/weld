# Architecture

`Weld` is graph-first. Generated files are an output of the graph and plan, not
the primary internal model.

## Core Stages

1. `Weld.Manifest` loads and validates a repo-local manifest.
2. `Weld.Workspace.Discovery` finds projects from manifest globs,
   `blitz_workspace`, or filesystem fallback.
3. `Weld.Workspace` loads each Mix project sequentially and normalizes
   dependencies.
4. `Weld.Graph` stores project nodes, classified edges, publication roles,
   external deps, and violations.
5. `Weld.Plan` resolves one artifact boundary and computes the selected closure.
6. `Weld.Projector` generates the standalone Mix project (routing to
   Weld.Projector.Monolith for monolith artifacts), merged application module
   when needed, and lockfile.
7. `Weld.Verifier` validates the generated project using a mode-specific gate.
8. `Weld.Release` prepares and archives deterministic release bundles.

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

## Projection Modes

### Package-Projection Mode (default)

Artifacts with `mode: :package_projection` (or no `mode` key) generate a
component-preserving layout under `dist/hex/<package>/`:

```text
dist/hex/<package>/
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

### Monolith Mode

Artifacts with `mode: :monolith` merge all selected packages into a single flat
project under `dist/monolith/<package>/`:

```text
dist/monolith/<package>/
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
- **Monolith application module**: the generated `Application` module bootstraps
  per-package config at startup using `Config.Reader.read_imports!` before
  starting any OTP application children.
- **Test baseline gate**: verification runs each selected package's own test suite
  first, then asserts the monolith test count is at least the baseline sum.

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
