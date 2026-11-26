# Testing Strategy

`Weld` needs both fast internal tests and generated-artifact integration tests.

## Unit And Planner Coverage

These tests cover:

- manifest normalization
- workspace discovery
- project loading
- graph traversal
- artifact planning
- source membership and artifact-local package boundaries
- affected-file analysis

## Generated Artifact Integration

These tests cover:

- projecting full and live views for `:package_projection`, `:monolith`, and
  `:source_project`, including nested source projects
- compiling the artifact
- starting compiled package and monolith applications after removing the source
  checkout, including private bootstrap config imports and companion files
- using ordinary Mix consumers outside the source checkout
- refreshing live views after structural changes
- running welded artifact tests
- preserving opt-in component tests, helpers, and relative fixtures in
  package-projection verification
- building docs at the canonical `doc/` verification path, including native
  source projects with a different configured ExDoc output
- building the Hex tarball when `verify.hex_build` is enabled
- preparing and tracking bundles for internal-only artifacts even when no
  tarball is present
- running `mix hex.publish --dry-run --yes` when both `verify.hex_build` and
  `verify.hex_publish` are enabled
- compiling the smoke app when configured
- monolith test baseline gate: asserting the merged artifact runs at least as
  many tests as the sum of selected-package baselines
- monolith source-only test support policy: asserting any non-selected support
  projects are explicitly declared when the manifest opts into that contract

## Fixture Strategy

This repo uses two complementary fixture shapes:

- a workspace without a root `mix.exs`
- a workspace with a root `mix.exs` and `blitz_workspace`

That keeps the discovery model honest while still allowing fast tests.

## Source Lane Versus Artifact Lane

Run the full source suite in the original workspace. Use the welded artifact
lane to exercise the generated package as a regular Mix project, including
its own tests and the component suites explicitly selected for verification.
Hex archive tests inspect the actual package allowlist independently.

Component verification requires test roots and test-only compiler roots to be
separate from published runtime roots. An overlap is rejected rather than
including fixtures in the Hex package. Each selected component runs its own
suite and supplies its own test configuration. A project reached only through a
component's test dependency contributes its ordinary compiler roots, includes,
private assets and package dependencies to the verification project. Its own
test paths, helpers, test-only dependencies and private configuration stay in
the source workspace. Its files are excluded from the Hex package. Selected
runtime component configuration follows the generated configuration pipeline.

Monolith mode supports the conventional `lib`, `src`, `include` and
`test/support` compiler roots. It transforms `test/test_helper.exs` once per
selected project. A nested helper may consist solely of a `Code.require_file`
delegation to that canonical helper. Other helper locations or custom compiler
roots fail explicitly; use package projection to preserve independent test
layouts. Live guards digest canonical and delegated helpers.

## Verification Goal

The target is not just "projection succeeded". The target is:

- the artifact is structurally correct
- the artifact is testable
- the artifact is buildable
- the artifact is trackable and archivable even when it is intentionally not
  Hex-buildable
- the artifact is publishable when Hex verification is enabled

The `source_project` fixture compiles the private components and consumes the aggregate, its optional extensions, and linked assets from independent Mix processes. Run the source-transport lane with `MIX_ENV=test mix test --only ci_build:source_consumption test/weld/source_consumption_test.exs`. The local bare Git repository supplies real refs and complete subdirectory checkouts. The distribution lane detaches full, prepared, projection-clone and unpacked archive inputs before making the original path inaccessible.

CI build copies use the system temporary directory. Fixture copies and test
repositories are removed after each test, including failed assertions.
