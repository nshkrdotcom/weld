# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.20.0] - 2026-11-26

This release introduces schema 2 and a single `mix weld` entry point.
Runtime qualification applies to the exact source revision and toolchain
recorded in the release evidence.

### Added

- Preserve the distinction between artifact-rooted and project-relative Erlang
  includes in portable proof and staged native compiler comparisons. Require
  explicit include directories to be covered by the detached source inventory.
- Verify native project description, Elixir requirement and test settings in
  staged metadata; apply flat OTP app identity checks to actual included tests
  and test-support libraries instead of dormant suites.

- Define closed schema 2 workspace, project input, artifact, layout, file,
  verification and publication declarations with path-qualified errors,
  duplicate/unknown-key rejection and explicit unsupported combinations.
- Collect bounded immutable source observations and isolated dev/test/prod Mix
  metadata once per workspace revision. Observe helper files, required files,
  missing roots and discovery patterns; diagnose unsupported metadata drift.
- Introduce a pure compiler and one portable inventory for components, flat and
  preserve layouts: exact full/live operations, file and directory link groups,
  normalized executable modes, empty directories, source roles, generated
  provenance, topology and absence watches, and explicit publication membership.
- Add canonical JSON and domain-separated input, plan, project, package, docs,
  qualification, bundle and cache identities. Reject noncanonical or malformed
  proof and bind bundle records to exact frozen observations and gate facts.
- Add v2 state ownership, artifact and destination leases, bounded metadata lock
  acquisition, run records, journaled activation/sealing/pointer transitions,
  dead-owner recovery and conservative GC. Active, interrupted and unknown work
  stays protected; GC defaults to a read-only report.
- Implement G01–G12 as one qualification path for verify and prepare. Freeze a
  resolved standalone lock, re-probe effective metadata, compare actual source
  and artifact test identities, recheck complete inventories at gate boundaries,
  and freeze exact package/docs archives once.
- Inspect actual Hex archive metadata, entry kinds, paths, normalized modes,
  sizes, digests and contents. Install the exact archive through an ordinary
  signed loopback Hex registry in a detached consumer with no Weld dependency;
  configured smoke and native payload behavior run in that consumer.
- Add explicit locked-preserve proof reuse eligibility tied to public context,
  compiler/toolchain/trust facts and intact sealed evidence. Ineligible reuse
  runs qualification; corrupt sealed bundles fail closed; `--fresh` bypasses
  proof and mutable work-cache reuse.
- Add immutable `inventory.json`, `qualification.json`, `bundle.json`, exact
  package/docs payloads and `weld.current/2` pointers, plus strict canonical
  annotated Git receipts. Historical pin operations work without the current
  manifest, including tag-only verification and idempotent exact-byte archives.
- Add durable per-part package/docs publication intent and outcomes, conservative
  authenticated readback, conflict and staging states, read-only reconciliation
  queries and partial continuation without repeating a confirmed package send.
- Add fault, malformed proof/archive, subprocess, concurrency, killed-owner,
  GC-race, exact HTTP body, signed-consumer and native fixture tests. Supply
  architecture, source accounting, local Git, browser, reuse, conformance,
  representative benchmark and synthetic soak drivers.

### Changed

- Run isolated source tests asynchronously and separate slower source cases
  from the default `mix test` run. Keep global Mix and environment mutations
  serial, retain every integration lane and include the probe-timeout case in
  CI. Bound concurrent CI lanes and nested ExUnit work for multicore hosts.
- Normalize Erlang `{:i, charlist}` include paths in portable plan and
  qualification evidence and in preserve staging checks.
- Compare the same observed native package metadata fields by Mix environment
  before and after preserve materialization.
- Use declared links in generated package metadata and omit the redundant
  maintainers field. Preserve follows the pinned Hex default Makefile patterns.
- Allow `Application.app_dir/2` for the surviving `:flat` monolith `package.otp_app`
  while continuing to reject absorbed component OTP app assumptions.

