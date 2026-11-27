# Testing strategy

The source suite and generated artifact suite are independent gates. A plan is
not a build result, a package build is not an installed-consumer result, and
static docs checks do not establish browser rendering. Weld 0.20.0 pairs
isolated ExUnit lanes with reproducible standalone QC drivers across layouts,
native payloads, signed Hex registries and browser rendering.

## Required repository gates

Run from a clean committed checkout on the pinned qualification toolchain:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix test
MIX_ENV=test mix credo --strict
mix dialyzer
mix docs --warnings-as-errors
mix ci
```

For documentation-only changes use `git diff --check` and docs with warnings as
errors. Behavioral changes require the full sequence. If formatting, compilation
or any test fails, repair source and rerun that gate and the dependent gates.
Never report an unexecuted check as passing.

The reference checkpoint toolchain was Elixir 1.20.5, OTP 29.1.2, Hex 2.7.0 and
Hex Core 0.21.1. The project declares Elixir `~> 1.18`; maintainers must also run
the supported minimum-version matrix before claiming compatibility. Preserve the
resolved Hex Core lock entry and capture pass or failure for every required
command on the committed source.

## Independent CI lanes

`scripts/test_ci.exs` retains all fifteen existing lanes and adds two focused
lanes. Each has isolated build output, at most two concurrent fixture-building
jobs, and warnings as errors. The fast lane excludes integration-tagged cases;
a fast pass never stands in for integration acceptance.

| Lane | Scope |
| --- | --- |
| fast | Ordinary unit, schema, CLI, archive, state and helper tests |
| source_consumption | Detached source/path/Git consumption |
| release | Preparation, immutable evidence and release behavior |
| formatter | Actual generated formatting |
| internal | Internal dependency projection |
| package | Generated package qualification |
| runtime | Composed application startup |
| monolith | Flat artifact verification |
| prepare_cli | Actual preparation task |
| monolith_tests | Full/live selected flat test suites |
| package_config | Package config and bootstrap behavior |
| source_docs_output | Native custom docs output |
| component_prepare | Component baseline and artifact tests |
| graph_consumption | Namespaced/live dependency consumption |
| bootstrap_relocation | Installed bootstrap after source relocation |
| qualification_faults | Frozen-input mutation and mandatory gate failures |
| hex_consumption | Signed registry consumption, including native payload |

## Architecture and canonical proof

```bash
MIX_ENV=test mix test test/weld/core_facts_test.exs test/weld/core_compiler_test.exs
MIX_ENV=test mix test test/weld/core_identity_test.exs test/weld/inventory_contract_test.exs
mix run scripts/qc/architecture_check.exs
mix xref graph --format cycles --fail-above 0
mix xref graph --format cycles --label compile-connected --fail-above 0
python scripts/qc/static_check.py
```

Literal-fact compiler tests run without a real source checkout. The architecture
check parses production AST and rejects effects in the pure decision layer,
while treating generated code quotations as data. Xref is a separate compiled
check for both runtime and compile-connected cycles. The Python check records
source metrics, baseline test-path retention and conservative lexical checks;
it does not parse or compile Elixir and cannot replace xref or ExUnit.

Canonical vectors cover exact UTF-8 bytes and digest domains. Adversarial tests
cover duplicate/noncanonical JSON, unknown fields, missing provenance, bad
references, different executable modes, forbidden paths, file/directory and
case-fold collisions, generation cycles and exact package/doc observations.
Two independent cache-free locations must produce equal portable identities
when source and toolchain inputs match; operational timings are compared
separately and never enter proof.

## Projection and change isolation

Exercise components, flat and preserve with root/nested projects, custom compiler
paths where supported, native inputs, declared helper/pin/checksum files,
optional features, canonical Hex aliases and external Git boundaries. Verify
that a single input class changes only relevant artifact decisions: compiled
code, config companion, structural helper, native tree, docs hook, lock, context
and toolchain. Include adds, removals, renames and executable-bit changes.

Cache tests tamper bytes, add unexpected files, remove expected files and change
empty directories. Live tests prove ordinary edits remain visible, copied mutable
inputs require refresh, structural/flat topology changes invalidate, and exact
link-target drift or cycles fail. Source trees remain untouched by detached
verification and compilation.

Flat cases cover code conflicts, equal-byte/mode deduplication with all origins,
stable asset remaps, migration restamps, explicit support sets, surviving
`package.otp_app` `Application.app_dir/2` asset reads after relocation versus
rejected absorbed component app identities, static helper requires and
unsupported AST. Config cases cover lexical scope, companions, known environment
imports, runtime evaluation and installed `priv` bootstrap.

## Runtime qualification and actual consumers

```bash
mix run --no-start scripts/qc/qualify_layouts.exs -- --output /tmp/weld-qc-layouts
bash scripts/qc/loopback_transport.sh
MIX_ENV=test mix test --only ci_build:qualification_faults test/weld/qualification_contract_test.exs
MIX_ENV=test mix test --only ci_build:hex_consumption test/weld/hex_consumption_contract_test.exs
MIX_ENV=test mix test test/weld/state_safety_test.exs test/weld/bundle_integrity_test.exs --trace
python scripts/git_ref_contract.py
```

The layout driver uses all three layouts and a native fixture. It removes the
original fixture checkout before detached consumption, installs the exact
archive through a signed local Hex registry, loads the application and exercises
the configured smoke/native behavior. A path dependency on extracted source
alone does not satisfy G10. Native inputs include a checksum-pinned source/header
and Makefile, with a separate offline rebuild after dependency resolution.

For Weld itself, use `scripts/qc/installed_weld.exs` with the exact sealed Weld
archive, its raw SHA-256 and a fresh output directory outside every Git checkout.
It installs Weld through the signed ordinary registry, starts a new Mix VM,
checks that all Weld modules and sources come from the installed dependency, and
plans/projects/verifies all three layouts with that tool. The driver records
actual lock/cache/code hashes and child results; running the root source VM is
not an installed-tool experiment. See the driver README for the exact command.

Crash/concurrency tests use independent OS processes, killed owners, journal
boundary injection, lock deadlines, pointer rollback and GC races. Git tests use
disposable repositories and a bare local remote, not source release refs.
The Python Git reproducer validates low-level Git behavior only; it cannot
establish that the Elixir adapters passed.

For actual MedEx base, Opus, RTC and Med Fabric, use disposable copies and the
exact manifest/package versions in their coordinated change. Qualify the actual
native provider archive and downstream dependency graph with Weld absent from
the consumer. External checkouts and toolchains are prerequisites; fixture
success alone does not establish ecosystem compatibility. Use the [consumer integration guide](consumer_repo_integration.md) for the
exact archive and signed-registry commands.

## Docs, transport and trust

Build docs once in qualification. Validate static Mermaid listener/theme rules
on nested pages and inspect the exact docs archive against the frozen tree.
Use `scripts/qc/browser_docs.mjs` for browser capture with the documented browser
prerequisites, then review navigation and light/dark rendering. Keep screenshots
and rendered findings separate from `docs-check` output.

Loopback HTTP tests capture actual package/docs request bytes and SHA-256,
including disconnects, rejection, staging, partial outcomes and reconciliation.
The authenticated conformance driver requires explicit approval of a private or
sandbox endpoint and scoped credentials. Public writes stay disabled until that
contract is qualified. Ordinary CI never performs a public production upload.

## Benchmarks and final soak

`scripts/qc/benchmark.py` uses disposable checkouts at explicit revisions. It
records one cold and five warm samples per revision and operation, median/max,
wall time, peak RSS, source probe/subprocess counts, materialization bytes and
cache disk size. Qualification, docs and native timings remain separate from
plan/full/live/cache timings. The driver records actual failures and retains
logs; it does not turn a missing tool into a pass.

```bash
python scripts/qc/benchmark.py --ref 7897ba6457d3ba725ee3a843bc863f2c38e90411 --ref 0ff6f9ef7a66048abaf00f4f24e5464ca2d90c37 --ref HEAD --cases scripts/qc/benchmark-cases.example.json
python scripts/qc/benchmark.py --ref 7897ba6457d3ba725ee3a843bc863f2c38e90411 --ref 0ff6f9ef7a66048abaf00f4f24e5464ca2d90c37 --ref HEAD --synthetic --projects 100 --files 5000 --artifacts 10
```

Fill external case paths with available disposable inputs before running the
representative command. After implementation and ordinary QC, hand only the
final long synthetic soak to the maintainer. Evidence goes under the unique
`.weld/v2/runs/qc/benchmark-*/` directory printed by the driver. The fixture has
100 projects, 5,000 project files, 10 artifacts and mixed dependency scopes.
Run smaller sizes as well to assess scaling. Compare on the same idle machine
and toolchain, and explain regressions instead of inferring statistical certainty
from six samples. A soak pass is not release readiness.
