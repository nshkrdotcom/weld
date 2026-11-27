# Qualification execution drivers

These drivers execute real commands when Elixir, OTP and Mix are installed.
They never write a passing record when a prerequisite or check is unavailable.
Runtime QC records driver and test results with their source revisions. Run
from the Weld checkout after
`mix deps.get` and `MIX_ENV=test mix compile --warnings-as-errors`.

## Local archive, runner and HTTP boundary contracts

```sh
scripts/qc/loopback_transport.sh
MIX_ENV=test mix test --only ci_build:qualification_faults test/weld/qualification_contract_test.exs
```

The HTTP fixture binds only loopback and observes the actual body buffer sent by
Hex Core 0.21.1. Both package and docs tests compare the received bytes and SHA-256
with the frozen archives. The release workflow tests cover the durable intent,
unknown/staged states, conflict, reconciliation and package/docs independence.
No test in this group targets a production registry. GNU `timeout`, `kill`, `sh`,
and a working Hex archive are required. Each subprocess has a 15 minute bound,
64 MiB total output bound, 64 KiB tail and a sanitized private local log.

## All layouts and real native builds

```sh
mix run --no-start scripts/qc/qualify_layouts.exs -- --output /tmp/weld-qc-layouts
MIX_ENV=test mix test --only ci_build:hex_consumption test/weld/hex_consumption_contract_test.exs
```

Use a new output path. The matrix qualifies components, flat and preserve, plus
the `native_hex` fixture. Each copied fixture gets a disposable committed Git
root, so a run inside managed `.weld/v2/runs/qc/` cannot accidentally discover
the enclosing Weld checkout as its source root. It saves exact package/docs archives and gate/log
observations outside each copied fixture, deletes that original source checkout,
and installs the exact package through a signed loopback Hex registry. The
consumer has an ordinary registry dependency, no Weld dependency and no path or
Git fallback. Its lock outer checksum and downloaded cache bytes must equal the
frozen tar SHA. It compiles dependencies and the consumer, starts the package,
loads its modules and executes the configured public smoke entry when present.

The native fixture checks SHA-256 pins for its actual C, header and bootstrap
inputs; invokes Make and the C compiler; loads a real NIF; and reads a bootstrap
payload in the relocated application's `priv` directory. It then stops the
registry, deletes build/dependency outputs and rebuilds/tests with `HEX_OFFLINE=1`
from the verified cache. Its native source is shipped in the package and needs
no native download. This proves that fixture's contract, not compatibility with
an absent third-party provider. Real provider checkouts and their actual online,
offline, checksum, platform and source-pin settings are separate acceptance work.
Required host tools: `openssl`, Make, C compiler, installed Hex with
`mix hex.registry`, and running OTP development headers. The fixture targets
Linux shared-library naming; qualify other operating systems with their real
provider tooling before claiming support.

For an independently supplied exact provider archive:

```sh
mix run --no-start scripts/qc/signed_hex_consumer.exs -- \
  --archive /tmp/provider-package.tar --sha256 FULL_RAW_TAR_SHA256 \
  --output /tmp/weld-provider-consumer --smoke /tmp/provider-smoke.ex \
  --native-context /tmp/native-context.json --offline-rebuild
```

A smoke module may expose `WeldSmoke.verify!/0` returning `:ok` or `true`, or
`WeldSmoke.ready?/0` returning `true`. Native context JSON has exactly
`native_env` and `public_facts`; see `native-context.example.json`. Replace its
example compiler identity with observed toolchain/version/image facts. Runtime
library code reads those explicit application settings; it never reads OS env.
Inherited compiler/Mix/Hex overrides are scrubbed. Keep credentials out of this
public context. The driver never changes the supplied archive.

## Positive locked-preserve proof reuse

From a clean identified Weld checkout or installed archive:

```sh
mix run --no-start scripts/qc/prepare_reuse.exs -- --output /tmp/weld-reuse
```

The driver resolves and commits a lock only in a disposable fixture checkout,
prepares it once, then requires identical-context reuse without executing any
gate. It also proves that a context change and `--fresh` execute qualification,
and that interrupted requalification preserves the previous current bundle.
Dirty/unidentified development compiler state or unavailable trust facts fails
the prerequisites; it is never relabelled as a positive reuse result.

## Browser evidence, kept separate from G06

Install Playwright in the operator's isolated tooling environment and install its
Chromium browser. This is not a Weld runtime/package dependency.

```sh
node scripts/qc/browser_docs.mjs /tmp/weld-qc-layouts/components/docs /tmp/weld-browser
```

The driver serves the frozen docs on loopback, navigates actual documentation
links, checks rendered SVG and JavaScript failures in light/dark body themes,
and saves screenshots plus `browser.json`. Missing tooling, Mermaid, navigation
or rendering fails. Review the screenshots and separately exercise the real
ExDoc theme-toggle control and back/forward navigation. Static `DocsSmoke` only
proves index, script and listener shape; it never claims browser rendering.

## Authenticated sandbox conformance

