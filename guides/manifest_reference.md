# Manifest reference

Schema 2 is a trusted evaluated Elixir keyword term. It is not a legacy manifest with renamed keys. The validator rejects unknown top-level keys and duplicates. A minimal preserve artifact:

```elixir
[
  schema: 2,
  workspace: [root: "..", projects: ["."]],
  artifacts: [
    example: [
      layout: :preserve,
      roots: ["."],
      preserve: [files: ~w(mix.exs mix.lock lib README.md LICENSE)],
      verify: [hex_build: true, hex_publish_check: false]
    ]
  ]
]
```

Explicit workspace project IDs are relative to the workspace root. Artifacts select `:components`, `:flat`, or `:preserve`, with required roots. Components and flat layouts declare `package: [name: "example", otp_app: :example, version: "0.1.0"]`; preserve derives package metadata from the root Mix project. Generated layouts support `include`, `features`, `external`, `docs`, and `files: [docs: [...], assets: [...]]`. Flat has optional `flat` settings for readme, test support, shared test configs and extra test deps. Verify settings include artifact tests, component tests (components only), smoke, and package-build checks.

Use `project_inputs` for nonstandard source inputs, including native sources. Each declaration has `path`, `type: :file | :tree | :glob`, `roles`, `target: :relative | :none`, optional `required`, and explicit `publish` for mixed roles. Use `inputs` on an artifact or preserve settings to watch structural inputs. Paths must be safe relative paths. Package membership must include required native build sources and pinned checksums. See `build_support/weld.exs` and fixture manifests for actual examples.

Workspace-level `classify`, `publication`, and `dependencies` declare graph policy. Do not specify legacy `mode`, `version`, or implicit discovery.
