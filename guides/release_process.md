# Release Process

`Weld` separates release preparation, projection tracking, and archiving from
Hex publication.

## Why

`weld` should govern exactly what is being published, but it should not own Hex
credentials or network-side retry semantics.

## Prepare

```bash
mix weld.release.prepare packaging/weld/my_bundle.exs
```

This command:

- generates the welded artifact
- runs welded package verification
- writes a deterministic release bundle
- includes a tarball when `verify.hex_build` is enabled

If the manifest sets `verify: [hex_build: false]`, release preparation still
writes the prepared bundle. The only thing omitted is the tarball, because the
artifact is intentionally not Hex-buildable.

## Track

```bash
mix weld.release.track packaging/weld/my_bundle.exs
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

Run `mix hex.publish` from the prepared bundle after inspection. In
package-projection mode, `weld.verify` already exercises
`mix hex.publish --dry-run --yes` unless `verify: [hex_publish: false]` is set.

Publish is the only release step that actually requires a tarball.

## Archive

```bash
mix weld.release.archive packaging/weld/my_bundle.exs
```

This copies the prepared release bundle into the archive surface.

## Release Bundle Contents

The prepared bundle contains:

- projected Mix project tree
- `projection.lock.json`
- built tarball when `verify.hex_build` is enabled
- `release.json` metadata

`release.json` records the manifest path relative to the repo root and the
Weld version used to prepare the bundle, which keeps release metadata portable
across checkout locations.

Tracked projection commits are intentionally separate from the prepared bundle.
The bundle is the release input; the projection branch is an optional durable
generated-source history.

## Archive Policy

The archive output is meant to preserve exactly what was released.

It is not intended to be an active generated development branch. The source
monorepo remains the source of truth, and `projection/<package_name>` is the
optional generated-source tracking surface when you need one.
