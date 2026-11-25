# Workflow

`Weld` separates day-to-day source development from artifact projection and release preparation across two complementary verification lanes:

- **Source workspace lane:** Owned by the repository (`main`). Runs normal Mix tests, formatting, static analysis, and source-level checks without invoking `Weld`.
- **Welded artifact lane:** Owned by `Weld`. Projects a standalone Mix candidate under `.weld/` and verifies that exact artifact as downstream consumers receive it.

## Main-Tree Authority Versus Projection Snapshots

- **`main` is authoritative:** Edit code, docs, and manifests only in the source checkout. Never hand-edit files inside `.weld/` or on a `projection/*` branch.
- **Orphan `projection/<package_name>` branches hold snapshots:** `mix weld.release.track` syncs the verified `project/` tree from a prepared release bundle onto `projection/<package_name>`, creating that branch as an orphan on first use. Downstream repositories that consume projected Git commits or pre-release snapshots point at `projection/<package_name>` while `main` keeps normal workspace history.

## Live Versus Full Projections

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
5. From a clean committed revision, run `mix release.prepare` to verify and write `.weld/releases/<artifact>/<identity>/`.
6. Optionally run `mix release.track` to update `projection/<package_name>` (with optional `--tag` and `--push`).
7. Run `mix release.stage` and publish with `mix hex.publish` from the printed workspace.
8. Run `mix release.archive` to record the released bundle under `.weld/archive/<artifact>/<identity>/`.

## Disposable Versus Durable Output

All Weld-owned files live under `<checkout_root>/.weld/`:

- **Disposable working state:**
  - `.weld/live/<artifact>/` — local symlinked development view
  - `.weld/full/<artifact>/project/` — latest full projection working copy
  - `.weld/cache/<projection_id>/<toolchain>/` — warm dependency checkouts and compiled build artifacts used by `mix weld.verify` (delete while idle to force a cold verification run)
  - `.weld/publish/<artifact>/<identity>/project/` — writable copy for publishing a verified release
  - `.weld/staging/`, `.weld/smoke/`, `.weld/worktrees/` — ephemeral mutation, smoke-consumer, and Git worktree directories
- **Durable release records:**
  - `.weld/releases/<artifact>/<identity>/` and `CURRENT` — immutable verified release bundle (`project/`, `docs/`, `release.json`, and optional Hex `.tar`)
  - `.weld/archive/<artifact>/<identity>/` — post-publication archive copy
  - `projection/<package_name>` commits and tags — durable projected-source Git history when tracked

Update any scripts still reading legacy `dist/` directories before retiring
them. See [Source-Project Artifacts](source_projects.md) for lock ownership and
consumer concurrency details.
