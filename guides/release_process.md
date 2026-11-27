# Release process

A Weld release operation consumes a sealed bundle ID. Preparation qualifies
exact source-derived bytes; tracking, staging, publication and archiving use
those bytes without rebuilding them. A projection tag, an archive and a remote
publication each establish a different fact.

## Preconditions and preparation

Use a clean committed checkout, an explicit schema 2 manifest, initialized
managed state and the pinned toolchain recorded in your QC evidence. Weld's own
version is 0.20.1; its package still builds normally from the root Mix project.
Record runtime acceptance for the exact committed revision before release.

```bash
mix weld setup
mix weld release-plan
mix weld prepare --artifact engine
mix weld status --artifact engine --format json
```

`setup` may edit the ignore rule; commit that edit before prepare. Prepare
reserves an artifact lease, materializes a fresh full candidate, freezes its
resolved lock, runs the mandatory qualification pipeline, then seals and validates
all evidence before moving current. Failure or detected source drift preserves
the previous valid pointer. Distinct artifacts can qualify independently; there
is no automatic multi-repository publisher.

## Bundle contents and strict proof

The immutable store is `.weld/v2/bundles/<artifact>/<bundle_id>/`:

| Path | Contract |
| --- | --- |
| `inventory.json` | Canonical `weld.inventory/2`; inputs, watches, mapping, policy and exact observed sets |
| `qualification.json` | Canonical `weld.qualification/2`; all G01–G12 outcomes and bound identities |
| `bundle.json` | Canonical `weld.bundle/2`; descriptors, source and cross-bindings |
| `project/` | Frozen standalone project, including resolved lock and verification inputs |
| `docs/` | Exact frozen documentation output, separate from the project |
| `package.tar` | Exact built Hex archive when Hex is enabled |
| `docs.tar.gz` | Exact docs payload when Hex is enabled |

Every required field is validated. Unknown fields, missing facts, changed bytes,
wrong executable modes, unexpected files, invalid empty directories, mismatched
lock or archive metadata fail integrity. The bundle ID binds the descriptor;
raw SHA-256 separately identifies the exact package/docs archives. Local runs,
logs, durations, credentials and link locators are not portable proof. Old
in-project projection reports are neither emitted nor accepted as evidence.

The current pointer is a closed `weld.current/2` record containing the artifact
and full ID. It is a convenience pointer, not mutable release truth.

## Mandatory qualification

| Gate | Required result or precise policy skip |
| --- | --- |
| G01 | Validate complete input facts and materialized candidate |
| G02 | Resolve dev/test dependencies, freeze lock and effective metadata |
| G03 | Run selected source test baselines when required |
| G04 | Compile the frozen project with warnings as errors |
| G05 | Execute the mapped artifact suites and compare observed identities |
| G06 | Generate docs with warnings as errors and validate static contracts |
| G07 | Execute configured project smoke; skip only when absent by policy |
| G08 | Build one package archive; inspect metadata, exact members, bytes and modes |
| G09 | Qualify isolated Hex dry-run construction when enabled |
| G10 | Consume the exact archive through ordinary detached Hex resolution |
| G11 | Recheck frozen docs; create one docs archive and verify its exact unpacked bytes |
| G12 | Recheck frozen project, source facts, lock and final evidence |

Non-Hex policy explicitly skips Hex-only gates. A missing tool, failed native
build or unavailable package is a failure, never a successful skip. The verifier
records every outcome and retains failure evidence. Browser rendering is a
separate check: static Mermaid checks cannot demonstrate actual rendering.
See [Testing strategy](testing_strategy.md) for scripts and independent lanes.

## Pin, stage and track

Replace `FULL_BUNDLE_ID` with the complete printed ID; examples are not release
authorization for a real package.

```bash
mix weld stage --artifact engine --identity FULL_BUNDLE_ID
mix weld track --artifact engine --identity FULL_BUNDLE_ID --tag-release
mix weld verify-tag engine-v2.0.0 --artifact engine --identity FULL_BUNDLE_ID
mix weld publish --artifact engine --identity FULL_BUNDLE_ID --tag engine-v2.0.0 --dry-run
mix weld archive --artifact engine --identity FULL_BUNDLE_ID
```

