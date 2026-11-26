# Release Process

`Weld` separates release preparation, projection tracking, and archiving from
Hex publication.

## Why

`weld` should govern exactly what is being published, but it should not own Hex
credentials or network-side retry semantics.

## Prepare

```bash
mix release.prepare
```

This command generates and verifies a full projection, then writes the
prepared release bundle. Select an artifact explicitly when a manifest
defines several, for example
`mix release.prepare build_support/weld.exs --artifact console_bundle`.
Preparation includes a tarball when `verify.hex_build` is enabled.

If the manifest sets `verify: [hex_build: false]`, release preparation still
writes the prepared bundle. The only thing omitted is the tarball, because the
artifact is intentionally not Hex-buildable.

Prepare Git releases from a clean committed tree. For a flattened project, set
`package.docs.source_ref` to an immutable tag on its tracked projection. That
tag contains the paths referenced by ExDoc's source links.

A repeat preparation can reuse a verified bundle for a locked source
project that has opted out of Hex publishing checks. Pass
`mix release.prepare --reuse local-toolchain-v1` from a clean checkout. Use a
non-secret identifier that represents any inputs your verification reads
outside the checkout, such as native compiler flags or service fixtures.
Change the identifier when those inputs change. Use `--no-cache` for an
independent rebuild. Weld checks the current source, signed registry
configuration, implementation, toolchain and resolved lock before reuse.
It also checks the project, docs and archive bytes. A corrupt current bundle
fails integrity validation.

HTML previews keep their code highlighting and use stable delimiter group
IDs. Rebuilding without the cache still generates the documentation
independently. The EPUB remains outside the prepared docs preview.

Verification passes `--output doc` to ExDoc so the prepared preview comes from
one canonical location even when a source project's native docs configuration
uses another directory. The preview must pass Weld's static Mermaid smoke
checks before it enters the bundle and again before the publication handoff.

## Track

```bash
mix release.track --tag-release --push
```

Create and push an annotated `v<version>` tag on the qualified source commit on
`main`. Keep the separate package release tag on the projection commit so it
continues to identify the Weld receipt and the packaged source shown by ExDoc.


This command:

- reads the verified `CURRENT` (or `--identity <sha>`) release bundle
- updates `projection/<package_name>` by default with `weld.receipt/v1` trailers
  (`Weld-Identity`, `Weld-Project-SHA256`, `Weld-Docs-SHA256`,
  `Weld-Archive-SHA256`, `Weld-Source-Revision`, `Weld-Tool-Version`)
- creates an `--allow-empty` receipt commit if the bundle identity changed on an
  unchanged projection tree, or reuses the branch tip on an exact retry
- creates an **annotated** tag (`--tag <tag>` or `--tag-release` for
  `<package>-v<version>`) carrying the same receipt, rejecting conflicting or
  legacy lightweight tags before moving refs

Verify any tag receipt against its target commit and local bundle/tarball with
`mix release.verify_tag <tag>`. A pre-publish tag records the verified prepared
bundle; Hex publication is a separate outcome.

## Status

```bash
mix release.status [--artifact <name> | --all] [--format json]
```

Run `mix release.status` from a fresh checkout to see every Weld artifact.
Each entry connects the checked-in manifest and source roots to the package,
default projection branch and release tag, and expected paths under `.weld/`.
Once prepared, it reports the bundle identity, freshness, archive SHA-256,
publish workspace and archive state. Use `--format json` to read these fields
from scripts, then pass the artifact and full identity to release tasks.

Keep the artifact inventory in the checked-in manifest. Link to it from the
repository README or agent instructions so maintainers can find it without
first generating `.weld/`. The local directories are grouped by artifact ID
and immutable bundle identity. A verified Git tag identifies the same artifact
and identity even after local outputs are gone.

## Publish

Recommended interactive handoff:

```bash
mix release.publish [--artifact <name>] [--identity <sha>] [--tag <tag>] [--dry-run]
```

Weld pins the verified bundle identity, verifies freshness (pass `--allow-stale`
only for `head_moved` / `dirty_worktree`), checks `--tag` receipt agreement when
given, stages an isolated per-run workspace under `.weld/publish/`, releases
`.weld/.lock`, runs `mix deps.get --check-locked` and a local `mix hex.build` to
confirm the rebuilt tarball matches the prepared `archive_sha256`, and hands
stdio to Hex for prompts and credentials. Declining confirmation stops the
handoff. Pass `--dry-run` to run the same local checks and Hex's publication
dry run without uploading. When Hex stages a release for approval, wait for
Hex to confirm publication before archiving.

