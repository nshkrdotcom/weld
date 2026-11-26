# Release process

1. Bump the source package version, update the changelog and run full QC. Commit all source and manifest changes; initialize `.weld/v2` with `mix weld setup` and commit the ignore rule.
2. Run `mix weld prepare --artifact NAME`. Inspect `mix weld status --artifact NAME` and retain the exact identity. The bundle contains the detached project, docs, a frozen docs archive and optional Hex package tarball.
3. Verify the package contents, install the exact archive in a detached consumer, and confirm documentation. Run `mix weld track --artifact NAME --identity ID --tag-release` only when the source and bundle match; Git pushes are explicit.
4. Run `mix weld publish --artifact NAME --identity ID --dry-run`. This is a local validation, not proof of remote acceptance. When separately authorized, set `HEX_API_KEY` securely and pass `--yes` to publish the exact archive. Do not rebuild or run `mix hex.publish` against a different project. Confirm remote bytes and retain the outcome. If the result is unknown, use `mix weld reconcile --artifact NAME --identity ID`; never retry on the assumption that an interrupted request did not commit.
5. Archive the pinned bundle with `mix weld archive`. Never delete active leases or mutable state manually without inspecting their owner and recovery facts.

No production publication or Git push is part of normal QC.
