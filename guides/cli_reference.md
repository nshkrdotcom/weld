# CLI reference

Weld 0.20.1 has one public task: `mix weld COMMAND`. Run `mix weld`, `mix weld help`, or `mix weld help COMMAND` for help generated from the same registry that validates requests. Help does not discover projects or initialize state.

## Discovery and selection

The default manifest is `build_support/weld.exs` at the Git checkout root. From a nested directory, Weld still uses that checkout root. For a directory outside Git, supply `--root PATH`, or explicitly select a manifest with `--manifest PATH`. Relative manifest overrides resolve against the invocation directory; `workspace.root` resolves against the manifest directory. When both overrides are supplied they must identify the same checkout. A nested `workspace.root` limits discovery; project IDs and artifact/global input paths remain relative to the checkout root. In a non-Git directory, `--root` can contain both an outer manifest and its nested discovery area.

```bash
mix weld plan --root /work/sdk --artifact sdk
mix weld plan --manifest ../../build_support/weld.exs --artifact sdk
mix weld graph --view package --format dot
mix weld graph --artifact sdk --view test --format json
mix weld query deps core/sdk --view compile
mix weld query why apps/console core/sdk --view package
```

`--artifact NAME` and `--all` are exclusive. A command needing one artifact auto-selects only when the manifest defines exactly one. Status, affected, and release-plan default to all applicable artifacts. Graph and query operate on the workspace without requiring an artifact; `--artifact` adds its boundary overlay.

All options are validated before workspace evaluation. Unknown options, duplicates, invalid formats, unexpected positional arguments, unsafe identifiers, and unsupported combinations fail. The public request API is:

```elixir
request = %{
  command: "plan",
  arguments: [],
  options: [manifest: "build_support/weld.exs", artifact: "sdk", format: "json"]
}

Weld.run(request)
# {:ok, data} or {:error, diagnostics}
```

The API returns values; the Mix adapter renders them. `Weld.version/0` reports the tool version. Internal compiler and shell modules are not a stable public API.

## Command registry

Common flags are `--manifest PATH`, `--root PATH`, `--format text|json`, `--verbose`, and `--help`. Artifact and batch flags apply only as listed below. Graph additionally accepts `--format dot`.

| Command | Arguments and additional flags | Result |
| --- | --- | --- |
| `setup` | Root/manifest selection | Initializes `.weld/v2/`, ensures the source ignore rule, and reports whether `.gitignore` changed. |
| `plan` | `--artifact NAME` or `--all` | Compiled layout, plan/input IDs, membership, dependency boundaries, provenance, inventories and diagnostics. |
| `graph` | Optional `--artifact NAME`, `--view VIEW` | Workspace dependency graph with optional artifact boundary overlay. |
| `query deps PROJECT` | Optional artifact, `--view VIEW` | Direct dependencies, transitive paths, external requirements and membership. |
| `query why FROM TO` | Optional artifact, `--view VIEW` | Deterministic shortest actual and artifact paths plus externalized edges. |
| `affected` | `--base REF --head REF --task TASK`, optional artifact or `--all` | Exact/conservative comparison of both Git trees, including added and removed artifacts. |
| `project` | Artifact or `--all`, `--kind full|live`, `--fresh` | Development output; full is the default. Does not qualify a release. |
| `verify` | Artifact or `--all`, `--fresh`, `--context VALUE` | Isolated verification run without changing CURRENT. |
| `prepare` | Artifact or `--all`, `--fresh`, `--context VALUE`, `--reuse CONTEXT` | Clean committed qualified bundle and atomic CURRENT activation. |
| `status` | Optional artifact or `--all`, `--identity ID`, `--remote` | Read-only integrity, freshness, refs, outcomes and next command. |
| `diff` | Optional artifact, `--kind full|live|bundle` (default `full`), `--identity ID` for bundle | Planned targets versus observed bytes/modes/links, including missing and unexpected entries. |
| `path` | Optional artifact, `--kind full|live|bundle|docs|archive|run` (default `full`), `--identity ID`, `--run ID` | Exact local path and presence state. Text output is the path alone. |
| `doctor` | Optional root/manifest | Toolchain, declarations, managed-state safety and owner/lease diagnostics. No `--fix`. |
| `docs-check DIR` | Directory positional argument | Static documentation/Mermaid diagnostics; does not execute JavaScript. |
| `lint` | `--root PATH` | Runtime OS-environment policy check; no dependency-source policy. |
| `release-plan` | `--all` (inherent), `--no-check` | Dependency-first publication order, sibling aliases and version constraints. |
| `track` | Pin, `--tag NAME` or `--tag-release`, `--push`, `--remote NAME`, `--branch NAME` | Optional projection branch and annotated receipt; default remote `origin`, branch `projection/PACKAGE`. |
| `verify-tag TAG` | `--artifact NAME`, `--identity ID`, `--tarball PATH` | Annotated receipt/commit/tree verification, optionally against exact local tar bytes. |
| `stage` | Pin | A new writable review run for every invocation. |
| `publish` | Pin, `--tag TAG`, `--dry-run`, `--yes`, `--allow-source-drift` | Verified frozen archives only; exact-byte transport conformance is required for writes. |
| `reconcile` | `--identity ID`, optional artifact when unambiguous | Remote observation and durable outcome classification; never uploads. |
| `archive` | Pin; `--all` only with `--current` | Exact immutable bundle copy with separate local archival state. |
| `gc` | `--keep N` (default 2, `>= 0`), `--dry-run`, `--apply` (exclusive) | Deterministic completed-run pruning. Without `--apply`, it is read-only. |
| `recover` | `--root PATH`, optional `--lease ID` | Inspect interrupted records, or explicitly recover the selected owner only if proved dead. |

