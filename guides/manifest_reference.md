# Manifest Reference

Weld manifests are plain Elixir keyword lists.

## Top-Level Keys

## `workspace`

- `root`
  Path from the manifest file to the repo root.
- `project_globs`
  Optional authoritative project globs. If omitted, `weld` will try
  `blitz_workspace` and then filesystem fallback.

## `classify`

- `tooling`
- `proofs`
- `ignored`

Each value is a list of project ids.

## `publication`

- `internal_only`
- `separate`
- `optional`

`optional` is a keyword list mapping feature ids to project-id lists.

## `dependencies`

Manifest-owned canonical external dependency declarations.

Use this when a selected project depends on an external package through local
workspace transport such as `:path`, `:git`, or `:github`, but the welded
artifact must publish a canonical dependency instead.

Each key is the dependency app name. Each value contains:

- `requirement` — version requirement string. Optional when `opts` includes
  `:git` or `:github`.
- `opts` — additional Mix dependency opts. `:path` is rejected. `:git` and
  `:github` are permitted.

`weld` raises if neither a `requirement` nor a git/github opt is present.

## `artifacts`

One manifest can define more than one publishable artifact. Each artifact entry
contains:

- `mode` — `:package_projection` (default) or `:monolith`. The alias
  `:components` is accepted as a synonym for `:package_projection`.
- `monolith_opts` — keyword list of monolith-specific options (see below).
  Ignored in package-projection mode.
- `roots`
- `include`
- `optional_features`
- `package`
- `output`
- `verify`

## Monolith Options (`monolith_opts`)

Selected projects contribute tests only from their Mix `:test_paths`
configuration, which defaults to `["test"]`. Weld preserves paths relative to
the owning project, de-duplicates overlaps, and rejects paths outside that
project root.

- `shared_test_configs` — list of project ids (atoms or strings) whose
  `config/test.exs` files are imported into the generated root `config/test.exs`.
  Other packages' test configs are omitted and a warning is emitted for each.
- `extra_test_deps` — list of app name atoms referencing manifest-declared
  dependencies that should be forced into test-only deps in the generated
  `mix.exs`, even if they would not otherwise appear in the test closure.
- `test_support_projects` — list of non-selected project ids (atoms or strings)
  that are allowed to appear in the monolith `:test` view. When present,
  `weld` fails closed if the discovered non-selected test support set does not
  match the manifest.

## Package Keys

- `name`
- `otp_app`
- `version`
- `elixir`
- `description`
- `licenses`
- `maintainers`
- `links`
- `docs_main` — backward-compatible shorthand for `docs.main`
- `docs` — generated HexDocs metadata:
  - `main`
  - `logo`
  - `homepage_url`
  - `source_url`
  - `source_ref`
  - `assets` — source-to-target asset-directory map passed to ExDoc
  - `extra_titles` — map of `output.docs` paths to sidebar titles
  - `groups_for_extras` — ordered `{group, [output.docs paths]}` entries

## Output Keys

- `dist_root`
- `docs`
- `assets`

Every declared `output.docs` and `output.assets` path is copied and included in
the generated package's explicit `package.files` allowlist. Weld rejects
HexDocs title/group paths that are not declared in `output.docs`, logos that are
not covered by `output.assets`, and ExDoc asset roots that are not copied.

## Verify Keys

- `artifact_tests`
- `hex_build`
- `hex_publish`
- `smoke.enabled`
- `smoke.entry_file`

Smoke verification is not run in monolith mode.
Set `hex_build: false` for internal artifacts that intentionally depend on
non-Hex git dependencies. Set `hex_publish: false` when package-projection
verification should skip `mix hex.publish --dry-run --yes`.

`hex_build: false` does not disable `weld.release.prepare`,
`weld.release.track`, or `weld.release.archive`. It only omits the tarball from
the prepared bundle.

## Example — Package Projection

```elixir
[
  workspace: [
    root: "../..",
    project_globs: ["apps/*", "core/*", "tooling/*"]
  ],
  dependencies: [
    external_lib: [
      requirement: "~> 1.2",
      opts: []
    ],
    private_tool: [
      opts: [git: "https://example.com/private_tool.git", branch: "main"]
    ]
  ],
  classify: [
    tooling: [".", "tooling/test_support"],
    proofs: ["apps/demo"]
  ],
  publication: [
    internal_only: ["tooling/test_support"],
    optional: [
      demo: ["apps/demo"]
    ]
  ],
  artifacts: [
    web_bundle: [
      roots: ["apps/web"],
      package: [
        name: "web_bundle",
        otp_app: :web_bundle,
        version: "0.1.0",
        docs: [
          logo: "assets/web_bundle.svg",
          homepage_url: "https://github.com/example/web_bundle",
          source_url: "https://github.com/example/web_bundle",
          source_ref: "v0.1.0",
          assets: %{"assets" => "assets"},
          extra_titles: %{"README.md" => "Overview"},
          groups_for_extras: [
            {"Start Here", ["README.md"]},
            {"Release", ["CHANGELOG.md", "LICENSE"]}
          ]
        ]
      ],
      output: [
        docs: ["README.md", "guides/architecture.md", "CHANGELOG.md", "LICENSE"],
        assets: ["assets/web_bundle.svg"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/web_bundle/test"],
        hex_build: true,
        hex_publish: true
      ]
    ]
  ]
]
```

## Example — Monolith

```elixir
[
  workspace: [
    root: "../..",
    project_globs: ["core/*", "runtime/*"]
  ],
  artifacts: [
    my_monolith: [
      mode: :monolith,
      roots: ["runtime/api"],
      monolith_opts: [
        shared_test_configs: ["core/contracts"],
        extra_test_deps: [:bypass],
        test_support_projects: ["tooling/test_support"]
      ],
      package: [
        name: "my_monolith",
        otp_app: :my_monolith,
        version: "0.1.0",
        description: "My welded monolith",
        docs: [
          logo: "assets/my_monolith.svg",
          source_url: "https://github.com/example/my_monolith",
          source_ref: "v0.1.0",
          groups_for_extras: [
            {"Start Here", ["README.md"]},
            {"Release", ["CHANGELOG.md", "LICENSE"]}
          ]
        ]
      ],
      output: [
        docs: ["README.md", "CHANGELOG.md", "LICENSE"],
        assets: ["assets/my_monolith.svg"]
      ],
      verify: [
        hex_build: false
      ]
    ]
  ]
]
```
