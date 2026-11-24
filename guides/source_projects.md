# Source-root artifacts

An ordinary Mix project at the root owns the OTP application, dependencies, compiler inputs and package metadata. Consumers can depend directly on that root with a Mix path, Git or Hex tuple. Direct builds use ordinary Mix state and require no Weld installation or generated files.

A maintainer adds a Weld dependency to an appropriate tooling project and defines the artifact in `build_support/weld.exs`. This example has two private component source roots. Each component can have its own Mix project for isolated compile tests. The aggregate compiles their source and declares a single application.

```elixir
[
  workspace: [root: "..", project_globs: ["components/*", "extensions/*"]],
  artifacts: [
    sprout: [
      mode: :source_project,
      roots: ["."],
      source_project: [
        files: ~w(mix.exs VERSION components/pure/lib components/runtime/lib priv test README.md),
        structural_inputs: ["VERSION"]
      ],
      package: [name: "sprout", otp_app: :sprout, version: "0.1.0", description: "Sprout"],
      verify: [hex_publish: false]
    ]
  ]
]
```

`files` lists literal paths relative to the project root. Include every file the Mix project reads, its compiler and test inputs, canonical assets, docs, committed lock and any helper needed outside the checkout. Keep private proof-only inputs and independent extensions outside the distributed package's own Hex `package.files`. Inventory roots must exist, be disjoint and contain regular files/directories. Dynamic module declarations and colliding module names are unsupported. Existing package-projection and monolith modes have their own merging rules.

```bash
mix weld.setup
git diff -- .gitignore
mix weld.project --artifact sprout --live
mix weld.project --artifact sprout
mix weld.verify --artifact sprout
```

The live view at `.weld/live/sprout` generates Mix metadata and links the declared inputs. Its compiler paths refer to the source checkout. Edits, additions and deletions under existing roots become visible to an ordinary path consumer's next build. Applications read the canonical assets through their normal application priv API. Live generation requires filesystem symlinks and refuses an unsupported link operation. The live Mix project rejects Hex build and publish.

The root Mix file, root lock when present, Weld manifest and each individual file in `structural_inputs` are fingerprinted at generation. Include every metadata helper, lock or version file whose changes should invalidate the view. A stale view reports the explicit refresh command during Mix project evaluation. If the set of inputs changes, regenerate while dependent Mix processes are idle.

A full candidate at `.weld/full/sprout/project` copies the declared inventory with its original paths and asset bytes. It can move outside the source checkout. Its `weld.provenance.json` records `kind: full` and a SHA-256 `artifact_id` of the projected source tree before adding generated provenance and the projection report. Live markers carry `kind: live`. Direct consumers choosing a refreshable full candidate can include its identity in their own dependency/build context.

## Output and release ownership

The root `.weld/` contains managed full/live views, staging, an exclusive mutation lock, caches, smoke consumers, worktrees, releases and archives. Worktrees and invocations from nested projects resolve to the current checkout root. The root ignore rule is normalized only by explicit Weld mutations. An existing tracked output subtree, symlink, conflicting exception or unmanaged target needs manual resolution. Commit the initialized ignore rule before preparing from a clean checkout.

Weld serializes its own writers. A plain Mix consumer does not participate in that lock. During refresh, Weld validates staging, moves the previous candidate aside and activates the replacement. Quiesce consumers for refreshable paths or choose an immutable prepared identity. After an interrupted writer, inspect `.weld/.lock/owner`, verify the process has exited and inspect `.weld/staging/` for preserved work before removing a stale lock.

`mix release.prepare --artifact sprout` verifies a full candidate and writes `.weld/releases/sprout/<identity>/`. The `CURRENT` pointer is updated after integrity verification. A repeated preparation with the same identity reuses verified bytes. Tracking the same prepared project again creates no commit. A new source revision, verified content, resolved lock or toolchain can produce a new identity. Retain the immutable project path for consumers needing stable input. `mix release.archive` preserves a verified copy under `.weld/archive/<artifact>/<identity>/`.

Historical `dist/`, `tmp/weld_smoke/` and `_build/weld/` trees are never auto-removed. Update scripts and paths before deciding which historical outputs to retire. The legacy `output.dist_root` key is accepted for manifest compatibility; all Weld-owned outputs use the checkout-root location.
