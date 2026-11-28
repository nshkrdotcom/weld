# AGENTS.md

This repository owns Weld, the maintainer tool that compiles explicit Elixir
workspace declarations into standalone projects and qualified release bundles.
Weld is not an application workspace or a dependency-source selector.

## Source ownership and architecture

Keep one owner per semantic fact:

| Responsibility | Owner |
| --- | --- |
| Closed schema and typed CLI requests | `Core.Manifest`, `Manifest`, `CLI`, `Commands` |
| Filesystem and isolated dev/test/prod Mix observations | `Workspace`, `Workspace.Probe`, `Shell.Snapshot` |
| Graph, selection and final layout decisions | `Graph`, `Core.Compiler`, `Core.Selection`, layout policies |
| Source roles, provenance, targets, watches and portable identities | `Plan.Inventory`, `Core.Inventory`, `Core.Identity` |
| Shared generated Mix, OTP and bootstrap content | `Layout.Render`, `Config.Generator` |
| Planned file operations and exact output validation | `Shell.Materializer` |
| Managed ownership, leases, transitions and recovery | `Output` |
| G01–G12 qualification and frozen bytes | `Verifier`, `Shell.Runner`, `Shell.Hex`, `SmokeApp` |
| Immutable bundle proof, pins, local refs and remote outcomes | `Release`, `ReleaseStatus`, `ReleaseReceipt`, `Git` |

The pure compiler receives explicit facts and returns values. It must not read
files, invoke Mix/Git/processes, inspect OS environment, or call effect modules.
Generated consumer code is data until executed in the consumer. Keep rendering
shared between components and flat; preserve keeps native Mix metadata and uses
the same inventory and executor. Do not reintroduce the old projector/plan cycle,
multiple inventory authorities, duplicate proof readers or generated reports in
published projects.

Runtime application code under `lib/**` must not call direct OS env APIs.
Runtime env reads belong in `config/runtime.exs` or a `Config.Provider`.
The shell takes declared context and explicitly configured tool/transport facts.
The only direct OS reads in Weld's shell runner select the explicit signed
candidate registry URL and public-key path; application runtime configuration
remains subject to the rule above.
No credentials belong in portable records, logs, command examples or fixtures.

## Working rules

- Make generic behavior changes in Weld; keep actual consumer declarations in
  their repositories. No MedEx, Opus, RTC or Fabric special cases in the compiler.
- Keep schema 2, the one `mix weld COMMAND` task and the `Weld.run/2` boundary.
  Do not restore dotted tasks, old manifest/state readers, ETF proof, legacy
  receipts or the rebuild publisher. There is no runtime migration mode.
- Preserve behavioral test intent. Change assertions when a documented schema 2
  contract intentionally changes, and record that disposition. Add narrow
  regression tests for real defects, then verify actual generated output.
- Keep probes bounded and isolated; share one observation per workspace revision
  across a batch. Read-only commands must not initialize state or change source.
- Only explicit `setup` changes the checkout ignore rule. Mutations require v2
  ownership. Keep metadata locks short; do not hash trees, run subprocesses or
  use the network while holding the checkout metadata lock.
- Use active artifact/destination leases, immutable bundles, durable transition
  journals and atomic pinned pointers. Never infer dead ownership from age.
- Full/live developer views are not qualification evidence. Verify and prepare
  use fresh detached runs, frozen locks, exact inventories and all required gates.
- Preserve exact frozen package/docs bytes for publication and archive. Unknown
  remote outcomes need read-only reconciliation; do not blindly retry a send.
- Never weaken a gate to make a consumer pass. Do not use skipped tests, dummy
  successes, invented locks, timings, bundle IDs or runtime results.
- Runtime absence defers execution only. Finish implementable source, fixtures,
  scripts and documentation; state precisely which commands were not run.

## Development and release workflow

