# Consumer Repo Integration

Consumer repos should keep repo-local policy in the manifest and keep release
logic thin.

## Recommended Layout

- add `{:weld, "~> 0.7.1", runtime: false}` to the root project
- store manifests under a stable repo-local path such as `packaging/weld/`
- keep artifact-owned tests beside the manifest
- declare canonical external package requirements in the manifest when source
  projects use non-publishable `:path` or SCM transports
- declare source-only monolith test support in
  `monolith_opts[:test_support_projects]` instead of relying on implicit
  projector behavior
- call `weld` from CI or release automation rather than wrapping it in large
  custom shell logic

## Consumer Dependency Policy

Consumer repos should keep the committed dependency line simple:

- committed steady state: Hex `{:weld, "~> 0.7.1", runtime: false}`
- coordinated pre-release validation: bump to a Weld prerelease such as
  `0.7.1-rc.1`
- avoid baking repo-local path/git override logic into every consumer repo

That keeps `weld` responsible for projection and verification behavior without
making every consumer repo carry custom dependency-resolution code.

Consumer repos should also prefer the standard manifest locations:

- `build_support/weld.exs`
- `build_support/weld_contract.exs`
- a single manifest under `packaging/weld/`

With that layout, repos can call `mix weld.inspect`, `mix weld.verify`,
`mix release.prepare`, `mix release.track`, and `mix release.archive` directly
without maintaining a root alias block that only forwards the manifest path and
artifact name.

## Suggested CI Shape

```bash
mix deps.get
mix test
mix credo --strict
mix dialyzer
mix weld.inspect
mix weld.verify
```

## Suggested Release Shape

```bash
mix test
mix credo --strict
mix dialyzer
mix release.prepare
mix release.track
mix hex.publish --yes
mix release.archive
```

If you want tracked generated source before a release, push the default
`projection/<package_name>` branch and consume a pinned commit or prerelease tag
from there. Official release semantics should stay on tags, not on a separate
`releases/*` branch.

For internal-only artifacts, keep `verify.hex_build` and `verify.hex_publish`
explicit in the manifest so CI and release automation skip Hex-only checks by
policy instead of by ad hoc shell branching. `weld.release.prepare`,
`weld.release.track`, and `weld.release.archive` still work without a tarball,
and the plain `mix release.*` wrappers call into that same flow.

## Integration Rule

If a repo needs bespoke behavior that meaningfully changes how workspace
discovery, selection, projection, or release bundling work, that behavior
should usually be implemented in `weld` itself rather than in repo-local shell
wrappers.