`authenticated_conformance.exs` is a restricted contract test of
`Weld.Shell.Hex.http_transport/1`, not another release publisher. It refuses the
public Hex service and accepts only an explicitly authorized HTTPS sandbox and
package names beginning `weld_qc_`. It is never called by verify, prepare or CI.
No sandbox or production write has been performed in this implementation session.

The sandbox must expose an authenticated `weld-qc/` API receipt route documenting
its actual received HTTP body hashes, authoritative absence including staging,
archive readback hashes, staged-approval exercise, TLS and signature/origin
verification. This is a test-harness API; **the public Hex API is not assumed to
provide it**. An unsupported receipt API fails before any write. Supported but
incomplete final receipts produce an unqualified observation and exit 2. Merely fetching/recompressing public docs does not establish an authenticated
raw docs archive hash. The current production adapter conservatively reports
that readback as unsupported and keeps public writes disabled until conformance.

Review the exact package, version, endpoint and raw archive hashes, obtain the
sandbox operator's authorization, and supply a scoped key in
`WELD_QC_SANDBOX_API_KEY` (never in a URL, file argument or report):

```sh
mix run --no-start scripts/qc/authenticated_conformance.exs -- \
  --api-url https://AUTHORIZED-SANDBOX/api \
  --repo-url https://AUTHORIZED-SANDBOX/repo --public-key /tmp/registry-public.pem \
  --archive /tmp/weld_qc_probe.tar --docs /tmp/weld_qc_docs.tar.gz \
  --evidence-path weld-qc/EXPLICIT-ATTEMPT-ID --output /tmp/weld-auth-conformance \
  --permit-sandbox-writes
```

The output directory stores the intent before sending and each result. Existing
output refuses writes. After a disconnect or staged response, repeat the same
pinned arguments with `--reconcile` instead of `--permit-sandbox-writes`; this
mode only queries. The script never retries uploads, replaces a version,
automatically approves staging, or enables production configuration. A conformant
sandbox observation is a review artifact; production trust remains bound to the
actual supported destination, adapter fingerprint, and authenticated readback.
The report also records the current adapter's own package/docs reads independently
of the sandbox receiver receipts. A sandbox pass cannot turn an unsupported
public docs read into confirmation.

## Benchmarks and final synthetic soak

Run on the same idle host with Python 3, Git, GNU `time`, and the pinned
Elixir/OTP/Hex toolchain. Initialize ignored state with `mix weld setup` and
commit the implementation being compared: `--ref HEAD` measures that exact
commit, without overlaying working-tree edits.

Copy [benchmark-cases.example.json](benchmark-cases.example.json), replace its
external checkout paths, baseline/current manifest configurations and artifact
IDs, then run:

```sh
python3 scripts/qc/benchmark.py \
  --ref 7897ba6457d3ba725ee3a843bc863f2c38e90411 \
  --ref 0ff6f9ef7a66048abaf00f4f24e5464ca2d90c37 \
  --ref HEAD --cases /absolute/path/to/completed-benchmark-cases.json
```

The driver copies each input and tool revision into a disposable checkout;
original sibling repositories remain unchanged. Each operation gets one cold
and five warm fresh-VM samples. `full` and `live` force materialization on every
sample. Separate `full_cache` and `live_cache` operations populate the cache once
and require all five warm runs to reuse every artifact. `verify` measures real
qualification separately; optional `docs` and `native` operations use declared
commands. Native cases can supply explicit `native_env` and public
`qualification_context` facts.

The report retains actual exit statuses and logs, cold observations, warm
medians/maxima, wall time, peak RSS, available phase/probe/process/copy metrics,
and cache/state sizes. Unsupported historical metrics are null. Erlang
`call_time` phase counters are labeled separately from wall durations and must
not be summed with overlapping phases. Cold means empty input work caches,
without flushing the OS page cache. Tool dependency preparation is recorded
outside sample timings; missing prerequisites and failed samples return nonzero.

Check the deterministic generator without an Elixir runtime using a new path:

```sh
python3 scripts/qc/benchmark.py --generate-only /tmp/weld-benchmark-input \
  --projects 100 --files 5000 --artifacts 10
```

It creates exactly 100 projects and 5,000 regular project files, plus five root
harness files, with 10 artifacts and mixed acyclic dependency scopes. Before
the final soak, compare smaller runs using `--projects 20 --files 1000
--artifacts 2` and `--projects 50 --files 2500 --artifacts 5`. After ordinary QC
and repairs, hand the maintainer this final long command:

```sh
python3 scripts/qc/benchmark.py \
  --ref 7897ba6457d3ba725ee3a843bc863f2c38e90411 \
  --ref 0ff6f9ef7a66048abaf00f4f24e5464ca2d90c37 \
  --ref HEAD --synthetic --projects 100 --files 5000 --artifacts 10
```

The driver prints its unique `.weld/v2/runs/qc/benchmark-*/` directory. Retain
`report.json`, sample reports, request configurations and preparation/sample
logs. Review regressions against Part 2 section 08.3; six observations do not
establish statistical certainty, and a soak pass does not establish release
readiness.

