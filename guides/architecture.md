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
6. `Weld.Projector` generates the standalone Mix project, merged application
   module when needed, and lockfile.
7. `Weld.Verifier` validates the generated project.
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

## Projection Layout

The generated artifact uses a component-preserving layout:

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

## Constraints

- project probing stays sequential because `Mix.Project.in_project/4` mutates
  global Mix state
- file copying and verification are deterministic
- publish-unsafe external transports must be rewritten through manifest
  dependency declarations
- the generated artifact is normal Mix, not a custom runtime
