# Workflow

Use Weld as a maintainer dependency. Consumers install an ordinary Mix project
and do not need Weld. Edit authoritative source projects, then use a live view
for development or a full view for a detached export. Release operations start
from an immutable, qualified bundle.

## Start from explicit intent

A schema 2 manifest declares workspace directory globs and artifacts. Discovery
starts at the Git checkout root or an explicit `--root`; `--manifest` is relative
to the invocation directory. There is no implicit root project or search through
historical manifest names. Manifest and Mix evaluation execute trusted code.

```bash
mix weld setup
mix weld plan --artifact engine
mix weld graph --view package --format dot
mix weld query deps apps/engine --view runtime
mix weld query why apps/engine core/contracts --view package
mix weld release-plan
```

Review and commit the setup ignore rule and manifest. `setup` initializes owned
state; read-only commands do not initialize or repair it. Plan reports explain
dependency, compilation, verification, inventory and external membership.
Release order is computed from actual publication dependencies, aliases and
requirements. It is an ordered report, with no automatic publication.

## Develop and inspect

```bash
mix weld project --artifact engine --kind live
mix weld path --artifact engine --kind live
mix weld diff --artifact engine --kind live
mix weld project --artifact engine --kind full
mix weld diff --artifact engine --kind full
```

Point a development Mix path dependency at the printed live directory. Ordinary
linked source edits appear immediately. Native mutable roots, config, locks and
structural helpers are copied. When the generated guard reports a change,
execute its quoted refresh command. Flat topology changes require refresh;
component/preserve directory groups allow ordinary content additions when those
do not change a structural input. A live view always refuses Hex build/publish.

A full view contains only regular files and directories. It is useful for
inspection and detached path consumption. Weld can replace it after validating
a new stage, but it is not a qualification receipt. Cache validation checks all
expected bytes, executable modes, empty directories and unexpected entries.
Use `--fresh` to force regeneration.

## Verify without changing a candidate

```bash
mix weld verify --artifact engine
mix weld verify --artifact engine --fresh --context linux-otp29-native-v1
mix weld path --artifact engine --kind run --run RUN_ID
```

Verification materializes a distinct run, resolves dev/test dependencies, freezes
the standalone lock, rechecks effective metadata, and runs G01–G12. Source and
artifact suites remain independent. The package gate inspects the exact tar,
then an ordinary detached Hex consumer resolves that tar through a signed local
registry. Docs are generated and frozen separately. Reports and logs remain
outside the frozen project. Failures retain a run for diagnosis.

A context is a public, nonsecret label. Declare required public environment names
in `verify.context`; configure actual public context values and native toolchain
settings through the supported runner configuration. A label alone is not proof
that dependencies, toolchain or registry trust match. See the manifest reference.

## Prepare and review a release

From a clean committed source checkout:

```bash
mix weld prepare --artifact engine
mix weld status --artifact engine --format json
mix weld stage --artifact engine --identity FULL_BUNDLE_ID
mix weld path --artifact engine --kind bundle --identity FULL_BUNDLE_ID
mix weld path --artifact engine --kind docs --identity FULL_BUNDLE_ID
```

Prepare runs the same qualification pipeline and activates a pointer only after
strict sealing. Copy the full 64-character ID printed by prepare/status. Each
stage invocation creates its own writable review run. Edits in that run never
change the bundle or become publication input. Status reports integrity,
freshness, qualification, tracking and remote evidence separately.

`prepare --reuse PUBLIC_CONTEXT` requests a narrow optimization for eligible
locked, trusted preserved-source evidence. An ineligible request runs complete
qualification. `--fresh` bypasses proof and work-cache reuse. Corrupt evidence
fails closed. Do not infer that a warm run reused proof unless the result says so.

Tracking, publication, reconciliation and archive commands require the explicit
ID, or a supported explicit `--current` selection resolved once. Historical pins
can be used with `--root`, `--artifact` and `--identity` even after the current
manifest changes or disappears. See [Release process](release_process.md).

## Batch and CI

```bash
mix weld plan --all --format json
mix weld affected --base main --head HEAD --task verify --format json
mix weld verify --all
mix weld prepare --all
mix weld release-plan --no-check --format json
```

Batch commands share workspace facts, order artifacts deterministically and
retain per-artifact errors. Source drift stops remaining writes. An unsatisfied
release constraint is reported by `--no-check`; malformed plans and real cycles
remain errors. Affected evaluates trusted revision snapshots. Do not run an
unknown pull request's Mix code with publication credentials.

## Recovery and retention

```bash
mix weld doctor --format json
mix weld recover --format json
mix weld recover --lease LEASE_ID
mix weld gc --keep 2
mix weld gc --keep 2 --apply
```

Doctor and unselected recover inspect state. Explicit recovery uses recorded
journal transitions and verified dead ownership. An active or unknown owner is
not stale merely because time elapsed. GC is read-only by default; `--apply`
prunes only eligible completed runs and never treats a bundle as disposable cache.
Do not remove state by hand to bypass an ownership or integrity diagnostic.

| Diagnostic | Safe next action |
| --- | --- |
| Unknown key, overlapping glob or duplicate app | Correct the explicit manifest/project identity, then run plan |
| Missing native helper or detached input | Add the required declared input/preserve file and regenerate |
| Conflicting dependency or code collision | Fix the source boundary/requirement or use an appropriate layout |
| Stale live view | Run the refresh command printed by the generated guard |
| Dirty source during prepare | Commit intended source changes, rebuild the plan, prepare again |
| Corrupt bundle | Preserve evidence, investigate exact mismatches; never treat it as a cache miss |
| Unknown publication outcome | Reconcile the pinned bundle before considering another request |
| Active/unknown lease | Wait for the owner or inspect it; recover only verified dead owners |
| Unmanaged or symlinked output | Choose an explicitly owned safe state location; do not force replacement |
| Unqualified Hex adapter | Complete controlled authenticated conformance; production writes remain disabled |

The breaking 0.20 release reads only schema 2 and `.weld/v2/`. Historical state
and old tags remain untouched. No automatic state importer or dotted-task alias
is provided.
