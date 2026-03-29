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
artifact must publish a normal Hex-style dependency instead.

Each key is the dependency app name. Each value contains:

- `requirement`
- `opts`

`opts` must remain publish-safe. `weld` rejects `:path`, `:git`, and
`:github` here.

## `artifacts`

One manifest can define more than one publishable artifact. Each artifact entry
contains:

- `roots`
- `include`
- `optional_features`
- `package`
- `output`
- `verify`

## Package Keys

- `name`
- `otp_app`
- `version`
- `elixir`
- `description`
- `licenses`
- `maintainers`
- `links`
- `docs_main`

## Output Keys

- `dist_root`
- `layout`
- `docs`
- `assets`

The current stable layout is `:components`.

## Verify Keys

- `artifact_tests`
- `smoke.enabled`
- `smoke.entry_file`

## Example

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
        version: "0.1.0"
      ],
      output: [
        docs: ["README.md", "guides/architecture.md"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/web_bundle/test"]
      ]
    ]
  ]
]
```
