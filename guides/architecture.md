# Architecture

Weld is a maintainer-only artifact compiler for trusted Elixir repositories.
The source checkout owns code and native Mix semantics. A compiler inventory
owns selection and source-to-output mapping. A sealed bundle owns qualified
release bytes. A pointer, cache record, Git tag or remote status is evidence
about those objects; none defines a second artifact.

## Dependency direction

`Manifest.load!` evaluates the explicit manifest, then `Core.Manifest` validates
its closed schema. `Workspace.Discovery` expands only declared globs.
`Shell.Snapshot` reads bounded file observations, and `Workspace.Probe` gathers
isolated dev/test/prod Mix facts. `Graph.build` and `Core.Compiler.compile!` consume
those values. They never probe a project or create an output directory.

`Plan` coordinates observation and compilation. `Core.Selection` and
`Plan.Boundary` choose dependency, compilation, verification and inventory
members independently. `Plan.Inventory` turns the finalized layout into the
closed `weld.inventory/2` record. `Core.Inventory` validates destinations and
provides comparison and provenance primitives. Layout policies use explicit
`Core.Facts`; a missing fact fails instead of triggering a filesystem read.
Absolute names in the shell facts are locators, excluded from portable records.
All path expansion in the pure transforms uses an explicit base.

`Shell.Materializer` executes approved operations and verifies the exact result.
`Projector` reserves a lease and activates a full or live view. `Verifier` uses
the same executor in a fresh run, then supplies observed qualification evidence
to `Release`. `ReleaseStatus` is the strict bundle reader for every later stage.
`Git`, `Shell.Hex`, `Shell.Runner` and `Output` own their narrow effect boundaries.

| Fact | Authority | Consumers |
| --- | --- | --- |
| Manifest defaults, options, roles and constraints | `Core.Manifest` | Workspace, compiler, CLI |
| Native metadata and dev/test/prod dependency declarations | Isolated `Workspace.Probe` | Graph, preserve, qualification |
| Bytes, modes, missing paths and topology | `Shell.Snapshot` facts | Pure layouts, inventory, rechecks |
| Dependency edges and view semantics | `Graph` | Selection, query, release order |
| Final mapping, generation inputs and publication flags | `Plan.Inventory` | Materializer, cache, diff, affected, verifier |
| Generated Mix, application and bootstrap content | `Layout.Render` and `Config.Generator` | Components and flat policies |
| Canonical encoding and digest domains | `Core.Identity` | All proof and cache writers/readers |
| Resolved lock and gate results | `Verifier` | Immutable qualification evidence |
| Sealed inventory, project, docs and archives | Strict bundle validation | Track, stage, publish, archive |
| Active operations and durable transitions | `Output` leases, runs and journals | Recovery and GC |
| Publication outcome | Trustworthy remote observations | Publish, reconcile, status |

## Three policies, one executor

**Components** retains namespaced compiler paths under `components/<project>/`.
Root project `.` maps to `components/root/`. Selected applications are composed
in dependency order. Verification-only helpers do not become published runtime
members. Additional native inputs are declared explicitly, including Makefiles,
headers, pins and checksum files.

**Flat** merges compiler roots, maps selected suites and support into stable
paths, and records every remap. Equal bytes and normalized executable modes
may deduplicate with multiple origins. Conflicting code, module names, include
files, slugs or file/directory destinations fail before activation. Eligible
non-code assets can receive a deterministic owner prefix. Private asset
collisions fail. Migration restamps and Repo/config overlays share one mapping.
The declared test-support set must match discovered support exactly. Because
absorbed component OTP apps do not exist at runtime, flat validation allows
`Application.app_dir/2` for the surviving `package.otp_app` (resolved against
merged `priv/`) while rejecting `Application.app_dir/2` for absorbed component
apps and rejecting `Application.app_dir/1` and `Application.ensure_all_started/1,2`
across selected and included test-support projects. The scan uses the projected
source/test membership, not dormant test directories.

**Preserve** copies a disjoint, explicit inventory around one native Mix project.
Its full `mix.exs`, application callback, package metadata and dependencies remain
source-owned. A fresh process validates each staged project/environment — comparing
effective identity, dependencies, normalized compiler options and observed package
fields per environment — so competing Mix module names cannot contaminate another
probe. Explicit Erlang include paths must be covered by the detached inventory;
relative and checkout-rooted includes remain distinct in portable evidence.
Missing helpers or escaping compiler and mutable paths fail. Unsupported
live Mix AST shapes fail with a full-view alternative; full projection does not
require a live transform.