- Consolidate the public surface into `mix weld COMMAND` and `Weld.run/2`, with
  typed requests, one JSON result envelope, stderr diagnostics and stable exit
  codes. Complete help, views, contexts, historical `--root` pins, run lookup,
  recovery, doctor, remote status and deterministic batch error aggregation.
- Use one shared facts value for batch commands and one snapshot per side of
  affected analysis. Compare genuine Git trees, old/new graph contributors,
  adds/deletes/renames/modes and unknown facts conservatively. Release planning
  reports dependency order and constraints without scheduling publication.
- Preserve actual and publication graphs, computed requirements and Hex aliases,
  optional features and mixed dependency scopes. Remote Git requirements remain
  valid for non-Hex artifacts; Hex publication requires versioned package
  boundaries. Reject effective local filesystem Git locators before rendering
  unless generated layouts replace them with canonical remote Git or Hex
  declarations. Preserve requires a native declaration change. Selected internal
  path dependencies retain the chosen layout's ownership rules.
- Share generated Mix, OTP application and runtime bootstrap renderers between
  components and flat. Preserve native Mix callbacks and nested path behavior
  through the common executor. Keep checked-in docs hooks and installed `priv`
  bootstrap independent of the original checkout.
- Relocated bootstrap config imports the observed environment companion when
  present. A missing optional environment companion leaves base config intact.
- Keep ordinary live code linked where safe; copy native, configuration,
  metadata and mutable runtime inputs. Require refresh for copied input,
  structural, discovery and flat topology changes. Validate exact expected
  targets, empty directories and live links before reusing a view.
- Normalize projected regular modes to 0644/0755 according to executable bits;
  preserve source modes in the source checkout. Equal-byte/equal-mode flat
  deduplication retains every origin, while code conflicts fail before activation.
- Bound subprocess time and output, sanitize private logs, scrub inherited
  Mix/Hex/compiler overrides and terminate process groups on timeout. Run gates
  outside metadata locks and keep the parent prepare lease through sealing.
- Use local ref compare-and-swap and explicit atomic branch/tag push, reject tag
  conflicts before mutation, keep source tags separate and never overwrite tags.
- Keep exact-byte public writes disabled until the destination and pinned
  adapter pass authenticated conformance. Unsupported public docs readback or
  staged-absence representations remain unknown rather than authorizing a send.
- Update all guides, README, AGENTS, self-hosting schema 2 declaration, ExDoc and
  acceptance/disposition evidence for the complete change since 0.19.0. Retain
  all fifteen isolated CI lanes and add qualification fault and Hex-consumer lanes.
- Retain the resolved Hex Core 0.21.1 lock pin and remove unused Multigraph and
  telemetry dependencies.

### Removed

- Remove dotted/duplicate Mix tasks, implicit discovery, old public bang APIs,
  legacy manifests/state/receipt readers, ETF proof and embedded projection
  reports. No compatibility runtime or automatic migration is provided.
- Remove the rebuild-and-publish handoff. Publication consumes frozen archive
  bytes only; staging changes do not qualify or replace a bundle.
- Replace separate source-project/live projector authorities and shell-side
  input selection with pure preserve/live/input policies and one executor.
- Adopt schema 2 in a clean coordinated change: create explicit project/layout
  declarations, run `mix weld setup`, commit the ignore rule and manifest, then
  prepare a new bundle. Keep historical state with its historical tool version;
  do not import it into v2.

## [0.19.0] - 2026-11-25

### Added

- Add `package.docs.hook_file` and Weld.docs_options!/2 so a single checked-in
  HTML file can own the ExDoc `before_closing_body_tag` hook across both the
  source checkout's `mix docs` and projected builds.
- Add `Weld.DocsSmoke` and `mix weld.docs.check` to verify generated ExDoc HTML
  (`index.html` presence and `exdoc:loaded` Mermaid hook integrity), and enforce
  the check automatically in `release.prepare` and `release.publish`.
