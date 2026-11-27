# Source accounting and size decision

## Scope and reproducible method

Run `python3 scripts/qc/static_check.py` from the committed checkout. The report
compares Git objects at the 0.19 baseline
`7897ba6457d3ba725ee3a843bc863f2c38e90411`, the implementation checkpoint
`0ff6f9ef7a66048abaf00f4f24e5464ca2d90c37`, and the current intended source.
Production means all `lib/**/*.ex` files, including the public task. Physical
lines use `splitlines()` on the complete file, with comments, whitespace and
rendered-code templates included. This method is identical for all three trees.
The dependency count includes development/test dependencies declared directly in
`mix.exs`; it is not the number of transitive packages or running applications.

The nonblank/noncomment count omits empty lines and lines beginning with `#` after
indentation. Module/function/branch counts are lexical supporting observations,
not AST complexity, compiled module counts, xref results or coverage. Generated
code strings may contain the counted keywords. The script never claims to parse
or compile Elixir.

## Implementation handoff checkpoint

| Metric | 0.19 baseline | Checkpoint | Initial runtime handoff |
| --- | ---: | ---: | ---: |
| Production implementation files | 71 | 54 | 62 |
| Physical production lines | 12,355 | 12,771 | 13,797 |
| Nonblank/noncomment lines | 10,198 | 10,530 | 12,180 |
| Lexical module declarations | 82 | 64 | 74 |
| Lexical function declarations | 911 | 1,052 | 1,294 |
| Lexical branch keywords | 559 | 620 | 1,225 |
| Direct dependencies, all scopes | 8 | 8 | 7 |
| Public Mix task files | 30 | 1 | 1 |

The Part 3 brief reports 12,762 checkpoint lines. The actual checkpoint Git tree
measures **12,771** with this counter; a byte/newline recount agrees. The nine-line
historical discrepancy is retained explicitly instead of changing the counter to
fit the brief. The baseline recount agrees with its supplied 12,355 lines.

## Quantified exception

The target of at most 9,900 physical lines is exceeded by
**3,897 lines (39.4%)**. The target of at most 55
implementation files is exceeded by **7 files**. Relative to the baseline,
there are +1,442 physical lines
(+11.7%) and -9 files. Relative to the measured checkpoint,
there are +1,026 lines and +8 files. These are recorded exceptions,
not passing size targets. The single-task target and no net direct dependency
increase are met: eight declared dependencies became seven.

The added code completes explicit source snapshots and probe isolation, one
closed role/provenance inventory, native relocation checks, strict immutable
cross-bindings, bounded archive/HTTP/process boundaries, and durable
owner/lease/run/journal recovery. The checkpoint's smaller effect layer lacked
these complete checks. The simple replacement/receipt approach could not prove
exact membership, preserve prior pointers across crashes, or distinguish an
ambiguous upload from safe retry. Retaining that design would fail the specified
contracts; this is the design reason for the larger effect boundary, not a
claim of an executed comparative benchmark.

The compiler now consumes values, layouts share renderers and a materializer,
and one canonical codec owns portable identity. Splitting the pure decision and
observation boundary adds files while removing dependency cycles by design, as
verified by compiled `mix xref` cycle checks during runtime QC. We did not retain
parallel implementations or add compatibility readers to avoid deleting old owners.

Selected **physical file** changes at the initial unformatted handoff show both
removal and expansion:

| File | Checkpoint lines | Initial handoff lines | Delta |
| --- | ---: | ---: | ---: |
| `lib/weld/plan.ex` | 546 | 105 | -441 |
| `lib/weld/projector.ex` | 301 | 138 | -163 |
| `lib/weld/workspace.ex` | 541 | 324 | -217 |
| `lib/weld/layout/components.ex` | 666 | 413 | -253 |
| `lib/weld/layout/flat/mix_file.ex` | 452 | 131 | -321 |
| `lib/weld/hash.ex` | 133 | 73 | -60 |
| `lib/weld/release.ex` | 736 | 365 | -371 |
| `lib/weld/output.ex` | 392 | 1,043 | +651 |
| `lib/weld/shell/hex.ex` | 331 | 627 | +296 |
| `lib/weld/shell/runner.ex` | 62 | 187 | +125 |
| `lib/weld/plan/inventory.ex` | 344 | 830 | +486 |

These per-file rows are not summed as an overall saving: some responsibilities
moved into shared pure compiler/render/materializer modules and must still be
counted there. The complete production totals above include all such files.
The four newly deleted paths since `0ff6f9e` are `lib/weld/lockfile.ex`,
`lib/weld/projector/live.ex`, `lib/weld/projector/source_project.ex` and
`lib/weld/shell/inputs.ex`. Legacy Hash identity helpers, the unused replace
facade and verifier wrappers were also removed. The 37 removals already in the
checkpoint remain absent. No production logic was moved into a QC script to
improve this metric, and code was not minified to conceal scope.

Multigraph had already been removed by the checkpoint; the completed source
removes unused Telemetry and preserves the resolved Hex Core 0.21.1 lock entry.
The current seven direct declarations are Blitz, Credo, Dialyxir, ExDoc, Hex Core,
Jason and NimbleOptions. Development tooling and production dependencies retain
their declared Mix scopes.

All 161 baseline test paths remain. The declaration disposition ledger contains
171 lexical rows, seven of which are shell test statements rather than ExUnit
cases. Existing independent CI lanes remain and two focused lanes were added.
Source counts do not establish preserved runtime behavior; the full suite is the
acceptance gate.

## Runtime QC recount

The pinned formatter expanded previously unformatted implementation files. It
added physical lines for layout and whitespace, which this metric includes.
Runtime QC also repaired behavior exposed by compilation and qualification.

| Metric | Runtime QC measurement |
| --- | ---: |
| Production implementation files | 62 |
| Physical production lines | 19,538 |
| Nonblank/noncomment lines | 16,112 |
| Lexical module declarations | 74 |
| Lexical function declarations | 1,571 |
| Lexical branch keywords | 1,208 |
| Direct dependencies, all scopes | 7 |
| Public Mix task files | 1 |

This measurement exceeds the physical line target by **9,638
lines (97.4%)** and the file target by **7 files**.
Rerun the same counter after additional repairs.

## Runtime and scaling status

Runtime QC records compilation, xref, test and driver observations against the
exact source revision executed. Historical checkpoint warm plan timings are
retained only as historical reference; use measured current samples for
performance comparisons.

`scripts/qc/benchmark.py` supplies exact revision checkouts, one cold/five warm
samples, forced full/live materializations separately from asserted cache hits,
real qualification and optional docs/native measurements. Missing historical
instrumentation is null, not zero. The deterministic synthetic generator was
executed with Python and counted at 100 projects, 5,000 project files, ten
artifacts and 197 mixed-scope edges; record Elixir timing runs per tested
revision under `.weld/v2/runs/qc/`.

Use the same idle host/toolchain and actual consumer inputs for comparisons.
Part 2 targets warm plan/cache medians no worse than baseline, full/qualification
medians no worse than baseline plus 10% after separately reporting new exact-tar
consumer checks, and memory within 20% unless a measured explanation is recorded.
After ordinary QC and smaller scaling runs, only the final long 100/5,000/10 soak
is handed to the maintainer. A performance result alone is not release approval.
