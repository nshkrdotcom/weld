# Weld 0.20.0 acceptance and evidence

This ledger maps the complete Part 2 acceptance contract to the current source.
The original editing environment
had no Elixir, Erlang or Mix. Runtime QC records execution results separately,
with the exact source commit and command exit status for each run.

## Source and test disposition

The comparison baseline is `7897ba6457d3ba725ee3a843bc863f2c38e90411`; the
completion checkpoint is `0ff6f9ef7a66048abaf00f4f24e5464ca2d90c37`. Version stays
0.20.0 and changelog date stays 2026-11-26. Historical checkpoint passes do not
qualify the completed source.

- `baseline-test-paths.tsv` records all 161 retained baseline test paths.
- `baseline-test-disposition.tsv` maps all 171 baseline lexical declarations to
  current coverage and explains changed schema/command assertions. Seven rows
  are shell `test` statements inside a fixture, not independent ExUnit tests.
- `module-disposition.tsv` maps all 71 baseline implementation files to current
  ownership and distinguishes removals already present at the checkpoint.
- `command-disposition.tsv` maps all 30 old task names to the unified command
  registry. Only `lib/mix/tasks/weld.ex` is a public task; no aliases are restored.

The current code also adds literal-fact pure tests, schema/environment/scope
contracts, inventory and source watch adversaries, exact archive/HTTP tests,
independent OS-process concurrency, recovery, semantic proof tampering and
native signed-registry consumption. Test names are retained where behavior is
retained; obsolete embedded-report and rebuild-handoff expectations are replaced
by explicit schema 2 contracts, not by relaxed success conditions.

Runtime QC updated assertions for schema 2. Live guard tests require the quoted
refresh command and the rejection specific to each Hex command. The native artifact plan checks
unique target membership through `output_inventory` and separately checks
`mix.exs` source provenance. The mutable graph destination test expects the
source-inventory rejection for `doc`, which is excluded from observations, and
retains the output-overlap assertion for `mix.lock`. Both cases still verify that
source bytes survive rejection. Run lookup tests check the run directory and
the location of its staged project.

## A01–A40 coverage

All paths in the test column ending in `_test` are under `test/weld/` with the
`.exs` suffix. Code names are Weld modules unless a script is named. Consult the runtime QC index for execution status. A36 additionally requires the
actual external checkouts and toolchains. A37 requires runtime measurements in
addition to static accounting.