- Add `mix weld.explain`, `mix weld.status`, `mix weld.diff`, `mix weld.doctor`,
  `mix weld.open`, `mix weld.gc`, and dependency-verified `mix weld.release.plan` with
  `--format json` support for agent and maintainer workflows.

### Fixed

- Listen on ExDoc's `exdoc:loaded` window event (instead of `DOMContentLoaded`
  only) and select `dark` vs `default` theme in the built-in Mermaid hook so
  diagrams render across in-site ExDoc navigation and dark mode.
- Preserve complete custom docs hooks, reject unsafe hook paths, and include
  hook files in projection cache keys and live structural guards. Root docs
  options no longer recursively load workspace Mix projects.
- Check nested Mermaid HTML pages and actual script declarations instead of
  accepting incidental hook names in prose, comments, quoted JavaScript, or
  ignored external-script bodies; preserve quoted HTML attributes and division
  expressions around real listeners.
- Resolve release planning from artifact publication dependencies, including
  computed requirements and Hex aliases; reject cycles and duplicate package
  identities, and honor `--no-check` for incompatible release versions.
- Include source-only and hidden configuration files in `weld.diff`, and make
  status commands preserve explicit manifests and prepared bundle identities.
  Follow live directory links without failing on unrelated dangling links,
  while still rejecting cycles and surfacing other filesystem errors.
- Keep active publishers safe from garbage collection, reject symlinked cleanup
  parents, and isolate verification, smoke, and publication subprocesses from
  inherited Mix project, lockfile, target, and build-path overrides.
- Carry generated application bootstrap config in package `priv` files and
  resolve it from the installed application so compiled artifacts remain
  usable after their source checkout is moved or removed.
- Include component config trees in generated projection cache inputs so
  config, imported files, companion bytes, permissions, and missing-directory
  changes refresh both full and live bootstrap copies.
- Normalize verified ExDoc output to `doc/` so native source projects with a
  custom docs output directory can still prepare their release preview.

## [0.18.1] - 2026-11-24

### Fixed

- Let monolith artifacts choose a repository README for the package root with
  `monolith_opts: [readme: "path/to/README.md"]`. The selected file is also the
  `README.md` extra for HexDocs.

## [0.18.0] - 2026-11-24

### Added

- Embed versioned `weld.receipt/v1` Git trailers (package, version, artifact,
  bundle identity, source revision, project/docs/archive SHA-256, and tool
  version) in `projection/*` commits and annotated `--tag` / `--tag-release`
  tags. Create receipt-bearing same-tree commits when bundle identity changes
  without projection tree edits, and reject conflicting or legacy lightweight
  tags before moving refs.
- Add `mix release.verify_tag <tag>` (`mix weld.release.verify_tag`) to verify
  tag and commit receipts against optional local bundles or tarballs. The
  receipt selects the artifact and identity, including in multi-artifact repos.
- Add read-only `mix release.status [--artifact name | --all] [--format json]`
  with shared two-layer integrity and freshness classification (`ready`,
  `stale` reason codes, `unprepared`, `corrupt_bundle`, local projection sync).
  Lists all artifacts by default and reports source roots, default tags, and
  projection and bundle paths in text and JSON.
- Add `mix release.publish` (`mix weld.release.publish`) to pin a verified
  bundle identity, stage an isolated per-invocation workspace, verify a local
  `mix hex.build` matches the prepared tarball SHA-256, and hand off
  interactively to `mix hex.publish` without holding `.weld/.lock`. Pass
  `--dry-run` to validate the handoff without uploading.
- Add `--identity <sha>` pinning across `release.track`, `release.stage`,
  `release.publish`, and `release.archive`, `--fresh` and `--path-only` on
  `release.stage`, `--all` on `release.prepare` and `release.archive`, and
  early `docs.source_ref` warnings for projected packages.

### Fixed

- Evaluate staged component `config/runtime.exs` files via `Code.eval_file/1`
  in deterministic order instead of emitting forbidden `import_config/1` calls
  inside generated `config/runtime.exs`, preserving `Config.Reader`, lexical
  isolation, and accurate `__DIR__`.

