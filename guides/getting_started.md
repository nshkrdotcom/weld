# Getting Started

`Weld` can be installed in the workspace root project or—when keeping a public `:source_project` root free of maintainer dependencies—in a dedicated maintainer project such as `tools/maintainer/mix.exs`. Consumers of your source root, generated projections, `projection/*` branches, or Hex packages never install `Weld`.

## 1. Add The Maintainer Dependency

```elixir
def deps do
  [
    {:weld, "~> 0.15.0", only: [:dev, :test], runtime: false}
  ]
end
```

## 2. Add A Repo-Local Manifest

Store your manifest in one of Weld's auto-discovered locations (`build_support/weld.exs`, `build_support/weld_contract.exs`, or a single `packaging/weld/*.exs`).

For example, `packaging/weld/my_bundle.exs` in default package-projection mode:

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
        version: "0.1.0",
        docs: [
          logo: "assets/my_bundle.svg",
          source_url: "https://github.com/example/my_bundle",
          source_ref: "v0.1.0",
          extra_titles: %{"README.md" => "Overview"},
          groups_for_extras: [
            {"Start Here", ["README.md", "guides/architecture.md"]},
            {"Release", ["CHANGELOG.md", "LICENSE"]}
          ]
        ]
      ],
      output: [
        docs: ["README.md", "guides/architecture.md", "CHANGELOG.md", "LICENSE"],
        assets: ["assets/my_bundle.svg"]
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

Key manifest concepts:

- `workspace.root` resolves relative to the manifest file (`"../.."` from `packaging/weld/my_bundle.exs`, or `".."` from `build_support/weld.exs`).
- **Choose the composition mode that matches your repo:**
  - `:package_projection` *(default)* stages selected workspace projects under `components/<project_id>/` and synthesizes a root `mix.exs` (and merged `Application` module when selected projects start OTP children).
  - `:monolith` merges `lib/`, `priv/`, migrations, configs, and declared `:test_paths` into a single flat Mix project. Declare any non-selected test helpers explicitly in `monolith_opts[:test_support_projects]`.
  - `:source_project` (`roots: ["."]`) preserves an existing root `mix.exs` and materializes its declared `source_project[:files]` inventory as either a full copy or a symlinked `--live` view. See [Source-Root Artifacts](source_projects.md).
- Every `output.docs` and `output.assets` entry (in `:package_projection` and `:monolith` modes) is copied into the generated project and added to its Hex `package.files` allowlist.
- Declare `dependencies` when a selected workspace project uses `:path`, `:git`, or `:github` for an external dependency that must be rewritten to a canonical Hex requirement (or canonical Git spec) in the projected package.

## 3. Initialize `.weld/` And Inspect The Graph

```bash
mix weld.setup
mix weld.inspect
mix weld.graph --format dot
```

`mix weld.setup` initializes `<checkout_root>/.weld/` and ensures `.weld/` is present in `.gitignore`. Commit any `.gitignore` change before preparing releases from a clean Git working tree.

Use `weld.inspect` and `weld.graph` to confirm project discovery, classifications, selected closures, and zero boundary violations before projecting.

## 4. Generate Projections

```bash
# Portable full projection under .weld/full/<artifact>/project/
mix weld.project

# Symlinked live view under .weld/live/<artifact>/ (:source_project mode only)
mix weld.project --live
```

Full projections contain regular files only, `weld.provenance.json` (`kind: "full"` and content-addressed `artifact_id`), and `projection.lock.json`. Live projections symlink a `:source_project` inventory back to the checkout so local path consumers see source edits immediately without installing Weld.

## 5. Verify The Projected Artifact

```bash
mix weld.verify
```

**Package-projection and source-project modes** run:

- `mix deps.get`
- `mix deps.compile`
- `mix compile --warnings-as-errors --no-compile-deps`
- `mix test`
- `mix docs --warnings-as-errors`
- optional consumer smoke-app compilation when `verify.smoke.enabled` is `true`
- `mix hex.build` (when `verify.hex_build` is `true`)
- `mix hex.publish --dry-run --yes` (when both `hex_build` and `hex_publish` are `true`)

**Monolith mode** runs:

- per-package test baseline across each selected workspace project
- `mix deps.get`
- `mix compile --warnings-as-errors`
- `mix test` (asserting the merged test count is at least the baseline sum)
- `mix docs --warnings-as-errors`
- `mix hex.build` (when `verify.hex_build` is `true`)
- `mix hex.publish --dry-run --yes` (when both `hex_build` and `hex_publish` are `true`)

Set `verify: [hex_build: false]` for internal artifacts with non-Hex Git dependencies, or `verify: [hex_publish: false]` to verify tarball creation without running the dry-run publish check.

## 6. Prepare, Track, Publish, And Archive

From a clean committed Git tree:

```bash
mix release.prepare
mix release.track
# Optional: cd into the prepared project printed by release.prepare and run:
# mix hex.publish --yes
mix release.archive
```

`mix release.prepare` writes an immutable, integrity-checked bundle to `.weld/releases/<artifact>/<identity>/` (with `project/`, rendered HTML/Markdown `docs/`, `release.json`, and optional tarball) and updates `.weld/releases/<artifact>/CURRENT`.

`mix release.track` syncs the prepared `project/` onto an orphan `projection/<package_name>` branch so Git consumers can pin projected snapshots without touching `main`. `mix release.archive` copies the verified bundle to `.weld/archive/<artifact>/<identity>/`.
