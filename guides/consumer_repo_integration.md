# Consumer Repo Integration

The consumer repo should stay thin. `Weld` should own the projection logic.

## Recommended Integration Shape

- add `{:weld, "~> 0.1.0", runtime: false}` to the root project
- add one or more manifests under `packaging/hex_projections/`
- invoke `mix weld.audit`, `mix weld.build`, and `mix weld.verify` from CI
- keep repo-specific behavior in manifest data, not in shell scripts

## Suggested CI Sequence

```bash
mix deps.get
mix test
mix weld.audit packaging/hex_projections/jido_integration.exs
mix weld.verify packaging/hex_projections/jido_integration.exs
```

## Design Rule

If a consumer repo needs large custom projection logic, the `Weld` API surface
is still wrong. The repo should contribute new general behavior back into
`Weld` rather than forking the projection pipeline locally.
