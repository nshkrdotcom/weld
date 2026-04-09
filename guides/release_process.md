# Release Process

`Weld` separates release preparation from Hex publication.

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
- builds the tarball
- writes a deterministic release bundle

## Publish

Run `mix hex.publish` from the prepared bundle after inspection.

## Archive

```bash
mix weld.release.archive packaging/weld/my_bundle.exs
```

This copies the prepared release bundle into the archive surface.

## Release Bundle Contents

The prepared bundle contains:

- projected Mix project tree
- `projection.lock.json`
- built tarball
- `release.json` metadata

`release.json` records the manifest path relative to the repo root and the
Weld version used to prepare the bundle, which keeps release metadata portable
across checkout locations.

## Archive Policy

The archive output is meant to preserve exactly what was released.

It is not intended to be an active generated development branch. The source
monorepo remains the source of truth.
