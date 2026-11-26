# CLI Reference

When the manifest path is omitted, Weld auto-discovers one by checking
`build_support/weld.exs`, then `build_support/weld_contract.exs`, then a single
`packaging/weld/*.exs`.

## Explain

```bash
mix weld.explain [--format json]
```

Prints each projection kind (live, full, release, publish, tracked), its
location, purpose, and the task that creates it. It needs no manifest and reads
no project state.

## Status, Doctor, Diff, Open, Gc

```bash
mix weld.status [manifest_path] [--artifact name | --all] [--format json]
mix weld.doctor [--format json]
mix weld.diff [manifest_path] [--artifact name] [--kind full|live] [--format json]
mix weld.open [manifest_path] [--artifact name]
mix weld.gc [repo_root] [--keep N] [--dry-run] [--format json]
```

- `weld.status` is `weld.release.status` plus a `next_command` for each artifact.
- `weld.doctor` reports Elixir/OTP versions and whether `git`, `mix`, `node` and Hex are available.
- `weld.diff` compares the checkout with a projection: whether `mix.exs` differs, modified files and projection-only files. It does not parse docs options.
- `weld.open` prints the projected `doc/index.html` path; it does not launch a browser.
- `weld.gc` deletes all but the newest `--keep` (default 2) `.weld/publish/*/*/run-*` directories by modification time.

## Docs check

```bash
mix weld.docs.check [docs_dir] [--browser --playwright /path/to/node_modules] [--format json]
```

Static check: `index.html` exists and every page with a Mermaid block loads
`mermaid.min.js` and listens on `exdoc:loaded`. With `--browser` (needs `node`
and a Playwright install, via `--playwright` or `WELD_PLAYWRIGHT`) each Mermaid
page is rendered in headless Chromium in light and dark mode and reached by an
in-site link; any page error or missing SVG fails the check. `weld.release.publish`
does not run this check yet.

## Release plan

```bash
mix weld.release.plan [manifest_path] [--no-check] [--format json]
```

Lists artifacts with depended-on packages first. For each artifact whose root
`mix.exs` declares `{:other_package, "requirement"` on another artifact's
package, it checks the requirement against that artifact's version and fails if
unsatisfied. It reads `mix.exs` text with a regex and does not bump or publish.

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
mix weld.release.prepare [manifest_path] [--artifact name | --all] [--reuse context] [--no-cache]
mix release.prepare [manifest_path] [--artifact name | --all] [--reuse context] [--no-cache]
```

Generates, verifies, and bundles one or all welded artifacts. The prepared
bundle always contains the projected project tree and metadata, and it also
contains the tarball when `verify.hex_build` is enabled.

With `--all`, Weld attempts each artifact, prints per-artifact results, and
exits with an error if any artifact failed. Successful bundles remain available.

## Release Status

```bash
mix weld.release.status [manifest_path] [--artifact name | --all] [--identity sha] [--format json]
mix release.status [manifest_path] [--artifact name | --all] [--identity sha] [--format json]
```

Lists every manifest artifact in artifact ID order by default. JSON returns an
array for the inventory and an object with `--artifact`. Each entry includes
the artifact's mode, source roots, manifest path, local projection and release
paths, default tag, bundle identity, integrity and freshness state, and local
projection branch tree and receipt alignment. Paths identify the expected locations
even when their outputs have yet to be generated.

## Release Track

```bash
mix weld.release.track [manifest_path] [--artifact name] [--identity sha] [--branch name] [--remote origin] [--tag tag | --tag-release] [--push]
mix release.track [manifest_path] [--artifact name] [--identity sha] [--branch name] [--remote origin] [--tag tag | --tag-release] [--push]
```

Tracks the prepared bundle on a projection branch with `weld.receipt/v1`
trailers and optional annotated release tags (`--tag-release` defaults to
`<package>-v<version>`).

## Release Verify Tag

```bash
mix weld.release.verify_tag <tag> [manifest_path] [--artifact name] [--identity sha] [--tarball path] [--format json]
mix release.verify_tag <tag> [manifest_path] [--artifact name] [--identity sha] [--tarball path] [--format json]
```

Verifies an annotated release tag's `weld.receipt/v1` trailers against its
target commit and optional local bundle or tarball. The receipt selects the
artifact and identity. Weld checks the prepared bundle first, then the archived
copy if the prepared bundle is absent. Explicit `--artifact` and `--identity`
act as assertions.

## Release Stage

```bash
mix weld.release.stage [manifest_path] [--artifact name] [--identity sha] [--fresh] [--path-only]
mix release.stage [manifest_path] [--artifact name] [--identity sha] [--fresh] [--path-only]
```

Validates the current or pinned bundle and stages a writable Hex workspace
under `.weld/publish/<artifact>/<identity>/project/`. Pass `--fresh` to
atomically reset a workspace that already contains Mix build or docs output.
Pass `--path-only` for scriptable path-only output.

## Release Publish

```bash
mix weld.release.publish [manifest_path] [--artifact name] [--identity sha] [--tag tag] [--allow-stale] [--dry-run]
mix release.publish [manifest_path] [--artifact name] [--identity sha] [--tag tag] [--allow-stale] [--dry-run]
```

Pins a verified bundle identity, stages an isolated per-invocation workspace,
verifies a local `mix hex.build` matches the prepared tarball SHA-256, and
hands off interactively to `mix hex.publish`.

## Release Archive

```bash
mix weld.release.archive [manifest_path] [--artifact name | --all] [--identity sha]
mix release.archive [manifest_path] [--artifact name | --all] [--identity sha]
```

Copies the prepared bundle into the archive surface after publish succeeds.
Internal-only artifacts can archive bundles even when the bundle does not
contain a tarball.
