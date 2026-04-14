# AGENTS.md

This file defines the working contract for `/home/home/p/g/n/weld`.

## Purpose

`weld` is the publication and projection tool for Elixir monorepos.

It is not an application workspace. The repo owns the Weld library, Mix tasks,
guides, and fixture-backed verification surface for package projection,
verification, release preparation, projection tracking, and archive creation.

## Repository Shape

The current layout is:

```text
weld/
  lib/           # Weld library code and Mix tasks
  test/          # fixture-backed tests and support helpers
  guides/        # user-facing guides and reference docs
  assets/        # docs/logo assets
  priv/          # persistent tool data such as PLTs
```

Important subtrees:

- `lib/weld/` for core planner, projector, verifier, release, git, graph, and workspace code
- `lib/mix/tasks/` for the public CLI surface
- `test/weld/` for direct unit/integration coverage
- `test/fixtures/` for projection and release fixture repos
- `test/support/` for reusable fixture/test helpers
- `guides/` for durable user-facing documentation

## Operating Rules

- Keep `weld` focused on generic publication/projection behavior. Do not add
  repo-specific consumer hacks here.
- Prefer fixture-backed tests when changing projection, verification, or git
  behavior. Validate real generated output instead of only unit-level mocks.
- Treat the public Mix tasks and manifest shape as the product surface. Changes
  to behavior or defaults must be reflected in guides and changelog entries.
- Keep generated output examples and wording aligned with the current package
  projection and monolith semantics.
- Do not weaken verification behavior to make a consumer pass. Fix the
  projection or manifest model instead.

## Documentation Homes

- `README.md` is the front door
- `guides/` holds durable usage, workflow, architecture, and reference material
- `CHANGELOG.md` records release-visible changes

If a change affects how consumers integrate or publish with Weld, update the
relevant guide in the same change.

## Required Validation Workflow

Run these from the repo root:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix test
MIX_ENV=test mix credo --strict
mix dialyzer
mix docs --warnings-as-errors
mix ci
```

`mix ci` is the acceptance gate. If it fails, the repo is not done.

## Working Style

- Prefer TDD/RGR when changing projection or release behavior.
- Add or extend fixture coverage first when touching manifest resolution,
  output layout, dependency canonicalization, or git tracking.
- Keep guides and examples synchronized with the implemented behavior.
- Keep commit surfaces tight. This repo is infrastructure, so incidental churn
  in docs, fixtures, and task output should be deliberate and coherent.

## Common Pitfalls

- Do not couple `weld` to one consumer repo's local path layout.
- Do not assume package projection and monolith mode can share the same fix.
- Do not update release flow behavior without also checking projection-branch
  semantics and prepared bundle behavior.
- Do not rely on one fixture when the behavior is mode-specific; add or update
  the correct fixture for the scenario.