A **pin** is `--identity ID` or `--current`. IDs are complete 64-character lowercase hexadecimal digests; prefixes are rejected. `--artifact`, `--run`, and `--lease` identifiers must match `[A-Za-z0-9][A-Za-z0-9_.-]*`. `--identity` is exclusive with `--current` and `--all`. `--current` explicitly opts into resolving the current pointer once under the operation's lease.

`--run ID` is required for `path --kind run`, and is invalid with other kinds. Run lookup returns the run directory. For a stage review, its `project/` subdirectory contains the review copy. Bundle identities apply to bundle/docs/archive paths, not development outputs or run lookup. `path --kind archive` locates the archived bundle directory, not an unqualified newly built tarball.

## Views, contexts, and batches

Graph views are `runtime`, `compile`, `package`, `smoke`, `docs`, `test`, and `all`; `tooling` and `dev` expose the corresponding development relationships. Package/compile/smoke include runtime and compile edges; docs adds docs edges; test adds test and dev-only edges. External cuts apply across every view. A declaration with mixed docs and test/dev scopes retains a union of those kinds, so it is visible in each relevant view and excluded from the package/runtime closure.

Affected task names are exactly `verify`, `package`, `docs`, `project`, and `release`. Weld materializes genuine base/head Git trees in disposable directories, shares their facts across artifacts, and never treats a missing manifest, missing revision or unsupported entry as evidence of no effect. Changes include old/new paths and modes. Invalid revisions are argument errors; unavailable manifest/project facts produce conservative affected/unknown results. The release view also marks source revision movement, with separate `content_changed` and `source_revision_changed` fields. Reports distinguish proven additions/removals from conservative unknown results. Opaque external source inputs report affected/unknown even when Git content is unchanged.

```bash
mix weld affected --base HEAD~1 --head HEAD --task package --format json
mix weld release-plan --no-check --format json
mix weld prepare --artifact sdk --context linux-public
mix weld prepare --artifact sdk --reuse linux-public
```

`--reuse CONTEXT` implies the same context. If `--context` is also supplied, it must match. `--fresh` and `--reuse` conflict. Supplying context without reuse still performs qualification. Reuse eligibility includes complete nonopaque inputs, locked dependencies, toolchain/trust coordinates and intact sealed evidence; an ineligible proof runs qualification, while a corrupt bundle fails closed.

Plan, project, verify and prepare batches share one captured workspace value. Each discovered project is observed once in each of dev, test and prod; at most four fresh metadata VMs run concurrently. Production is always observed to detect branches hidden from dev/test. Invalid single-artifact plans report the underlying plan violations without attempting to serialize a missing layout. Independent artifact failures in a batch are reported in deterministic artifact order. If source observations change during a writing batch, remaining writes stop. Release-plan orders actual compiled publication dependencies; it does not schedule publication. `--no-check` permits reporting unsatisfied version constraints, but still rejects invalid plans, duplicate package identities and cycles.

## Historical bundles and recovery

A pinned stored bundle can be inspected or operated on independently of the current manifest. Supply `--root`, `--artifact`, and `--identity`; tracking, staging, archive, status and tag evidence do not require the old artifact to remain in the current manifest. Publication separately checks source freshness and its acknowledgement policy.

```bash
mix weld status --root /work/sdk --artifact sdk --format json
mix weld path --root /work/sdk --artifact sdk --kind bundle
mix weld stage --root /work/sdk --artifact sdk --current
mix weld recover --root /work/sdk
```

Use the full identity printed by prepare/status for automation. A status result recommends an appropriately quoted command. `recover --lease ID` is explicit selection of a recorded stale operation; Weld rejects active or unknown liveness. With no lease, recover only reports. Remote ambiguity belongs to `reconcile`, not local recovery. Neither command silently resubmits publication.

## Output and exit status

JSON stdout contains exactly one UTF-8 envelope:

```json
{"command":"plan","data":null,"diagnostics":[],"ok":true,"schema":"weld.result/2"}
```

The empty data above illustrates the envelope, not a real plan. Object keys have deterministic ordering; lists have stable semantic order. Progress, trusted source logs and verbose timing go to stderr. Secret-bearing URLs and credential fields are sanitized at shell boundaries. A failure still emits its JSON envelope before exiting.

Each diagnostic has `code`, `severity`, `phase`, nullable `artifact`, `project`, `source` and `target`, `message`, nullable `hint`, and bounded typed `details`. Schema errors include their declaration path and allowed keys. `--verbose` adds sanitized exception/subprocess context and timing; it does not change the result schema.

| Exit | Meaning |
| --- | --- |
| 0 | Success; read-only status can report unprepared/stale state, and affected can report no changes. |
| 2 | Invalid arguments, manifest/schema, plan or dependency cycle. |
| 3 | Effect, verification, integrity, or doctor error. |
| 4 | Unresolved external publication outcome or conflict. |
| 5 | A batch has per-artifact failures. |

Doctor warnings alone return 0. `release-plan --no-check` returns 0 for unsatisfied constraints and 2 for invalid plans or cycles. Old task aliases, old flags, old manifest keys and old state/receipt readers are absent.
