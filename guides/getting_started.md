# Getting Started

`Weld` belongs in the root project that owns packaging and release work for a
multi-project Elixir repo.

## 1. Add The Dependency

```elixir
def deps do
  [
    {:weld, "~> 0.2.0", runtime: false}
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
        artifact_tests: ["packaging/weld/my_bundle/test"]
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
mix weld.inspect packaging/weld/my_bundle.exs
mix weld.graph packaging/weld/my_bundle.exs --format dot
```

Use these commands to confirm project discovery, classifications, and graph
shape before generating output.

## 4. Generate The Welded Package

```bash
mix weld.project packaging/weld/my_bundle.exs
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

## 5. Verify The Welded Package

```bash
mix weld.verify packaging/weld/my_bundle.exs
```

**Package-projection mode** runs:

- `mix deps.compile`
- `mix compile --warnings-as-errors --no-compile-deps`
- `mix test`
- `mix docs --warnings-as-errors`
- `mix hex.build`
- `mix hex.publish --dry-run --yes`
- optional smoke verification when configured

**Monolith mode** runs:

- per-package test baseline (each selected package's own test suite)
- `mix deps.get`
- `mix compile --warnings-as-errors`
- `mix test` (asserts test count is not lower than the baseline sum)
- `mix docs --warnings-as-errors`
- `mix hex.build`

## 6. Prepare And Archive Releases

```bash
mix weld.release.prepare packaging/weld/my_bundle.exs
mix hex.publish --yes
mix weld.release.archive packaging/weld/my_bundle.exs
```

The prepared bundle contains the projected project tree, tarball, lockfile, and
release metadata needed to preserve exactly what was published.
