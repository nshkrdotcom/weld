# Manifest Reference

Projection manifests are plain Elixir maps.

## Required Keys

- `package_name`
  Public Hex package name for the generated projection.
- `otp_app`
  OTP app name emitted by the generated `mix.exs`.
- `version`
  Version string written into the generated package.
- `mode`
  One of `:library_bundle`, `:strict_library_bundle`, or `:runtime_bundle`.
- `source_projects`
  Relative paths to selected child Mix projects.

## Optional Keys

- `public_entry_modules`
  Declares the intended public API surface for human readers and future tooling.
- `copy.docs`
  Files copied into the generated package and exposed to ExDoc.
- `copy.assets`
  Additional asset paths copied verbatim.
- `copy.priv`
  Reserved for future finer-grained `priv/` control. `:auto` is the current default.
- `docs.main`
  ExDoc main page name, usually `"readme"`.

## Example

```elixir
%{
  package_name: "my_bundle",
  otp_app: :my_bundle,
  version: "0.1.0",
  mode: :strict_library_bundle,
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
    assets: ["guides/assets"],
    priv: :auto
  },
  docs: %{
    main: "readme"
  }
}
```