## Upstream contracts used

* Hex Core 0.21.1 binary release upload:
  <https://hex-core.hexdocs.pm/hex_api_release.html>
* Hex Core 0.21.1 binary body passthrough and repository path construction:
  <https://github.com/hexpm/hex_core/blob/v0.21.1/src/hex_api.erl>
* Hex Core default HTTPc TLS peer/CA verification:
  <https://hex-core.hexdocs.pm/hex_http_httpc.html>
* Hex Core archive/files/mode contract:
  <https://hex-core.hexdocs.pm/hex_tarball.html>
* Signed ordinary Hex registry setup:
  <https://hex.hexdocs.pm/Mix.Tasks.Hex.Registry.html>
* Hex 2.7 build/directory/native build-tool behavior:
  <https://github.com/hexpm/hex/blob/v2.7.0/lib/mix/tasks/hex.build.ex>
* Hex 2.7 dry-run in-memory archive creation:
  <https://github.com/hexpm/hex/blob/v2.7.0/lib/mix/tasks/hex.publish.ex>
* Hex API release/docs/staging semantics:
  <https://github.com/hexpm/specifications/blob/main/apiary.apib>

The isolated G09 process observes the actual return of `Hex.Tar.create!/3` and
requires its bytes to match G08. If that instrumentation point changes, the gate
fails with a prerequisite error; it never substitutes a fresh archive for the
frozen release payload. All G01–G12 outcomes and policy skips remain explicit.

## Installed Weld package qualification

Use the exact Weld `package.tar` you intend to distribute and its independently
recorded raw SHA-256. This driver first installs that archive with the existing
signed loopback Hex consumer, then starts a **new Mix VM** inside that consumer.
The child runs only the installed Weld implementation. Its harness is a copied
standalone script; it imports no product code from the bootstrap checkout.

```sh
mix run --no-start scripts/qc/installed_weld.exs -- \
  --archive /absolute/path/to/weld/package.tar \
  --sha256 FULL_LOWERCASE_RAW_TAR_SHA256 \
  --output /tmp/weld-installed-qc
```

The output path must be new, have an existing parent and be outside every Git
checkout. The defaults exercise **components, flat and preserve**: each copied
fixture is planned, materialized in both full and live forms with cache reuse
disabled, and verified through the installed G01–G12 implementation. To add the
real C/NIF fixture, pass `--native`; explicit toolchain facts can also be supplied:

```sh
mix run --no-start scripts/qc/installed_weld.exs -- \
  --archive /absolute/path/to/weld/package.tar \
  --sha256 FULL_LOWERCASE_RAW_TAR_SHA256 \
  --output /tmp/weld-installed-native-qc --native \
  --native-context /absolute/path/to/native-context.json
```

The ordinary consumer has an exact Hex dependency on `weld`, never a path or Git
dependency. Before using the installed APIs, the child checks that **every Weld
module** loads from `consumer/cache/build/dev/lib/weld/ebin`, confirms the package
version and signed-registry lock tuple, and compares the cached tar with the
supplied SHA. It also compares the installed dependency source files against the
actual archive entries and records source/BEAM hashes. These checks run again
at the end; a loaded copy from the bootstrap checkout cannot satisfy them.

The driver preserves the supplied archive and original fixture trees, uses
fresh copies under its output directory, and rechecks the originals after the
child exits. It does not touch original sibling consumer repositories. The
outer child-process bound is four hours; individual qualification subprocesses
retain their own bounds. Missing prerequisites, any failed phase, unexpected
code paths or checksum differences fail explicitly and never produce a successful
final `result.json`. This driver has not been run in the current environment.

Retain these artifacts:

| File | Evidence |
|---|---|
| `result.json` | Final `weld.installed-qc/1` result: archive/version/driver hashes, child exit status, unchanged-original assertions, installed code facts and per-layout results |
| `installed-code.json` | Loaded Weld code path, per-module BEAM paths/hashes, compile-source path/hash, installed source-entry hash, cached tar hash and consumer lock hash |
| `installation.json` | Ordinary signed Hex archive installation, checksum, compile/start and consumer-test observations |
| `request.json`, `invocation.json`, copied `installed_weld.exs` | Exact child inputs, command, working directory, timeout and reproducible harness |
| `installed-child.log`, `child-process.json` | Bounded sanitized child output and actual exit status when the process returns |
| `<layout>/plan.json`, `qualification.json`, `result.json` | Compiled inventory, G01–G12 evidence, plan/input/compiler IDs and full/live/verification paths |
| `fixtures/<layout>/.weld/v2/runs/verify/.../logs/` | Installed verifier's individual command logs and associated operational evidence |
| `driver-failure.json`, `<layout>/failure.json` | Failure diagnostics when their respective execution stage fails |

`installed-result.json` records the child result before the parent verifies
that the supplied archive and original fixtures are unchanged. Treat the final
`result.json` as the complete driver outcome. These local execution records are
separate from immutable release-bundle schemas and publication authorization.