| ID | Required behavior | Implementation | Tests / reproducible evidence source |
| --- | --- | --- | --- |
| A01 | Read-only commands, CWD, JSON and pre-effect validation | `CLI; Commands; Output; Shell.GC` | `cli_subprocess_v2_test; cli_v2_contract_test; ergonomics_contract_test; mix_tasks_test` |
| A02 | Closed schema, explicit root/globs and duplicate identities | `Core.Manifest; Manifest; Workspace.Discovery` | `schema_v2_contract_test; workspace_snapshot_v2_test; manifest_test; workspace_test; nested_workspace_coordinates_test` |
| A03 | Isolated bounded environment/helper probes | `Workspace.Probe; Workspace; Shell.Runner; Shell.Snapshot` | `workspace_snapshot_v2_test; workspace_test; source_project_test; runner_contract_test` |
| A04 | One batch facts value and deterministic ordering | `Commands.batch; Workspace; Core.Compiler; Core.ReleaseOrder` | `workspace_snapshot_v2_test; artifact_plan_test; release_plan_test; cli_v2_contract_test` |
| A05 | Literal pure compilation, graph views and topology | `Core.Compiler; Core.Facts; Core.Selection; Graph; Graph.View` | `core_compiler_test; core_facts_test; graph_scope_v2_test; graph_live_test; plan_test` |
| A06 | One common inventory and three policies | `Plan.Inventory; Layout.Components; Layout.Flat; Layout.Preserve; Layout.Render` | `artifact_plan_test; monolith_plan_test; projector_package_mode_test; core_compiler_test` |
| A07 | Aliases, requirements, boundaries, all scopes and cycles | `Graph; Plan.Boundary; Core.Selection; Core.ReleaseOrder` | `graph_scope_v2_test; git_dependency_portability_test; plan_test; release_plan_test; artifact_plan_test; workspace_snapshot_v2_test` |
| A08 | Compiler ownership separate from dependency membership | `Plan.Inventory; Core.Selection; Plan.Boundary` | `artifact_plan_test; source_consumption_test; plan_test` |
| A09 | Exact full/live targets, native callbacks and detached behavior | `Shell.Materializer; Shell.Native; Layout.Preserve; Layout.Live` | `source_project_test; projector_monolith_test; graph_live_test; source_consumption_test; scripts/qc/qualify_layouts.exs` |
| A10 | Native sources, pins, modes, missing paths and installed build | `Core.Inputs; Plan.Inventory; Shell.Snapshot; Shell.Hex; SmokeApp` | `core_facts_test; snapshot_contract_test; verification_integrity_test; hex_consumption_contract_test; test/fixtures/native_hex` |
| A11 | Config companions/imports, lexical scope and installed priv | `Config.Generator; Layout.Render; Shell.Materializer` | `config_generator_test; projector_config_cache_test; bootstrap_relocation_test; projector_package_mode_test` |
| A12 | Flat collisions, deduplication, remaps, migrations and helpers | `Layout.FilePlan; Layout.Flat; Layout.Flat.Migrations; Layout.Flat.TestHelper` | `monolith_plan_test; monolith_config_spike_test; monolith_test_helper_spike_test; core_identity_test` |
| A13 | Exact docs inputs/hooks and bounded static rendering claims | `Layout.Support; DocsPreview; DocsSmoke; Verifier` | `docs_options_test; docs_smoke_test; docs_preview_test; ergonomics_and_docs_smoke_test; scripts/qc/browser_docs.mjs` |
| A14 | Complete provenance, roles, watches and package membership | `Core.Inputs; Plan.Inventory; Core.Inventory; Shell.Hex` | `inventory_contract_test; core_compiler_test; artifact_plan_test; verification_integrity_test; hex_archive_contract_test` |
| A15 | Input-class isolation, cache keys and relevant invalidation | `Plan.Inventory; Shell.Snapshot; Projector; Receipt` | `core_compiler_test; snapshot_contract_test; projector_config_cache_test; projector_test; source_project_test` |
| A16 | Two actual Git trees, old/new contributors and conservative unknown | `Affected; Git; Plan.Inventory` | `affected_test; artifact_plan_test; nested_workspace_coordinates_test` |
| A17 | Semantic diff, modes, planned links and hidden membership | `Shell.Diff; Core.Inventory; Plan.Inventory` | `ergonomics_contract_test; ergonomics_and_docs_smoke_test; monolith_plan_test` |
| A18 | Exact complete cache reuse and live structural refresh | `Projector; Receipt; Shell.Materializer; Layout.Live` | `projector_test; projector_config_cache_test; source_project_test; graph_live_test` |
| A19 | Explicit eligible proof reuse, fresh and corrupt proof refusal | `Release; ReleaseInputs; ReleaseStatus` | `release_test; bundle_integrity_test; scripts/qc/prepare_reuse.exs` |
| A20 | Canonical vectors, schema closure, UTF-8, modes and relocation | `Core.Identity; Plan.Inventory; Core.Inventory` | `core_identity_test; inventory_contract_test; core_compiler_test; bundle_integrity_test` |
| A21 | Independent cache-free identities and strict immutable evidence | `Release; ReleaseStatus; ReleaseReceipt; Shell.Hex` | `release_test; bundle_integrity_test; docs_preview_test; nested_workspace_coordinates_test` |
| A22 | Lock freeze then complete boundary rechecks | `Verifier; Projector.recheck_inputs!; Hash` | `qualification_contract_test; verification_integrity_test; verifier_test; snapshot_contract_test` |
| A23 | Domain separation and operational settings excluded from proof | `Core.Identity; Plan.Inventory; ReleaseInputs` | `core_identity_test; core_compiler_test; inventory_contract_test; qualification_contract_test` |
| A24 | Owned safe paths, special/link refusal and recoverable activation | `Output; Shell.Materializer; Shell.GC` | `output_test; state_safety_test; verification_integrity_test; ergonomics_contract_test` |
| A25 | Detached path/Git/exact Hex consumers, native and bootstrap | `SmokeApp; Shell.Hex; Release; Shell.Native` | `source_consumption_test; bootstrap_relocation_test; smoke_app_test; hex_consumption_contract_test; scripts/qc/qualify_layouts.exs; scripts/qc/installed_weld.exs` |
| A26 | OS-process leases, killed owners, lock bounds and GC races | `Output; Shell.GC; Release; Verifier` | `state_safety_test; output_test; qualification_contract_test; release_workflow_018_test` |
| A27 | Independent source baseline and actual test identities | `Verifier baseline mirror and ExUnit formatter` | `component_tests_test; monolith_test_helper_spike_test; qualification_contract_test; verifier_test` |
| A28 | All gate outcomes, explicit skips and bounded subprocess isolation | `Verifier.gate_specs; Shell.Runner; SmokeApp` | `qualification_contract_test; runner_contract_test; verifier_test; smoke_app_test` |
| A29 | Frozen docs and archive roundtrip; browser proof separate | `DocsPreview; DocsSmoke; Shell.Hex; Verifier` | `docs_preview_test; docs_smoke_test; hex_archive_contract_test; scripts/qc/browser_docs.mjs` |
| A30 | Actual tar inspection, ordinary resolver and HTTP body hashes | `Shell.Hex; SmokeApp; Verifier` | `hex_archive_contract_test; hex_transport_contract_test; hex_consumption_contract_test; scripts/qc/loopback_transport.sh` |
| A31 | Prepare boundaries, immutable pins and valid prior pointer | `Release; ReleaseStatus; Output` | `release_test; state_safety_test; bundle_integrity_test; qualification_contract_test` |
| A32 | Git object proof, annotated receipts, ref CAS and atomic push | `Git; Release; ReleaseReceipt; ReleaseStatus` | `release_workflow_018_test; bundle_integrity_test; scripts/git_ref_contract.py` |
| A33 | Not-sent/unknown/staged/conflict states and query-only reconcile | `Shell.Hex; Release; ReleaseStatus` | `hex_publication_fault_test; hex_transport_contract_test; release_workflow_018_test; scripts/qc/authenticated_conformance.exs` |
| A34 | Tag-only verification and exact idempotent archives | `Git; ReleaseReceipt; ReleaseStatus; Release.archive!` | `bundle_integrity_test; release_workflow_018_test; release_test` |
| A35 | Pure boundary, one renderer/codec and dependency direction | `Core.*; Layout.*; Config.Generator; Shell.*` | `core_compiler_test; scripts/qc/architecture_check.exs; compiled Mix xref commands` |
| A36 | Actual MedEx/Opus/RTC/Fabric consumer qualification | `Generic compiler, native preserve and exact archive harness; no repo-specific hacks` | `External committed producer/consumer checkouts plus scripts/qc/signed_hex_consumer.exs and the ecosystem procedure in the standalone handoff` |
| A37 | Source/dependency counts and real comparable measurements | `scripts/qc/static_check.py; benchmark.py; benchmark_driver.exs` | `Static accounting executed; representative and scaling runtime measurements unrun; final long soak manual after ordinary QC` |
| A38 | Complete registry, quoted recommendations, exits and partial batches | `CLI; Commands; Mix.Tasks.Weld; Error` | `cli_v2_contract_test; cli_subprocess_v2_test; mix_tasks_test; explain_task_test` |
| A39 | Archive/path corruption, secret redaction and bounded effects | `Shell.Hex; Shell.Runner; Output; Hash; Shell.Snapshot` | `hex_archive_contract_test; hex_publication_fault_test; runner_contract_test; state_safety_test; bundle_integrity_test` |
| A40 | Publication dependency order, constraints and no-check behavior | `Core.ReleaseOrder; Graph; Commands.release_plan` | `release_plan_test; graph_scope_v2_test; cli_v2_contract_test` |