An `ACTIVE` marker protects the per-run workspace while dependency retrieval,
archive rebuilding, and the interactive handoff are running. `mix weld.gc`
retains marked runs. Normal completion and failures clear the marker; after a
process crash, confirm the publisher has stopped before removing a stale marker.
Publication subprocesses clear inherited Mix project, lockfile, target, build,
and dependency path overrides so they operate on the staged project.

For manual staging, run `mix release.stage [--fresh] [--identity <sha>]` (use
`--path-only` for scripts). `--fresh` atomically replaces a dirty publish
workspace. Prepare, track, and publish print the next command with the selected
manifest, artifact, and full identity. Tagged tracking pushes the branch and
tag together in one atomic Git transaction.

**Recovery:** If `release.track --push` succeeded and `mix hex.publish` fails or
is cancelled, fix the issue and retry `mix release.publish --identity <sha>`
(or prepare a new version if source changed). If Hex accepted the upload and
archiving failed, run `mix release.archive --identity <sha>` directly against
the intact `.weld/releases/<artifact>/<sha>/` bundle.

## Archive

```bash
mix release.archive [--artifact <name> | --all] [--identity <sha>]
```

These wrappers delegate to the Weld release tasks and use the same manifest
auto-discovery rules. Pass an explicit manifest path only when the repo carries
more than one Weld manifest or uses a nonstandard manifest location.

This copies the prepared release bundle into the archive surface.

## Release Bundle Contents

The prepared bundle contains:

- portable projected Mix project tree in `project/`, including the files
  needed for configured verification
- browser preview at `docs/index.html` beside the project, with generated Markdown when available
- `project/weld.provenance.json` and `project/projection.lock.json` for auditing
  the projection. Both are retained in the prepared project and tracked Git
  projection; Hex tarballs omit both generated reports.
- built tarball when `verify.hex_build` is enabled
- `release.json` metadata

Weld verifies the configured ExDoc formats. The prepared browser preview omits
EPUB output because ExDoc embeds a random identifier and build timestamps.

`release.json` records the manifest path relative to the repo root and the
Weld version used to prepare the bundle, which keeps release metadata portable
across checkout locations.

When preparation runs from a Git revision, `release.json` also contains the
`mix_workspace_ops.prepared_artifact/v2` data handoff. It records the source
revision, package and version, relative manifest, project and archive paths,
and their SHA-256 digests. Mix Workspace Ops can independently compare a
rebuild from the pinned checkout against that metadata before publication.

Tracked projection commits are intentionally separate from the prepared bundle.
The bundle is the release input; the projection branch is an optional durable
generated-source history.

## Archive Policy

The archive output is meant to preserve exactly what was released.

It is not intended to be an active generated development branch. The source
monorepo remains the source of truth, and `projection/<package_name>` is the
optional generated-source tracking surface when you need one.

## Prepared Identities And Storage

Preparation stages and verifies the bundle before activating `.weld/releases/<artifact>/<identity>/` and updating `.weld/releases/<artifact>/CURRENT`. Its SHA-256 `<identity>` covers release metadata, source revision (required in source-project mode), manifest digest, verified `project/`, `docs/`, and archive checksums, the resolved `mix.lock`, Elixir/OTP toolchain, and verification outcomes. The `prepared_at` timestamp is informational. Repeating preparation with unchanged inputs reuses the verified bundle. Tracking reads the integrity-checked `CURRENT` bundle and creates a commit when the projected tree changes. Archives live at `.weld/archive/<artifact>/<identity>/`. See [Source-Project Artifacts](source_projects.md) for `.weld/` lock ownership and migration details.

The full projection's `artifact_id` initially identifies the materialized
inputs. Successful verification atomically finalizes it over the portable
inventory and resolved standalone lock; the prepared project carries the same
ID. The surrounding prepared bundle identity also binds verification results,
docs and tarball bytes. A Hex tarball follows the project's `package.files`
allowlist, so its inventory can be smaller than the prepared project.

Verification rejects modifications to inventoried source or test files and
additions beneath published paths. Only the standalone root `mix.lock` may be
resolved during verification. Component baseline tests run in a regular-file
workspace mirror under `.weld/staging`, so fetching their test dependencies
does not create or update source component locks. Preparation rechecks copied
input bytes and executable flags before finalizing the bundle.

For Weld itself, the checked-in `build_support/weld.exs` selects the root `:weld` project. Resolve and commit the reviewed lock, run `mix ci` on the supported Elixir toolchains, then prepare, archive and optionally track from the clean release revision.

```bash
mix release.prepare build_support/weld.exs --artifact weld
mix release.archive build_support/weld.exs --artifact weld
mix release.track build_support/weld.exs --artifact weld
```

Weld's root Mix project also builds the public Weld package directly.
To release Weld itself, publish with `mix hex.publish` from the source
checkout after validating the committed release version.
