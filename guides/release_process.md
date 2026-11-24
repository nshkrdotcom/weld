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

This command:

- generates the welded artifact
- runs welded package verification
- writes a deterministic release bundle
- includes a tarball when `verify.hex_build` is enabled

If the manifest sets `verify: [hex_build: false]`, release preparation still
writes the prepared bundle. The only thing omitted is the tarball, because the
artifact is intentionally not Hex-buildable.

Prepare Git releases from a clean committed tree. For a flattened project, set
`package.docs.source_ref` to an immutable tag on its tracked projection. That
tag contains the paths referenced by ExDoc's source links.

## Track

```bash
mix release.track
```

This command:

- reads the prepared release bundle
- updates `projection/<package_name>` by default
- creates the first projection branch as an orphan by default
- optionally tags and pushes that projection commit

Tracking is for durable projected-source history, including unreleased and
pre-release snapshots. It is not a substitute for Hex publication and it does
not imply that a tracked projection commit was released.

## Publish

Run `mix hex.publish` from the prepared bundle's `project/` directory after
inspection. Across all projection modes, `weld.verify` exercises
`mix hex.publish --dry-run --yes` whenever both `verify.hex_build` and
`verify.hex_publish` are enabled.

Publish is the only release step that requires a tarball.

## Archive

```bash
mix release.archive
```

These wrappers delegate to the Weld release tasks and use the same manifest
auto-discovery rules. Pass an explicit manifest path only when the repo carries
more than one Weld manifest or uses a nonstandard manifest location.

This copies the prepared release bundle into the archive surface.

## Release Bundle Contents

The prepared bundle contains:

- projected Mix project tree in `project/`
- browser preview at `docs/index.html` beside the project, with generated Markdown when available
- `project/weld.provenance.json` and `project/projection.lock.json` for auditing
  the projection. Both are retained in the prepared project and tracked Git
  projection; Hex tarballs omit `projection.lock.json`.
- built tarball when `verify.hex_build` is enabled
- `release.json` metadata

Weld verifies the configured ExDoc formats. The prepared browser preview omits
EPUB output because ExDoc embeds a random identifier and build timestamps.

`release.json` records the manifest path relative to the repo root and the
Weld version used to prepare the bundle, which keeps release metadata portable
across checkout locations.

When preparation runs from a Git revision, `release.json` also contains the
small `mix_workspace_ops.prepared_artifact/v2` handoff: source revision,
package/version, relative manifest, project and archive paths, and their SHA-256 digests.
Weld does not depend on or invoke Mix Workspace Ops. This data-only boundary
is consumed by Mix Workspace Ops' clean-checkout release transaction without
teaching MWO to parse a Weld manifest: the transaction invokes Weld's declared
prepare command in the pinned source checkout, compares the rebuilt handoff and
its files with the expected handoff, and only then admits the archive to the
publication step. Weld never receives or manages publication credentials.

Tracked projection commits are intentionally separate from the prepared bundle.
The bundle is the release input; the projection branch is an optional durable
generated-source history.

## Archive Policy

The archive output is meant to preserve exactly what was released.

It is not intended to be an active generated development branch. The source
monorepo remains the source of truth, and `projection/<package_name>` is the
optional generated-source tracking surface when you need one.

## Prepared Identities And Storage

Preparation stages and verifies the bundle before activating `.weld/releases/<artifact>/<identity>/` and updating `.weld/releases/<artifact>/CURRENT`. Its SHA-256 `<identity>` covers release metadata, source revision (when in Git; required for `:source_project`), manifest digest, verified `project/`, `docs/`, and archive checksums, resolved `mix.lock` digest, Elixir/OTP toolchain, and verification outcomes. The recorded `prepared_at` timestamp is informational and excluded from `<identity>`. Repeating preparation with unchanged inputs reuses the verified bundle. Tracking reads the integrity-checked `CURRENT` bundle and creates no commit when the projected tree is unchanged. Archives live at `.weld/archive/<artifact>/<identity>/`. See [Source-Root Artifacts](source_projects.md) for `.weld/` lock ownership and migration details.

For Weld itself, the checked-in `build_support/weld.exs` selects the root `:weld` project. Resolve and commit the reviewed lock, run `mix ci` on the supported Elixir toolchains, then prepare, archive and optionally track from the clean release revision.

```bash
mix weld.release.prepare --artifact weld
mix weld.release.archive --artifact weld
mix weld.release.track --artifact weld
```

Preparation exercises the Hex publish dry run. A real tag, push or package publication is a separate maintainer action.