## G01–G12 execution and skip policy

`Verifier.verify!/2` owns the sequence for both verify and prepare. `after_gate`
failure injection does not create evidence of execution when a gate was not run.
Only the policy skips listed here are allowed. Failure records keep all gate IDs,
identify the failed gate and mark downstream gates blocked; missing runtime is
never a successful gate or a permitted skip.

| Gate | Executor / evidence | Permitted skip |
| --- | --- | --- |
| G01 | Common materializer; complete planned project membership and source inputs | None |
| G02 | Dev/test `deps.get`, dev/test/prod metadata reprobes; frozen lock/project | None |
| G03 | Independent source mirror suites; actual ExUnit test identity/state list | No selected source suites when component tests are off and layout is not flat |
| G04 | Dependency compile plus project compile with warnings as errors | None |
| G05 | Artifact/native tests and provenance-mapped source identities | None; zero tests accepted only if no candidate test sources exist |
| G06 | One docs build, normalized frozen docs and static Mermaid check | None; browser rendering remains a separate check |
| G07 | Configured ordinary path-consumer smoke | Smoke not configured; flat configured smoke is rejected by schema |
| G08 | One Hex build; exact package metadata/files/modes/checksums/raw tar | `hex_build: false` |
| G09 | Isolated real Hex dry run; captured actual rebuilt bytes equal G08 | Hex disabled or explicit `hex_publish_check: false` |
| G10 | Exact tar through signed ordinary Hex registry; lock/cache digest, compile/start/smoke | Hex disabled only |
| G11 | Frozen docs unchanged; one docs archive and exact unpack roundtrip when Hex enabled | None; archive is null only for non-Hex policy |
| G12 | Final complete project/source/lock/package/docs/gate revalidation | None |

