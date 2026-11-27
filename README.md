<p align="center">
  <img src="assets/weld.svg" alt="Weld logo" width="200" />
</p>

<h1 align="center">Weld</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/weld"><img src="https://img.shields.io/badge/github-nshkrdotcom/weld-8da0cb?style=flat&logo=github" alt="GitHub" /></a>
  <a href="https://github.com/nshkrdotcom/weld/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-4c9f70.svg" alt="MIT License" /></a>
</p>

Weld is an artifact compiler for Elixir workspaces. It resolves explicitly declared Mix projects, plans standalone artifacts, materializes development views, qualifies detached copies, and prepares immutable release bundles. Downstream consumers use ordinary Mix and do not install Weld.

## Install

These examples target Weld 0.20.3. Resolve the Hex dependency after publication.

```elixir
{:weld, "~> 0.20.3", only: [:dev, :test], runtime: false}
```

## Start here

The 0.20 series introduced a breaking release in 0.20.0. Weld 0.20.3 retains that contract, including the 0.20.1 public Hex dependency and invalid-plan fixes and the 0.20.2 signed candidate-registry support, while reducing redundant inventory and qualification work. Use schema 2 manifests and the single `mix weld` command. Prior manifest schemas, dotted commands, and prior state formats are not supported.

```bash
mix weld setup
mix weld plan --artifact weld
mix weld project --artifact weld --kind full
mix weld verify --artifact weld
mix weld prepare --artifact weld
mix weld status --artifact weld
mix weld path --artifact weld --kind bundle
```

`setup` initializes managed state in `.weld/v2/` and the checkout ignore rule. Commit the ignore rule before preparing a release. The default manifest is `build_support/weld.exs` at the Git root; use `--manifest PATH` for another manifest or `--root PATH` outside Git. Relative manifest paths resolve from the invocation directory. Manifests and source Mix projects are trusted executable code; isolated probes protect host Mix state but are not a sandbox. Workspace facts include separate bounded dev, test and prod observations, shared across all artifacts in the command. Environment-dependent dependencies retain their scopes; unsupported changes to project identity or native package/compiler/application semantics fail explicitly.

Three layouts share a semantic plan: `:components` embeds selected workspace components, `:flat` merges their sources into a single project, and `:preserve` copies a declared existing project. Full projects are detached regular-file copies; live views link source for development and are not releasable. Qualification operates on a separate copy. A prepared bundle includes the qualified project, documentation and, when enabled, the exact package archive. Git tracking, staging and publication are distinct operations. Never publish from a mutable development project.

Ordinary public Hex dependencies may use the Mix shorthand or explicitly name the same package and `hexpm` repository. Remote Git dependencies are supported for non-Hex artifacts. Local filesystem Git dependencies need a canonical remote Git or Hex replacement in generated layouts, or a native declaration change in preserve. Selected internal path dependencies continue to follow the chosen layout's ownership rules.

Use `mix weld release-plan` for dependency order and `mix weld affected --base HEAD~1 --head HEAD --task package` to compare genuine Git trees. Batch commands share workspace facts and return per-artifact diagnostics. Later release operations require a full bundle identity or an explicit `--current`; historical pinned bundles can be read with `--root --artifact --identity` after a manifest changes. `--format json` emits one versioned envelope on stdout, with progress on stderr.

See [getting started](guides/getting_started.md), the [manifest reference](guides/manifest_reference.md), [CLI reference](guides/cli_reference.md), [architecture](guides/architecture.md), and [release process](guides/release_process.md).

## What 0.20 changes

| Area | Current contract |
| --- | --- |
| Source selection | Explicit schema 2 project globs and typed extra/native inputs; actual and publication graphs keep aliases, optional features and dependency scopes. |
| Planning | One pure compiler consumes shared observations and produces exact targets, provenance, role membership, missing-input watches, normalized `{:i, charlist}` Erlang include descriptors and full/live variants. |
| Generated projects | Components and flat share Mix/OTP/config renderers with manifest-only `package.links`; flat preserves `Application.app_dir/2` on the surviving `package.otp_app` while rejecting absorbed component app identities; preserve keeps native callbacks and Hex `Makefile*` defaults. Installed bootstrap, assets and native inputs remain usable without the source checkout. |
| Development views | Ordinary code may stay linked in live views. Mutable runtime/config/native inputs are copied, structural changes require refresh, and cache hits validate the complete expected output. |
| Qualification | G01–G12 resolve and freeze the standalone lock, compare real source/artifact test identities, inspect exact package/docs archives and install the package through ordinary signed Hex consumption. An explicit signed loopback registry can supply unpublished dependencies without altering published dependency declarations. |
| Release evidence | Canonical domain-separated identities, strict immutable bundle records and full identity pins replace embedded reports and permissive legacy receipts. |
| State and Git | Explicit setup, owned state, resource leases, short metadata transitions and recovery protect source and previous pointers. Annotated receipts, ref CAS and atomic push protect tracked projections. |
| Publication | Uploads use frozen bytes with independent package/docs outcomes. Reconciliation queries remote evidence after uncertain sends; stage and dry run do not publish. |

No automatic state migration or old-task compatibility is provided. Read the
[changelog](CHANGELOG.md) for the full change since 0.19.0, including the 0.20.3 efficiency changes, and the
[workflow](guides/workflow.md) for setup, refresh, failure recovery and GC.

## Pinned release operations

After a successful clean-source prepare, use the full identity printed by
prepare/status. Each `stage` makes an independent review copy.

```bash
mix weld release-plan
mix weld status --artifact weld --format json
mix weld stage --artifact weld --identity FULL_BUNDLE_ID
mix weld track --artifact weld --identity FULL_BUNDLE_ID --tag-release
mix weld publish --artifact weld --identity FULL_BUNDLE_ID --dry-run
mix weld archive --artifact weld --identity FULL_BUNDLE_ID
```

An explicit `--reuse PUBLIC_CONTEXT` requests proof reuse only when a locked
preserve artifact, compiler/toolchain/trust context and intact sealed evidence
match; otherwise preparation qualifies again. `--fresh` forces qualification.
Source version tags and projection receipt tags have different purposes. An
archive or Git tag does not establish remote publication.

**Public writes remain disabled pending authenticated adapter conformance.**
The public API's unsupported staged-absence and exact docs-archive readback
representations remain unknown. Local loopback and authorized sandbox drivers
exercise the pinned byte boundary; they do not enable production publication.
See the [release process](guides/release_process.md) and
[consumer integration](guides/consumer_repo_integration.md) for the supported
trust and detached-consumption contracts.

## Maintainer quality gates

Run `mix ci` once for the [repository validation gates](guides/testing_strategy.md#required-repository-gates).
It includes the detached four-layout/native consumer matrix; do not repeat that
matrix when the same run already supplies its results. Qualify actual ecosystem
consumers when changing their release integration. `mix test` runs the fast source checks; `mix test --include slow`
adds the slower source cases. `mix ci` runs both tiers and all isolated
integration lanes, including fault, signed Hex consumer and probe-timeout
checks. Blitz 0.5.0 schedules the isolated jobs against available CPU and
memory resources without Weld-specific worker counts. [Testing strategy](guides/testing_strategy.md) and the QC driver
section there document exact commands, browser evidence,
canonical proof, crash/concurrency, representative measurements and the final
manual synthetic soak. The acceptance and disposition ledgers live in
[guides/qc](guides/qc/acceptance.md).

Release QC records the results for the exact source revision tested. See the
testing strategy for the required gates and how to collect evidence.

License: MIT.
