# Architecture

`Weld` treats projection as a deterministic build artifact, not as a second
source tree.

## Flow

1. `Weld.Manifest` loads and validates a manifest file.
2. `Weld.ProjectGraph` reads selected child Mix projects and classifies deps.
3. `Weld.Audit` scans selected source trees for app-identity-sensitive code.
4. `Weld.Builder` copies source trees into `dist/hex/<package_name>/vendor/...`.
5. `Weld.Builder` renders a standalone generated `mix.exs`.
6. `Weld.verify!/2` runs normal Mix verification inside the generated package.

## Dependency Rules

- selected sibling `path:` deps become internalized
- unresolved sibling `path:` deps fail the build
- `git` deps fail the build
- external Hex deps are preserved in generated `deps/0`

## Generated Project Shape

The generated package is a normal Mix project:

```text
dist/hex/<package_name>/
  mix.exs
  README.md
  CHANGELOG.md
  vendor/
    core_contracts/
      lib/
    runtime_local/
      lib/
```

This lets `Weld` verify the package with the same `mix` commands downstream
consumers would expect.