Stage always creates a new review run. Tracking builds a Git tree from the frozen
project's blobs, modes and directory structure. Local branch/tag updates use
compare-and-swap transactions. Same tree and same receipt is idempotent; the
same tree with new qualification identity receives a new receipt-bearing commit.
Annotated tags are never overwritten. Main and the source checkout remain intact.

Commits and annotated tags carry one canonical, base64url `weld.receipt/2`
record. Tag verification recomputes the project identity from Git objects; it
does not trust a checkout or an embedded text report. Without local bundle
files it reports receipt/tree agreement separately from absent local evidence.
An optional `--tarball` must match the receipt's raw archive digest.

Use a disposable local checkout and bare remote to test `--push`. A real push
is an explicit additional operation; when requested, branch and tag are pushed
atomically. At the breaking cutover, an existing branch without strict v2
receipts requires a new explicit `--branch`, such as `projection/v2/engine`.
Historical tags stay historical. The source version tag is a separate annotated
tag on the qualified source commit, created only by the release owner.

Historical operations do not require current manifest membership:

```bash
mix weld status --root /checkout --artifact engine --identity FULL_BUNDLE_ID
mix weld stage --root /checkout --artifact engine --identity FULL_BUNDLE_ID
mix weld archive --root /checkout --artifact engine --identity FULL_BUNDLE_ID
```

Freshness is assessed separately. A stale source pin is never silently replaced
by current. Publication requires the supported explicit acknowledgement when
source drift is intentionally accepted.

## Exact-byte transport and remote outcomes

The adapter is pinned to Hex Core 0.21.1, already resolved in `mix.lock`.
Package writes pass the frozen binary to the verified publish interface with
replacement disabled. Docs writes use the frozen docs archive. The uploader
has no package rebuild path. Local loopback tests capture request-body hashes
and exercise pre-send rejection, ambiguous responses and independent parts.

**Public writes remain disabled until controlled authenticated conformance is
established.** A successful local TCP test proves request shape and bytes, not
TLS/authentication, authoritative public readback or production permission.
The supplied authenticated conformance driver is for an explicitly approved
private/sandbox endpoint and scoped credentials. Unsupported remote checksum
representations stay unknown. No production upload is part of ordinary QC.

Dry run validates local evidence and plans the operation without credentials or
remote writes. Actual writes require explicit `--yes` and the qualified adapter.
Credentials are supplied through the adapter's supported external configuration;
they are not command-line arguments, log content or bundle fields.

Before each request, Weld persists intent and reserves destination/package/version
within the checkout. Outcomes distinguish confirmed, staged approval required,
definitively rejected, unknown and conflicting evidence. A lost response after a
possible send is not retry permission. A remote matching package is not uploaded
again; missing docs can proceed independently once trustworthy evidence permits.
Conflicting bytes are never replaced.

```bash
mix weld status --artifact engine --identity FULL_BUNDLE_ID --remote --format json
mix weld reconcile --artifact engine --identity FULL_BUNDLE_ID
```

Remote status only reads. Reconcile only queries remotely and persists linked
local observations; it does not upload. A staged result needs the service's
approval process followed by reconciliation. A bare 404 or unsupported checksum
is not sufficient authority to retry an ambiguous package write.

## Archive, recovery and audit

Archive copies the exact sealed bundle atomically and is idempotent for matching
bytes. It can preserve unpublished work and does not claim remote publication.
Corrupt existing archive bytes fail. GC retains bundles, archives and active or
unknown runs; default GC is read-only.

Recovery uses strict owner/lease/run/journal facts, verified owner death and the
observed transition. It preserves the last valid current pointer on recoverable
failures and refuses ambiguous evidence. Run `doctor`, inspect `recover`, then
select an eligible lease explicitly. Never infer stale ownership from age.

Collect source commit, toolchain versions, input/plan/project/package/docs/
qualification/bundle IDs, raw package and docs SHA-256, Git commit/tag object IDs,
actual request-body hashes and authoritative remote observations. Keep runtime,
consumer, native and browser evidence with the release review. A passing soak,
a matching tag or a successful archive alone does not establish release readiness.