## [0.17.1] - 2026-11-24

- Stage a verified project for Hex with `mix release.stage`. Mix and Hex write
  build files in a checkout-local `.weld/publish/` workspace. The prepared
  release stays intact for tracking and archiving.

## [0.17.0] - 2026-11-24

### Added

- Reuse unchanged live and full projections after validating the source
  inventory and generated output. Pass `mix weld.project --no-cache` to
  force materialization.
- Use `mix release.prepare --reuse CONTEXT` to reuse an intact, verified
  bundle for a locked source-project artifact with Hex publishing checks
  disabled. Use `--no-cache` for an independent rebuild.

### Fixed

- Generate stable HTML code-highlight group IDs so independent preparations
  can reproduce the documentation preview byte for byte.
- Keep projection reuse metadata out of prepared bundles so an unchanged
  projection produces the same release files whether materialized or reused.

## [0.16.0] - 2026-11-24

### Added

- Generate linked live views for package-projection and monolith artifacts from
  the same composition as their full counterparts. Live projects use ordinary
  Mix and require refresh when inputs that determine their layout change.
- Preserve nested standalone Mix projects as source-project artifacts and
  declare artifact-local package boundaries with `external_projects`.
- Include selected component suites in package-projection verification with
  `verify: [component_tests: true]` while excluding verification files from Hex.

### Fixed

- Plan monolith collisions, migration layouts, configuration, helpers and
  generated project files before writing outputs. Inspection, affected analysis,
  projection locks and both projection kinds use the final inventory. Reject
  stale plans, ambiguous slugs, and file/directory collisions before activation.

- Report the actual projects that own compiled sources and inventory, including
  sources linked into live projects. Use the same ownership to detect affected
  artifacts when Git paths are added, changed, renamed, or deleted.
- Retain the files required to verify a detached prepared project alongside the
  separate Hex package allowlist.

### Upgrading

- Existing manifests retain their dependency closure unless they opt into
  `external_projects`. Refresh existing live views after upgrading Weld.
- Linked package directories expose ordinary additions and deletions on the
  next compile. Live monoliths require refresh when file topology changes.

## [0.15.0] - 2026-11-24

- Add explicit source-project artifacts with portable full candidates and optional live views of canonical compiler inputs and assets.
- Collect generated projections, verifier caches, smoke consumers, locks, worktrees and immutable prepared releases beneath the checkout's `.weld/`.
- Normalize the root ignore rule on explicit projection operations and protect unmanaged output. Existing `dist/` trees remain available for manual migration.
- Bind prepared identities to verified project, archive, resolved lock, configuration, source revision and toolchain. Retain component-preserving and monolith projection, archive and orphan branch tracking.

## [0.14.0] - 2026-11-22

- Keep projection metadata in prepared projects and tracked Git projections.
  Omit `projection.lock.json` from generated Hex archives in both modes.

## [0.13.1] - 2026-11-22

- Keep verification dependency checkouts and compiled output under the
  workspace's `_build/weld/` directory. This preserves warm verification and
  keeps compiler symlinks out of source probes such as Mix Workspace Ops.

## [0.13.0] - 2026-11-22

- Reuse Mix dependency checkouts and compilation state across verification runs and report stage timings.
- Serialize operations sharing a projection or prepared bundle.
- Verify prepared release digests before tracking or archiving.
- Reject invalid options in projection and release commands.
- Support opt-in Mermaid rendering in generated HTML documentation.

## [0.12.0] - 2026-11-22

Default `mix test` runs the fast checks. `mix ci` also runs the tests that
build and verify generated packages. Blitz runs the independent checks in
parallel with isolated Mix build directories and streams labeled results.
Release checks reuse prepared outputs and compare package contents across
clean checkouts.

### Added

- Prepared bundles provide rendered documentation beside the clean project and archive.

### Release verification

