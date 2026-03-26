# Getting Started

`Weld` is intended to be installed in the root project that owns a multi-Mix
monorepo.

## 1. Add The Dependency

```elixir
def deps do
  [
    {:weld, "~> 0.1.0", runtime: false}
  ]
end
```

## 2. Create A Projection Manifest

Write a manifest under `packaging/hex_projections/`:

```elixir
%{
  package_name: "my_bundle",
  otp_app: :my_bundle,
  version: "0.1.0",
  mode: :library_bundle,
  source_projects: [
    "core/contracts",
    "runtime/local"
  ],
  public_entry_modules: [
    MyBundle
  ],
  copy: %{
    docs: [
      "README.md",
      "CHANGELOG.md",
      "guides/architecture.md"
    ],
    assets: [],
    priv: :auto
  },
  docs: %{
    main: "readme"
  }
}
```

## 3. Audit Before You Build

Run:

```bash
mix weld.audit packaging/hex_projections/my_bundle.exs
```

Use `:strict_library_bundle` when the bundle should fail on app-identity
assumptions such as `Application.app_dir/1`.

## 4. Build The Projection

Run:

```bash
mix weld.build packaging/hex_projections/my_bundle.exs
```

This generates a standalone package in `dist/hex/my_bundle/`.

## 5. Verify The Result

Run:

```bash
mix weld.verify packaging/hex_projections/my_bundle.exs
```

Verification runs:

- `mix deps.get`
- `mix compile`
- `mix docs`
- `mix hex.build`

inside the generated package directory.
