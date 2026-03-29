# Getting Started

`Weld` belongs in the root project that owns packaging and release work for a
multi-project Elixir repo.

## 1. Add The Dependency

```elixir
def deps do
  [
    {:weld, "~> 0.1.0", runtime: false}
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

This creates a standalone Mix project under `dist/hex/<package>/`.

## 5. Verify The Welded Package

```bash
mix weld.verify packaging/weld/my_bundle.exs
```

This runs package-level verification against the generated artifact:

- `mix compile --warnings-as-errors`
- `mix test`
- `mix docs --warnings-as-errors`
- `mix hex.build`
- `mix hex.publish --dry-run --yes`
- optional smoke verification when configured

## 6. Prepare And Archive Releases

```bash
mix weld.release.prepare packaging/weld/my_bundle.exs
mix hex.publish --yes
mix weld.release.archive packaging/weld/my_bundle.exs
```

The prepared bundle contains the projected project tree, tarball, lockfile, and
release metadata needed to preserve exactly what was published.