All policies produce the same operation form: copy, generated write, proven
deduplication, and an explicit live link variant. The executor cannot select
another source, render a new template, change a collision rule or expand a new
package allowlist. Full output contains regular files and directories only.
Exact validation includes executable modes, unexpected files and empty dirs.

## Inventory and identity

The portable inventory contains normalized metadata, context, compiler identity,
selection reasons, external dependencies, typed inputs and watches, full/live
entries, layout mappings, qualification policy and the standalone lock slot.
Qualification fills the observed project, package and docs sets in that same
record. Every generated variant refers to its recipe, version and input IDs.

Input roles are nonexclusive: `compile`, `runtime`, `native`, `test`, `docs`,
`metadata`, `lock`, `generation`, `structure`, `verification`. File facts bind
path, bytes, size and executable mode. Portable regular file modes are 0644
or 0755. Absence facts bind missing inputs. Tree/glob facts bind membership,
types, normalized file modes and directory modes, including missing/default
directories.
External facts bind declared public context or are explicitly opaque. Generated
facts bind recipe inputs. Typed declarations retain their complete role set.

Canonical JSON has sorted UTF-8 object keys, explicit arrays and integers, and
no floats or implicit atom conversion. Readers reject unknown/missing fields,
noncanonical bytes, invalid references, generation cycles and inconsistent
modes. Identity is SHA-256 of `weld/2/<domain>\n` followed by canonical bytes.
Raw archive hashes remain SHA-256 of the actual archive bytes.

| Identity | Meaning |
| --- | --- |
| `input_id` | Relevant source facts, watches, metadata, context and compiler |
| `plan_id` | Artifact selection, exact output variants and qualification policy |
| `project_id` | Exact frozen regular files, executable bits and empty directories |
| `package_id` | Actual package entries and normalized package metadata |
| `docs_id` | Exact frozen documentation tree |
| `qualification_id` | Gate results, source revision, lock, toolchain and trust |
| `bundle_id` | Cross-bound immutable descriptor and payload descriptors |
| Projection/work cache IDs | Local optimization keys; never release proof |

Checkout paths, transient run names, transport settings and timings are not
portable identity inputs; checkout-relative `{:i, charlist}` Erlang include
options are normalized into portable relative descriptors. Live link locators
have a separate local cache digest. A changed source commit can change
qualification even when project bytes agree. The canonical vectors and
relocation tests define the executable contract.

## Live views, cache and affected

Live directory groups are permitted only for wholly eligible ordinary source.
Structural helpers, native mutable roots, config, locks, transformed bytes and
deduplicated sources are copied or generated. A self-contained Mix guard checks
structural fingerprints, discovery slots, topology where needed and exact link
targets. Ordinary edits inside an eligible linked directory remain visible;
flat additions/removals and structural edits require refresh. Every live view
blocks package build and publish.

Projection receipts and ownership records live outside generated projects.
A cache hit validates the complete output tree against the current inventory.
Malformed cache data is a miss; a corrupt sealed bundle is an integrity error.
`--fresh` bypasses reuse. Explicit preparation reuse additionally requires a
matching public context, lock, compiler/toolchain, trust and intact evidence.
Opaque or untrusted facts cannot establish reusable proof.

Affected compares genuine base/head Git trees and compiles one workspace
snapshot per side. Both inventories contribute reasons for content, additions,
deletions, renames, modes and membership changes. Unavailable or unsupported
facts produce conservative affected/unknown results. Diff compares planned
logical targets, generated variants and expected links, including remaps; it
does not treat unrelated checkout files as output drift.

## State and effect boundaries

Only `setup` edits source ignore rules. Mutating operations require an owned
`.weld/v2/` root. Short metadata locks reserve leases, activate views and move
pointers; subprocesses and network requests run after the lock is released.
Artifact leases permit independent work. Publication additionally serializes
its destination/package/version within the checkout.

Owner records bind host, boot, PID, process start and a nonce. Unknown liveness
is retained. Journals describe durable old/new/stage/pointer transitions.
Recovery acts only when owner death and recorded filesystem facts agree; age
alone never authorizes cleanup. GC defaults to a report, and keeps active or
unknown runs, immutable bundles and archives.

The subprocess runner uses argv, selected environment, bounded sanitized logs,
finite deadlines and process-group termination on supported Linux hosts.
Manifests, Mix projects and native builds are trusted code, not a sandbox.
No hermeticity, cross-platform crash guarantee or remote publication success is
inferred from source inspection. See [Testing strategy](testing_strategy.md)
for the actual runtime acceptance gates.