- Freeze the projection lock before building the Hex archive and encode nested JSON keys in a stable order.
- Apply Hex dry runs in both projection modes and reject unsupported monolith verification settings.
- Reject dirty Git release inputs and conflicting monolith private assets.

### Changed

- prepared bundles now expose the portable
  `mix_workspace_ops.prepared_artifact/v2` handoff consumed by an external
  clean-checkout release transaction, while Weld remains independent of Mix
  Workspace Ops and publication credentials.
- generated release projects contain only declared package files, the portable
  lockfile, and owned tests; transient build, dependency, documentation, and
  nested archive outputs are excluded.

### Fixed

- prepared project trees and lockfiles are reproducible across independent
  checkout locations, and handoff manifest paths are anchored to the Git root.

## [0.11.0] - 2026-08-30

### Removed

- **Breaking:** remove `Weld.DependencySources`, its canonical helper template,
  and `mix weld.dependency_sources.verify`. Dependency-source selection and
  verification now live outside Weld's package-projection boundary.
- **Breaking:** remove `Weld.EcosystemReport` and
  `mix weld.ecosystem.report`; their graph, publish-order, clone, and readiness
  fields were projections of the removed dependency-source manifest.
- remove dependency-source requirements from `mix weld.agents.verify`; the task
  continues to enforce runtime-environment guidance.

### Changed

- consumer guidance now targets Weld `~> 0.11.0` and keeps Weld focused on
  projection, generated-package verification, and release bundles.

## [0.10.0] - 2026-08-11

### Added

- prepared release metadata now exposes a bounded,
  `mix_workspace_ops.prepared_artifact/v1` data handoff containing the source
  revision, package/version, relative artifact paths, and SHA-256 digests.

### Changed

- consumer guidance and release documentation now target Weld `~> 0.10.0`.

### Architecture

- Weld retains complete ownership of projection and artifact preparation; the
  handoff introduces no Mix Workspace Ops dependency or executable coupling,
  leaving clean-checkout transaction consumption to a later product-driven
  integration.

## [0.9.0] - 2026-08-10

### Added

- the canonical dependency-source template now provides fail-closed publish
  preflight checks, machine-readable release ordering, source inspection, and
  exact task-token detection for Hex-only package builds and publication.
- package projections can declare Hex-only development dependencies so their
  generated artifacts run Credo and Dialyzer as first-class release gates.

### Security

- dependency-source configuration and local overrides are parsed as literals
  instead of evaluated as code, configured names cannot allocate arbitrary
  atoms, and local-path resolution is absolute and bounded to declared sources.

### Changed

- consumer guidance and release documentation now target Weld `~> 0.9.0`.

### Fixed

- generated-project verification recognizes both the legacy ExUnit summary and
  Elixir 1.20's `Result: N passed` summary without weakening the zero-test or
  failure checks.

## [0.8.4] - 2026-07-13

### Fixed

- monolith projection now honors every selected project's declared
  `test_paths` instead of copying all files below `test/`, preventing dormant
  or separately owned suites from leaking into generated-package verification.
- selected-project test paths are constrained to their owning project root and
  overlapping paths are de-duplicated before projection.

### Changed

- consumer guidance and release documentation now target Weld `~> 0.8.4`.

## [0.8.3] - 2026-07-13

### Added

- generated-package HexDocs metadata for logos, homepage/source links, source
  refs, copied assets, titled extras, and ordered extra-page groups in both
  package-projection and monolith modes.

### Fixed

- monolith `package.files` now includes every manifest-declared output document
  and asset, including individual changelog and SVG paths outside Weld's legacy
  hard-coded candidates.
- monolith package allowlists now collapse descendant paths already covered by
  a declared directory, keeping generated Hex previews explicit but minimal.
- the repository `mix ci` alias now launches test-environment child commands
  through an explicit `env` executable, avoiding Mix 1.19's literal-command
  parsing failure for the former inline assignment syntax.

### Changed

- consumer guidance and release documentation now target Weld `~> 0.8.3`.

