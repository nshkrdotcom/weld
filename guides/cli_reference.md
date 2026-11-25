# CLI Reference

When the manifest path is omitted, Weld auto-discovers one by checking
`build_support/weld.exs`, then `build_support/weld_contract.exs`, then a single
`packaging/weld/*.exs`.

## Inspect

```bash
mix weld.inspect [manifest_path] [--artifact name] [--format json]
```

Shows manifest metadata, discovery source, project classifications, effective
selection, excluded projects, and violations. Use JSON to inspect dependency
closure, compiled source ownership, inventory and verification membership,
and external package boundaries.

## Graph

```bash
mix weld.graph [manifest_path] [--artifact name] [--format json|dot]
```

Renders actual workspace dependency relationships as human-readable edges,
JSON, or DOT. The JSON output identifies edges externalized by the selected
artifact.

## Query

```bash
mix weld.query deps [manifest_path] <project_id> [--artifact name]
mix weld.query why [manifest_path] <from_project> <to_project> [--artifact name]
```

`deps` lists direct outgoing dependencies and indicates artifact-local
externalization. `why` shows an explanatory path through the selected
artifact's package view.

## Affected

```bash
mix weld.affected [manifest_path] --task verify.all --base main --head HEAD [--artifact name]
```

Computes affected projects using Git paths, artifact source ownership, and
dependency relationships. A file copied or linked into an artifact can
affect that artifact even when the owning project is absent from its Mix
dependency closure.

## Setup

```bash
mix weld.setup [manifest_path]
```

Initializes `<checkout_root>/.weld/`, writes its ownership marker, verifies `.weld` has no tracked Git files or conflicting `.gitignore` negations, and normalizes `.weld/` in the checkout-root `.gitignore`. Commit any `.gitignore` change before preparing clean-tree releases.

## Project

```bash
mix weld.project [manifest_path] [--artifact name] [--live] [--no-cache]
```

Generates a standalone full candidate under `.weld/full/<artifact>/project/`.
Pass `--live` to generate the same artifact as a source-linked development
view under `.weld/live/<artifact>/`. Both kinds record provenance and inventory
in `weld.provenance.json` and `projection.lock.json`. Live views use standard
Mix and report a refresh command if structural inputs change. Use a full
candidate for Hex packaging.

## Verify

```bash
mix weld.verify [manifest_path] [--artifact name]
```

Regenerates `.weld/full/<artifact>/project/` and runs the mode-specific Mix verification gate using isolated dependency and build caches under `.weld/cache/`.

## Agents Verify

```bash
mix weld.agents.verify [--repo-root path] [-r path] [--format json]
```

Verifies root and nested `AGENTS.md` files for runtime-environment guidance.

## Release Prepare

```bash
mix weld.release.prepare [manifest_path] [--artifact name] [--reuse context] [--no-cache]
mix release.prepare [manifest_path] [--artifact name] [--reuse context] [--no-cache]
```

Generates, verifies, and bundles the welded artifact. The prepared bundle always
contains the projected project tree and metadata, and it also contains the
tarball when `verify.hex_build` is enabled.

## Release Track

```bash
mix weld.release.track [manifest_path] [--artifact name] [--branch name] [--remote origin] [--tag tag] [--push]
mix release.track [manifest_path] [--artifact name] [--branch name] [--remote origin] [--tag tag] [--push]
```

Tracks the prepared bundle on a projection branch. Defaults to
`projection/<package_name>` and creates the first branch as an orphan by
default.

## Release Archive

```bash
mix weld.release.archive [manifest_path] [--artifact name]
mix release.archive [manifest_path] [--artifact name]
```

Copies the prepared bundle into the archive surface after publish succeeds.
Internal-only artifacts can archive bundles even when the bundle does not
contain a tarball.
