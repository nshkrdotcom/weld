# Getting Started

`Weld` belongs in the root project that owns packaging and release work for a
multi-project Elixir repo.

## 1. Add The Dependency

```elixir
def deps do
  [
    {:weld, "~> 0.7.1", runtime: false}
  ]
end
```

## 2. Add A Repo-Local Manifest

Create a manifest such as `packaging/weld/my_bundle.exs`:

```elixir
[
  workspace: [
    root: "../..",
    project_globs: ["core/*", "runtime/*"]
  ],
  dependencies: [
    external_lib: [
      requirement: "~> 1.2",
      opts: []
    ]
  ],
  artifacts: [
    my_bundle: [
      roots: ["runtime/local"],
      package: [
        name: "my_bundle",
        otp_app: :my_bundle,
        version: "0.1.0"
      ],
      output: [
        docs: ["README.md", "guides/architecture.md"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/my_bundle/test"],
        hex_build: true,
        hex_publish: true
      ]
    ]
  ]
]
```

`workspace.root` is resolved relative to the manifest file. In
`packaging/weld/...`, `"../.."` points back to the repo root.

Use `dependencies` when a selected workspace project depends on an external
package through a local `:path`, `:git`, or `:github` declaration that cannot
ship in the welded artifact as-is. `weld` will rewrite that dependency to the
canonical requirement you declare here.

## 3. Inspect Before You Project

```bash
mix weld.inspect
mix weld.graph --format dot
```

Use these commands to confirm project discovery, classifications, and graph
shape before generating output.

If the repo uses one of Weld's standard manifest locations, you can omit the
manifest path entirely. Explicit paths are still useful when a repo carries
more than one manifest.

## 4. Generate The Welded Package

```bash
mix weld.project
```

Package-projection mode (the default, `mode: :package_projection`) creates a
standalone Mix project under `dist/hex/<package>/` with a component-preserving
layout.

Monolith mode (`mode: :monolith`) creates a merged flat project under
`dist/monolith/<package>/`, combining sources, tests, config, migrations, and
priv from all selected packages into a single project tree.

If selected projects publish OTP application modules, the generated package also
gets a merged `lib/<otp_app>/application.ex`. In monolith mode this module also
bootstraps per-package config at startup via `Config.Reader`.

If monolith tests need source-only support from non-selected workspace
projects, keep that policy explicit with
`monolith_opts[:test_support_projects]`.

## 5. Verify The Welded Package

```bash
mix weld.verify
```

**Package-projection mode** runs:

- `mix deps.compile`
- `mix compile --warnings-as-errors --no-compile-deps`
- `mix test`
- `mix docs --warnings-as-errors`
- `mix hex.build`
- `mix hex.publish --dry-run --yes`
- optional smoke verification when configured

Set `verify: [hex_build: false]` for internal artifacts that intentionally
depend on non-Hex git dependencies, and `verify: [hex_publish: false]` when
you want package verification without the dry-run publish step.

**Monolith mode** runs:

- per-package test baseline (each selected package's own test suite)
- `mix deps.get`
- `mix compile --warnings-as-errors`
- `mix test` (asserts test count is not lower than the baseline sum)
- `mix docs --warnings-as-errors`
- `mix hex.build`

Monolith artifacts can also disable `hex.build` with
`verify: [hex_build: false]` when they are intentionally not Hex-packagable.

## 6. Prepare, Track, And Archive Releases

```bash
mix release.prepare
mix release.track
mix hex.publish --yes
mix release.archive
```

The prepared bundle always contains the projected project tree, lockfile, and
release metadata. It also contains the tarball when `verify.hex_build` is
enabled. That means internal-only artifacts can still use prepare, track, and
archive without pretending they are Hex-buildable.

`mix release.track` updates `projection/<package_name>` from the prepared
bundle and creates the first projection branch as an orphan by default.