The portable qualification proof binds the source revision, compiler, plan,
project/package/docs IDs, raw archive hashes, resolved lock, explicit public
context, toolchain and registry trust. Timings, local paths, transport tuning,
logs and mutable pointers are operational records outside portable identity.

## Reproducible checks and explicit limitations

Run the full sequence in `AGENTS.md`, the seventeen independent lanes in
`scripts/test_ci.exs`, and the additional architecture/consumer/native/browser/
conformance commands in `guides/testing_strategy.md` and `scripts/qc/README.md`.
`static_check.py` reports source counts, retained paths, pin retention, seven
independent canonical-vector arithmetic checks and conservative lexical checks.
It is not an Elixir parser, compiler, formatter or xref substitute.

The source accounting target is no more than 9,900 production physical lines,
55 implementation files and one public Mix task. Consult `source-metrics.md` for
measured current counts and the documented size exception. Do not minify or move
production logic into QC scripts to alter those numbers. Runtime timing and
memory thresholds are separate pending experiments.

The pinned exact-byte transport and durable outcomes are implemented. The
current public adapter conservatively refuses public writes when it cannot
prove staged absence or authenticate the exact raw docs archive digest. This
is a production capability limit, not a runtime gate that automatically turns
green. The authorized sandbox contract driver reports receiver evidence and
actual adapter reads separately and never enables production publication.

Only the final long synthetic soak is handed to the maintainer after ordinary
QC and any source repairs. A soak result alone does not establish release
readiness. No production upload, real release tag or remote push is authorized
by these instructions.