## [0.8.2] - 2026-05-10

### Fixed

- `mix weld.agents.verify` now ignores generated build and dependency
  directories at any repo depth, preventing nested package `deps/AGENTS.md`
  files from being treated as source-owned guidance.

## [0.8.1] - 2026-05-10

### Fixed

- the canonical dependency-source helper now preserves GitHub `subdir` metadata
  and per-dependency options such as `only`, `runtime`, and `override`, allowing
  consumer repos to remove one-off dependency resolver modules without losing
  workspace, GitHub fallback, or Hex publish behavior.

## [0.8.0] - 2026-05-10

### Added

- `Weld.Credo.Check.NoRuntimeOsEnv` for rejecting direct OS environment API
  calls in runtime `lib/**` code.
- a canonical `build_support/dependency_sources.exs` template plus
  `mix weld.dependency_sources.verify` for helper drift, manifest shape,
  source metadata, and publish-mode blocker checks.
- `mix weld.agents.verify` for root and nested `AGENTS.md` dependency-source
  and runtime-env guidance.
- `mix weld.ecosystem.report` for dependency graph, publish-order,
  clean-clone, and publish-readiness reports across repo sets.

### Changed

- consumer guidance now targets the Weld `~> 0.8.0` line.
- the Hex package file list now includes `priv/templates` so packaged Weld
  carries the dependency-source helper template without generated PLT files.

## [0.7.2] - 2026-04-23

### Changed

- publish Weld with a current Telemetry dependency requirement (`~> 1.4`) so
  downstream welded-package verification can use the latest Telemetry 1.4.x
  line without stale owned-package constraints.
- refresh development quality tooling to the latest available Credo patch
  release.

## [0.7.1] - 2026-04-13

### Added

- repo-layout autodiscovery for Weld CLI tasks. When no manifest path is
  passed, Weld now prefers `build_support/weld.exs`, then
  `build_support/weld_contract.exs`, then a single `packaging/weld/*.exs`
- plain `mix release.prepare`, `mix release.track`, and `mix release.archive`
  wrapper tasks that delegate to the Weld release flow

### Changed

- the recommended consumer steady state now uses Weld's standard manifest
  locations plus direct task invocation instead of repo-local alias blocks that
  only forward manifest paths and artifact names

## [0.7.0] - 2026-04-13

### Changed

- prepared release bundles now treat the projected source tree as the canonical
  tracked payload and the tarball as optional bundle content
- `weld.release.prepare`, `weld.release.track`, and `weld.release.archive` now
  work for internal-only artifacts that intentionally set `verify.hex_build:
  false`
- consumer guidance now recommends plain Hex consumption of Weld `~> 0.7.0`
  and prerelease version bumps for coordinated pre-release validation instead
  of baking repo-local path/git override logic into every consumer repo

### Fixed

- `Weld.Release.prepare!/1` no longer crashes when verification intentionally
  omits a tarball
- archive and projection tracking now work from prepared bundles that do not
  contain a tarball

## [0.6.0] - 2026-04-13

### Added

- `mix weld.release.track` and the corresponding public API for tracking
  prepared bundles on durable `projection/<package_name>` branches.
- thin Git helpers for branch detection, worktree management, tagging, and
  push operations used by projection tracking.
- real Git fixture coverage for projection tracking, including orphan-branch
  initialization, no-op sync, content updates, and tag/push behavior.
- a root `mix ci` alias that runs the full formatter, compiler, test, Credo,
  Dialyzer, and docs gate.

### Changed

- projection tracking now treats orphan `projection/<package_name>` branches as
  the default durable generated-source history surface.
- README and guides now document tracked projections, consumer override policy,
  and the `0.6.0` dependency line.

## [0.5.0] - 2026-04-11

### Changed

- Weld now depends on `multigraph ~> 0.16.1-mg.3` directly instead of the old
  `libgraph` alias shape, matching the dependency's current package and OTP app
  contract.
