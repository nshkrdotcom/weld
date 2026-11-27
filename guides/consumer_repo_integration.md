# Consumer repository integration

Weld is a maintainer tool. Downstream applications consume an ordinary detached Mix project, a projection Git ref, or a Hex package. They do not need Weld, a source-workspace helper, or the producer's checkout layout at runtime.

## Producer responsibilities

Declare all source projects with explicit schema 2 globs, choose the appropriate components/flat/preserve policy, and make native/helpers/config/docs inputs explicit. For `:flat` monoliths, absorbed component OTP apps lose standalone runtime `.app` identities while `Application.app_dir/2` on the surviving `package.otp_app` continues resolving merged `priv/` assets after relocation. Resolve external package boundaries and publish aliases in the native declarations or canonical manifest policy. The artifact compiler owns membership and mapping; release-plan derives order from the resulting publication requirements.

```bash
mix weld plan --all --format json
mix weld release-plan --format json
mix weld verify --all
mix weld prepare --all
mix weld status --all --format json
```

Batch qualification is not coordinated publishing. Prepare each required base/provider artifact, review its exact bundle identity and dependency constraints, and perform explicitly pinned release operations in dependency order. A separate provider remains a separate artifact even when another package optionally depends on it.

## Consumer forms

| Form | Ordinary Mix dependency | Evidence to verify |
| --- | --- | --- |
| Development path | `{:sdk, path: "/detached/sdk"}` | Full standalone compile/start; approved live views are development only. |
| Projection Git | `{:sdk, git: "https://example.test/sdk.git", tag: "sdk-v1.0.0"}` | Annotated Weld receipt, exact projected tree/modes and correct immutable ref. |
| Hex | `{:sdk, "~> 1.0"}` | Exact package archive, expected metadata/dependencies, trustworthy registry/checksum and detached installation. |

Use the real producer package/app names and version requirements. For aliased Hex names, retain the native `hex:` option. Do not change the consumer to a local extraction path and call that proof of Hex installation: the exact qualified tar must be served through the controlled registry and consumed through normal Hex resolution.

A provider with native code must include the source, headers, build recipes, pinned downloads/checksums and runtime assets needed in a clean environment. Qualify its native build and actual runtime load after removing original checkout access. Optional features must be exercised explicitly; qualifying only the base library does not qualify each provider.

## Portable bundle evidence

A sealed bundle uses the closed `weld.bundle/2` descriptor plus `inventory.json` and `qualification.json`, the exact `project/` and `docs/` trees, and package/docs archives when enabled. Every cross-binding and raw digest is validated. Local pointers and run/outcome records are operational state, not additional artifact definitions.

External tooling must read the new strict descriptor and use full bundle IDs. Old handoff/state/receipt readers are not supported, and there is no automatic migration or rebuild publisher. Keep producer state outside version control. Staging is an isolated review copy and must not be used to overwrite immutable evidence.

## Qualify a consumer independently

Use a disposable checkout or temporary consumer with its own dependency/build directories. Ensure no producer path dependency, inherited Mix override, original source tree or Weld runtime library can satisfy a missing artifact. Resolve the base package and applicable optional providers, compile, start and exercise their configured smoke behavior. Test projection Git and exact-tar Hex consumption independently when both distribution forms are supported.

Keep the source verification lane, detached artifact lane and consumer lane independent. Record actual toolchain, dependency resolution, package digests, commands and outcomes. A generated plan or a successful local copy does not establish native/Hex/browser behavior. See [testing strategy](testing_strategy.md) for runnable local registry and relocation experiments. Public writes remain disabled until the exact-byte adapter's authenticated conformance is established; no production upload is required to run read-only planning or dry runs.
