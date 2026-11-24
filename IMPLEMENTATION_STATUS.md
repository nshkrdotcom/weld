# Implementation status — November 24, 2026

The 0.15.0 source implements checkout-owned `.weld/` output management, canonical ignore normalization, live/source and full/portable projections, immutable prepared release identities, source-consumption fixtures and updated release documentation. Main-tree development remains authoritative; projection branches remain snapshots. Existing flattened projection modes and data-only compatibility metadata remain supported.

The independently reviewed changes include smoke consumer isolation from inherited Mix path overrides. Permanent regression coverage lives in `test/weld/{output,source_project,source_consumption,smoke_app}_test.exs`, the release tests and the neutral `test/fixtures/source_project` fixture. See `guides/source_projects.md` for the exact new manifest and paths.

## Evidence boundary

Git whitespace checks and inspected filesystem/Git primitives passed. Approximate lexical inspection found no Elixir delimiter issues. These are not compilation or ExUnit results. No Elixir/OTP runtime was available during implementation; `mix ci`, all Mix/Hex consumer operations, formatter/lint/type checks, documentation generation and release preparation require execution on the target toolchains.

Run the full `AGENTS.md` acceptance gate, including `mix ci` and the source-consumption lane. Verify the next minor against actual history, prepare from a clean committed revision, inspect the exact archive, and let the user perform publication. Verify the published Hex version afterward. No source status document substitutes for the release receipt or recorded prepared identity.

The fixtures, consumer tests and smoke isolation regression are permanent. No temporary Python inspection scripts were added to Weld. Historical generated directories require an ownership check before deletion; the migration does not authorize deleting unknown local content.