- workspace graph operations now target `Multigraph.*` throughout the codebase,
  which restores compatibility with the current graph backend API.
- README and guide installation examples now target the `0.5.0` dependency
  line.

## [0.4.1] - 2026-04-11

### Added

- explicit `verify.hex_build` and `verify.hex_publish` manifest controls so
  artifacts can opt out of Hex-only verification steps by policy.

### Changed

- README and guide examples now target the `0.4.1` dependency line and document
  when Hex build and dry-run publish verification should be disabled.

### Fixed

- verifier results now mark skipped Hex-only steps explicitly and only record a
  tarball path when `mix hex.build` actually ran successfully.

## [0.4.0] - 2026-04-09

### Added

- `Weld.version/0`, a stable public version API for bundle metadata and
  downstream tooling that needs the packaged Weld version instead of the caller
  project's version.

### Changed

- prepared release bundle metadata now records the manifest path relative to
  the repo root instead of an absolute filesystem path.
- release bundle slug derivation is now stable across checkout locations while
  still reflecting the selected artifact and manifest contents.
- release docs and installation examples now target the `0.4.0` line.

### Fixed

- `release.json` now records the actual Weld version instead of the consumer
  repo version when Weld runs as a dependency.
- workspace discovery no longer duplicates `"."` when the root project is
  already declared in `blitz_workspace.projects`.

## [0.3.3] - 2026-04-08

### Fixed

- generated package-mode and monolith-mode application modules now emit an
  explicit `@moduledoc false`, so prepared release bundles and projected
  monoliths stay Credo-clean when downstream repos lint the generated
  artifacts directly

## [0.3.2] - 2026-04-08

### Added

- a shared source formatter helper for generated Elixir sources so projected
  Mix files, generated applications, and synthesized config roots are emitted
  formatter-clean by construction.

### Changed

- projected package and monolith artifacts now preserve repo-root Mix tooling
  files such as `.formatter.exs`, with support ready for other root quality
  config files when present.

### Fixed

- prepared release bundles and projected monoliths can now run `mix format`
  from the artifact root without ad hoc arguments or missing-config failures.
- generated `mix.exs`, application modules, and root config files are now
  emitted in formatter-clean form, so dist artifacts satisfy the normal
  formatter gate instead of only compiling and testing cleanly.

## [0.3.1] - 2026-04-08

### Added

- package-mode regression fixtures and projector tests covering projected
  package config bootstrap, root `ecto_repos` overlays, and repo-priv layout.

### Changed

- projected package and monolith `mix.exs` files now declare an explicit
  `build_path`, which keeps Mix from misclassifying generated multi-app config
  as invalid during local dist verification commands.
- staged static config sources now preserve selected project app config instead
  of blanking it out and relying solely on generated application bootstrap.

### Fixed

- prepared bundles and projected monoliths now keep repo config available for
  direct dist commands such as `mix ecto.create`, `mix ecto.migrate`, and
  other Mix tasks that need config before the generated application starts.
- regenerated artifacts no longer emit false-positive "configured application
  ... is not available" warnings during normal Mix task execution.

## [0.3.0] - 2026-04-08

### Added

- `monolith_opts[:test_support_projects]`, an explicit manifest-owned contract
  for non-selected workspace projects that still participate in the monolith
  `:test` view as source-only support.

### Changed

- Monolith projection now fails closed when
  `monolith_opts[:test_support_projects]` is declared but the discovered
  non-selected test support set does not match the manifest.
- Monolith config bootstrap app ownership is now derived from staged bootstrap
  sources rather than from every staged project app, which keeps generated
  application bootstrap allowlists aligned with the actual runtime config
  surface.
- Consumer integration docs, monolith docs, and examples now describe the
  explicit source-only test support policy.

### Fixed

- `guides/consumer_repo_integration.md` now references the current Weld
  dependency line instead of an outdated `0.1.0` example.

## [0.2.0] - 2026-04-07

### Added