```bash
mix weld help
mix weld setup
mix weld plan --all
mix weld project --artifact <name> --kind live
mix weld project --artifact <name> --kind full
mix weld verify --artifact <name>
mix weld release-plan
mix weld prepare --artifact <name>
mix weld status --artifact <name> --format json
mix weld stage --artifact <name> --identity <full-bundle-id>
mix weld track --artifact <name> --identity <full-bundle-id> --tag-release
mix weld verify-tag <tag> --artifact <name> --identity <full-bundle-id>
mix weld publish --artifact <name> --identity <full-bundle-id> --dry-run
mix weld archive --artifact <name> --identity <full-bundle-id>
```

Commit the manifest and setup ignore rule before preparation. `--identity` pins
historical operations independently of the current manifest; use explicit
`--root` when needed. `--current` selects a pointer once. Each stage creates its
own review run. A source version tag on the qualified source commit is separate
from an annotated projection receipt tag. The public Hex write adapter remains
disabled until destination-specific authenticated conformance proves its full
exact-byte contract. No ordinary test, dry run or QC script authorizes production
publication or pushing release refs.

Exercise local tracking and atomic push only in disposable repositories and a
bare local remote. Keep original sibling consumer checkouts unchanged; migrate
and qualify disposable copies. Weld's root Mix project builds its own Hex package
from source; `build_support/weld.exs` also describes native preserve qualification
without duplicating authoritative package metadata.

## Required validation workflow

For documentation-only changes run `git diff --check` and
`mix docs --warnings-as-errors`; spot-check changed commands and links.
For runtime, dependency, task or build changes, run focused affected tests during
repair, then the complete repository gate once:

```bash
mix ci
```

It includes format, compile, all test lanes, strict Credo, Dialyzer and docs;
do not repeat those commands merely to precede CI.

`mix test` excludes `:slow` and `:integration`; use `mix test --only slow`
for the slower source cases or `mix test --include slow` for all source cases.
Use `--max-cases N` to tune ExUnit without changing coverage. Keep tests that
mutate Mix task/project state, OS environment or cwd synchronous.

`mix ci` remains the repository acceptance gate. It runs format, compile,
all 11 isolated test lanes (fast, slow, all four signed archive layouts,
release, release faults, component prepare, source consumption, and remaining
integration contracts), strict Credo, Dialyzer, and docs. `scripts/test_ci.exs`
isolates build paths and delegates advisory CPU/memory admission to Blitz 0.5.0;
no separate Weld worker-count, lexical sharding, or CPU-slot scheduler is
retained. Use `-- --plan` with the standalone runner to inspect lanes without
executing them. A fast pass cannot replace any release gate.

Also run the lightweight architectural and static checks when changing
compiler boundaries, dependencies, or CI scripts:

```bash
mix run scripts/qc/architecture_check.exs
mix xref graph --format cycles --fail-above 0
mix xref graph --format cycles --label compile-connected --fail-above 0
python3 scripts/qc/static_check.py
```

For the four-layout matrix, set `WELD_QC_LAYOUT_OUTPUT` to a new directory when
running `mix ci`; the separate driver is only needed when those results are
missing or affected. Use fresh output directories. Optional manual diagnostics
and release-only drivers (`scripts/git_ref_contract.py`,
`scripts/qc/loopback_transport.sh`, `scripts/qc/prepare_reuse.exs`, browser
docs, authenticated conformance, installed-package qualification, and synthetic
soak benchmarks) are documented in `guides/testing_strategy.md` and
`scripts/qc/README.md`; do not run them automatically on routine edits. The
reference toolchain is Elixir 1.20.5, OTP 29.1.2, Hex 2.7.0 and the resolved
Hex Core 0.21.1 lock entry. Verify the declared `~> 1.18` minimum-version
compatibility explicitly before claiming it on release.

## Documentation and evidence

Update README, affected guides, the current release changelog and ExDoc entries with every
public behavior change. `guides/qc/` holds acceptance/disposition/source accounting;
`scripts/qc/` holds reproducible validation drivers, not production logic moved
out of `lib` to improve a line-count metric. Production size targets are goals,
not permission to remove safety checks; quantify and explain any exception.

Record commands and exit statuses from the current source. Historical checkpoint
observations are historical. A source review, Python check or Git primitive
experiment does not establish compilation, ExUnit, browser or consumer success.
The next runtime-enabled agent repairs failures and reruns affected gates before
handing only the final long soak to the maintainer.
