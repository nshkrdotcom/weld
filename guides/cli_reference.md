# CLI Reference

When the manifest path is omitted, Weld auto-discovers one by checking
`build_support/weld.exs`, then `build_support/weld_contract.exs`, then a single
`packaging/weld/*.exs`.

## Inspect

```bash
mix weld.inspect [manifest_path] [--artifact name] [--format json]
```

Shows manifest metadata, discovery source, project classifications, selected
closure, excluded projects, and current violations.

## Graph

```bash
mix weld.graph [manifest_path] [--artifact name] [--format json|dot]
```

Renders the workspace graph as human-readable edges, JSON, or DOT.

## Query

```bash
mix weld.query deps [manifest_path] <project_id> [--artifact name]
mix weld.query why [manifest_path] <from_project> <to_project> [--artifact name]
```

`deps` lists direct outgoing internal and external dependencies for a project.
`why` shows one explanatory path through the selected package view.

## Affected

```bash
mix weld.affected [manifest_path] --task verify.all --base main --head HEAD [--artifact name]
```

Computes affected selected projects from a Git diff range plus reverse
dependency traversal.

## Project

```bash
mix weld.project [manifest_path] [--artifact name]
```

Generates the welded artifact. Package-projection mode writes to
`dist/hex/<package>/`; monolith mode writes to `dist/monolith/<package>/`.

## Verify

```bash
mix weld.verify [manifest_path] [--artifact name]
```

Runs package-level verification against the generated artifact.

## Release Prepare

```bash
mix weld.release.prepare [manifest_path] [--artifact name]
mix release.prepare [manifest_path] [--artifact name]
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