- **Monolith artifact mode** (`mode: :monolith`): projects selected packages and
  their test-view closure into a single flat Mix project under
  `dist/monolith/<package>/` instead of `dist/hex/<package>/`. Merges `lib/`,
  `test/`, `priv/`, config, and migrations from all selected projects with
  automatic file-conflict resolution and deterministic migration re-stamping.
- `monolith_opts` artifact key: supports `shared_test_configs` (list of project
  ids whose `test.exs` are included in the monolith root config) and
  `extra_test_deps` (atoms referencing manifest-declared dependencies to force
  into test-only deps in the generated mix file).
- Weld.Config.Generator: generates a merged config tree for monolith artifacts,
  sanitizing workspace-app config calls from static copies while preserving full
  originals under `config/runtime_sources/` for bootstrap use.
- Weld.Projector.Monolith, Weld.Projector.Monolith.FilePlan,
  Weld.Projector.Monolith.Migrations, Weld.Projector.Monolith.MixFile,
  Weld.Projector.Monolith.TestHelper: internal modules implementing monolith
  projection, file merging, migration merging, mix file generation, and test
  helper synthesis.
- `Plan.projects_for_view/2` and `Plan.external_deps_for_view/2`: view-scoped
  project and dependency queries used by monolith projection.
- Git/GitHub-only manifest dependencies: `requirement` is now optional when
  `opts` include `:git` or `:github`, enabling manifest-declared git deps without
  a version constraint.
- Monolith verifier gate: runs per-selected-project test baseline before
  verifying the merged artifact, then asserts the monolith test count is not
  lower than the baseline sum.
- `mode: :components` is accepted as an alias for `:package_projection` for
  compatibility with earlier internal configurations.

### Changed

- Package-projection verifier now runs `deps.compile` then
  `compile --warnings-as-errors --no-compile-deps` instead of a single
  `compile --warnings-as-errors` step.
- Manifest dependency validation: `:path` is still rejected; `:git` and
  `:github` are now permitted in dependency opts.
- Canonical external dep normalization strips `:override`, `:branch`, `:tag`,
  `:ref`, and `:subdir` from workspace dep opts before merging manifest opts.
- Monolith artifacts are excluded from `hex.publish --dry-run --yes` during
  verification (not a publishable Hex package in the traditional sense).

## [0.1.0] - 2026-04-02

Initial release.

[0.20.0]: https://github.com/nshkrdotcom/weld/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/nshkrdotcom/weld/compare/v0.18.1...v0.19.0
[0.18.1]: https://github.com/nshkrdotcom/weld/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/nshkrdotcom/weld/compare/v0.17.1...v0.18.0
[0.17.1]: https://github.com/nshkrdotcom/weld/compare/v0.17.0...v0.17.1
[0.17.0]: https://github.com/nshkrdotcom/weld/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/nshkrdotcom/weld/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/nshkrdotcom/weld/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/nshkrdotcom/weld/compare/v0.13.1...v0.14.0
[0.13.1]: https://github.com/nshkrdotcom/weld/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/nshkrdotcom/weld/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/nshkrdotcom/weld/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/nshkrdotcom/weld/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/nshkrdotcom/weld/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/nshkrdotcom/weld/compare/v0.8.4...v0.9.0
[0.8.4]: https://github.com/nshkrdotcom/weld/compare/v0.8.3...v0.8.4
[0.8.3]: https://github.com/nshkrdotcom/weld/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/nshkrdotcom/weld/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/nshkrdotcom/weld/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/nshkrdotcom/weld/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/nshkrdotcom/weld/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/nshkrdotcom/weld/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/nshkrdotcom/weld/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/nshkrdotcom/weld/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/nshkrdotcom/weld/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/nshkrdotcom/weld/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/nshkrdotcom/weld/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/nshkrdotcom/weld/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/nshkrdotcom/weld/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/nshkrdotcom/weld/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/nshkrdotcom/weld/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nshkrdotcom/weld/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/weld/releases/tag/v0.1.0
