# Testing Strategy

`Weld` needs both fast internal tests and generated-artifact integration tests.

## Repo Test Layers

## Unit And Planner Coverage

These tests cover:

- manifest normalization
- workspace discovery
- project loading
- graph traversal
- artifact planning
- affected-file analysis

## Generated Artifact Integration

These tests cover:

- projecting a standalone Mix artifact (package-projection and monolith modes)
- compiling the artifact
- running welded artifact tests
- building docs
- building the Hex tarball when `verify.hex_build` is enabled
- preparing and tracking bundles for internal-only artifacts even when no
  tarball is present
- running `mix hex.publish --dry-run --yes` when `verify.hex_publish` is enabled
  in package-projection mode
- compiling the smoke app when configured (package-projection mode)
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

The generated package is intentionally tested as a standalone package, not as a
full mirror of every source-project test tree.

That means:

- source-repo tests remain the place for the full source-level suite
- welded artifact tests remain the place for package-level correctness

## Verification Goal

The target is not just "projection succeeded". The target is:

- the artifact is structurally correct
- the artifact is testable
- the artifact is buildable
- the artifact is trackable and archivable even when it is intentionally not
  Hex-buildable
- the artifact is publishable when Hex verification is enabled
