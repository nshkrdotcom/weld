# Workflow

`Weld` separates day-to-day source development from artifact projection and release preparation across two complementary verification lanes:

- **Source workspace lane:** Owned by the repository (`main`). Runs normal Mix tests, formatting, static analysis, and source-level checks without invoking `Weld`.
- **Welded artifact lane:** Owned by `Weld`. Projects a standalone Mix candidate under `.weld/` and verifies that exact artifact as downstream consumers receive it.

## Main-Tree Authority Versus Projection Snapshots

- **`main` is authoritative:** Edit code, docs, and manifests only in the source checkout. Never hand-edit files inside `.weld/` or on a `projection/*` branch.
- **Orphan `projection/<package_name>` branches hold snapshots:** `mix weld.release.track` syncs the verified `project/` tree from a prepared release bundle onto `projection/<package_name>`, creating that branch as an orphan on first use. Downstream repositories that consume projected Git commits or pre-release snapshots point at `projection/<package_name>` while `main` keeps normal workspace history.

## Live Versus Full Projections

Run `mix weld.explain` for a one-screen map of every projection kind, its path, and the task that creates it.

- **Live view (`.weld/live/<artifact>/`, all modes):** Generate with
  `mix weld.project --artifact <name> --live` and depend on that directory
  with `path:` in an ordinary Mix consumer. Linked package and source-project
  directories expose code and asset edits on the next build. A monolith uses
  file links for its merged layout. Refresh a monolith when files are added,
  removed, or remapped, and refresh any live view when its structural guard
  reports a change. Run formatters and code generators from the source
  checkout.
- **Full candidate (`.weld/full/<artifact>/project/`, all modes):** Generated with `mix weld.project` (and refreshed automatically by `mix weld.verify` and `mix release.prepare`). Contains regular copied/synthesized files, `weld.provenance.json` (`kind: "full"`, `artifact_id`), and `projection.lock.json`.

An identical project command checks the source inventory and generated output
under the checkout lock and leaves a valid projection in place. Pass
`--no-cache` to force materialization. Unsafe source paths still fail
validation.

## Recommended Release Sequence

1. Run `mix weld.setup` once (and commit `.gitignore` if updated) so `.weld/` is ignored on a clean tree.
2. Run the source repository's own test and quality gates.
3. Run `mix weld.inspect` to confirm workspace discovery, selected closure, and zero graph violations.
4. Run `mix weld.project` and `mix weld.verify` for each artifact while
   iterating on packaging configuration. Compile any live view you intend to
   share from a separate Mix consumer.
5. From a clean committed revision, run `mix release.prepare` (or `--all`) to verify and write `.weld/releases/<artifact>/<identity>/`.
6. Run `mix release.status` (or `--all`) to confirm `ready` state, expected `archive_sha256`, and zero `docs.source_ref` warnings.
7. Optionally run `mix release.track --tag-release --push` to record `weld.receipt/v1` trailers on `projection/<package_name>` and an annotated release tag.
8. Run `mix release.publish` (or `mix release.stage --fresh` for manual `mix hex.publish`) to verify a local Hex rebuild against the prepared tarball SHA-256 and hand off interactively to Hex.
9. Run `mix release.archive --identity <sha>` using the pinned identity printed after publish to save the bundle under `.weld/archive/<artifact>/<identity>/`.

## Local `.weld/` State Versus Git-Durable Records

All Weld-owned local files live under `<checkout_root>/.weld/` (gitignored and machine-local):

- **Disposable working state:**
  - `.weld/live/<artifact>/` — local symlinked development view
  - `.weld/full/<artifact>/project/` — latest full projection working copy
  - `.weld/cache/<projection_id>/<toolchain>/` — warm dependency checkouts and compiled build artifacts used by `mix weld.verify` (delete while idle to force a cold verification run)
  - `.weld/publish/<artifact>/<identity>/` — writable workspaces for `release.stage` and per-run `release.publish`
  - `.weld/staging/`, `.weld/smoke/`, `.weld/worktrees/` — ephemeral mutation, smoke-consumer, and Git worktree directories
- **Local verified release storage (deleting `.weld/` removes the only local copy of built tarballs and docs):**
  - `.weld/releases/<artifact>/<identity>/` and `CURRENT` — immutable verified release bundle (`project/`, `docs/`, `release.json`, and optional Hex `.tar`)
  - `.weld/archive/<artifact>/<identity>/` — post-publication local archive copy
- **Git-durable release records:**
  - `projection/<package_name>` commits and annotated tags — carry `weld.receipt/v1` trailers (`Weld-Identity`, `Weld-Project-SHA256`, `Weld-Docs-SHA256`, `Weld-Archive-SHA256`, `Weld-Source-Revision`), verifiable from any clone with `mix release.verify_tag <tag>`

Update any scripts still reading legacy `dist/` directories before retiring
them. See [Source-Project Artifacts](source_projects.md) for lock ownership and
consumer concurrency details.
