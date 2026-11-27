# Getting started

Weld produces ordinary Mix artifacts from explicitly declared source projects. Install it only in the maintainer environment:

```elixir
{:weld, "~> 0.20.1", only: [:dev, :test], runtime: false}
```

The version constraint is for the published release; when qualifying unreleased source, use the supplied checkout through your normal local tool development workflow. Generated consumers do not need Weld.

## Declare the workspace

Create `build_support/weld.exs` in a trusted repository. This generated-layout example assumes `core/sdk/mix.exs` and `README.md` exist:

```elixir
[
  schema: 2,
  workspace: [root: "..", projects: ["core/*"]],
  artifacts: [
    sdk: [
      layout: :components,
      roots: ["core/sdk"],
      package: [name: "sdk", otp_app: :sdk, version: "1.0.0"],
      files: [docs: ["README.md"]],
      verify: [hex_publish_check: false]
    ]
  ]
]
```

Use `:preserve` for an existing project whose native Mix file already defines the artifact, or `:flat` when the supported merged-source layout is required. Declare all helpers/native inputs that affect generation. Read the [manifest reference](manifest_reference.md) before including projects with custom build behavior.

Weld evaluates the manifest and source Mix code. Metadata probing observes dev, test and prod in isolated, bounded VMs and shares those facts across artifacts. It does not make an untrusted repository safe to execute.

## Inspect before materializing

```bash
mix weld help plan
mix weld plan --artifact sdk --format json
mix weld graph --artifact sdk --view package
mix weld query deps core/sdk --view test
```

These commands do not initialize managed output. Inspect the selected projects, external requirements, compiler/native files, test ownership and source-to-target mapping. Fix invalid or missing declarations before writing output.

Default discovery uses the Git root. In a non-Git directory, supply `--root /path/to/workspace`; a relative `--manifest` is always relative to the directory where the command is invoked.

## Create development views

```bash
mix weld setup
mix weld project --artifact sdk --kind full
mix weld path --artifact sdk --kind full
mix weld project --artifact sdk --kind live
mix weld diff --artifact sdk --kind live
```

Setup is the only command that edits source, by ensuring the `.gitignore` rule. Commit that change before prepare. State lives under `.weld/v2/` and must remain untracked.

Full output is a detached regular-file project. Live output links approved ordinary source while keeping generated and structural inputs guarded. Live is for editing and ordinary path consumption; package build/publication from it is blocked. `--fresh` bypasses development cache reuse. A modified or incomplete cached output is revalidated before use.

## Qualify and prepare

```bash
mix weld verify --artifact sdk
mix weld prepare --artifact sdk
mix weld status --artifact sdk --format json
mix weld path --artifact sdk --kind bundle
```

Verify uses an isolated run and does not set CURRENT. Prepare additionally requires clean committed source, performs qualification, seals exact project/docs/archive evidence, and atomically activates the bundle. Failed qualification does not replace a previously valid pointer. The result reports the full immutable identity; use it to pin later release operations.

Review [release process](release_process.md) before tracking, publishing or archiving. `stage` creates a fresh writable review copy; it does not replace or qualify the bundle. Production writes are never implied by preparation or a dry run.

## More than one artifact

```bash
mix weld plan --all --format json
mix weld verify --all
mix weld release-plan
mix weld affected --base HEAD~1 --head HEAD --task package
```

Batches capture workspace facts once, keep deterministic per-artifact results, and report partial failures. Release order follows compiled publication requirements and aliases. It does not automatically publish a release train. See the [CLI reference](cli_reference.md) for contexts, historical pins, diagnostics and exit statuses.
