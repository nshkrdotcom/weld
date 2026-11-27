# Preserved source projects

Choose `layout: :preserve` when an existing root or nested Mix project already defines the artifact. Its native `mix.exs` owns app/package name, version, dependencies, compiler paths, callbacks, package files, exclusions, documentation and application behavior. Weld preserves that source rather than replacing it with generated Mix metadata.

## Declare a complete detached project

```elixir
[
  schema: 2,
  workspace: [root: "..", projects: ["packages/native_sdk"]],
  artifacts: [
    native_sdk: [
      layout: :preserve,
      roots: ["packages/native_sdk"],
      preserve: [
        files: ["mix.exs", "lib", "src", "include", "priv", "test", "config", "README.md", "LICENSE", "VERSION", "build_support"],
        inputs: [[path: "VERSION", type: :file]]
      ],
      verify: [hex_publish_check: false]
    ]
  ]
]
```

Use only paths actually present in the project and required by its build/test/docs behavior. Include an existing native `mix.lock`. When no lock exists, omit it; Weld records absence and resolves/freezes the standalone lock during qualification. Include nested version helpers, `Code.require_file` helpers, custom compilers, Makefiles, native pins/checksums, fixtures, application configuration and docs hooks. A missing required path is a plan error, not an optional copy.

`preserve.files` is a disjoint list relative to the selected native root. Listing both `lib` and `lib/nested` is invalid. Absolute, escaping, symlink and special-file inputs are rejected. There is one root and no include/features; generated package/docs/files overrides are forbidden.

Before activating a projection, Weld checks its provisional detached project with isolated metadata probes. It compares effective app/package identity, dependencies, compiler/test paths and package patterns in dev, test and prod. Metadata is captured independently for every environment; unsupported variation in identity, package/compiler metadata or application callbacks fails explicitly. Production-only dependencies cannot disappear merely because a development probe did not return them. A project that only evaluates while its original checkout is present is not a valid standalone artifact.

## Dependencies and nested ownership

Path dependencies may remain native when their entire required subtree is within the declared detached project. A path dependency outside that subtree must become a portable external dependency in the native Mix project: a versioned Hex dependency, or remote Git for a non-Hex artifact. Declare the corresponding `external` boundary if that package is also a discovered workspace project. Filesystem Git locators, including relative paths and `file://` URLs, require a native declaration change. A canonical manifest override cannot make an unchanged native Git locator portable; preserve does not rewrite path or Git declarations on the user's behalf.

A root may compile nested/private project files without activating the nested projects' OTP applications. Compilation ownership, dependency membership, test support and inventory ownership are distinct. Declare nested projects explicitly when their dependency or helper facts are needed. Root ownership does not silently include every sibling or ignored project.

## Full and live behavior

```bash
mix weld plan --artifact native_sdk
mix weld project --artifact native_sdk --kind full
mix weld project --artifact native_sdk --kind live
mix weld verify --artifact native_sdk
```

Full is an ordinary detached project composed of regular files and directories. Live links only plan-approved read-only source. Mix files, locks, config, structural helpers and mutable/native build roots are copied or transformed as required. The self-contained live guard checks structural inputs and prevents package publication; it does not depend on Weld at consumer runtime.

Some dynamic native callback/alias shapes cannot safely receive the live guard. Those fail with `unsupported_live_mix` and a full-output alternative. They are not silently rewritten. Preserve runs native test suites; extra generated artifact suites and component-test switches are not supported.

Native Mix package patterns and exclusions define the expected Hex payload. Verification compares the actual archive with the closed planned inventory, including modes and metadata. Source tests/support/docs inputs can remain in the detached verification project while excluded from the published archive. Broad package patterns that leak reports, caches or mutable bookkeeping are rejected.

## Prove relocation

Qualify from an isolated copy, consume the exact generated package tar in a separate ordinary Mix project, and run the runtime smoke behavior your artifact requires. The source checkout and its original path dependencies must be unavailable to that consumer. Native compilation should use declared pinned inputs. Test root and nested helpers, installed `priv` access, runtime config and migration assets as applicable.

Preparation requires clean committed Git source even though non-Git development projection and verification are supported. Historical bundle inspection operates from `--root`, `--artifact` and a full identity without needing the current manifest. See [release process](release_process.md) for sealing, receipts, staging, exact-byte publication and archive semantics.
