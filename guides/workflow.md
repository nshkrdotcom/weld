# Workflow

`Weld` is built around two verification lanes:

- source workspace verification
- welded artifact verification

They are complementary, not interchangeable.

## Source Workspace Lane

This remains the source repo's responsibility. Run the normal suite the
monorepo already owns:

- tests
- static analysis
- formatting checks
- docs or guide validation that belongs to the source repo

## Welded Artifact Lane

This is the lane `weld` owns directly. It generates a standalone package and
verifies that exact package as a consumer would see it.

## Recommended Sequence

1. Run normal source-repo preflight checks.
2. Run `mix weld.inspect` to confirm graph shape and selection.
3. Run `mix weld.project` while iterating on packaging behavior.
4. Run `mix weld.verify` before release preparation.
5. Run `mix weld.release.prepare`.
6. Publish from the prepared release bundle.
7. Run `mix weld.release.archive`.

When the selected closure includes multiple OTP applications, the projected
artifact includes a generated merged application module so package-level
verification runs against the real boot surface users will get.

## Disposable Versus Durable Output

Disposable output:

- `dist/hex/<package>/`
- smoke-app temp output
- local cache

Durable output:

- prepared release bundle
- tarball
- `projection.lock.json`
- release metadata
- archive copy created by `mix weld.release.archive`

The projection is disposable during day-to-day development. The prepared and
archived release bundle is the durable record.
