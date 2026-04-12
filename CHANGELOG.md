# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
