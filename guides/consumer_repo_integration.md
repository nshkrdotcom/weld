# Consumer Repo Integration

Consumer repos should keep repo-local policy in the manifest and keep release
logic thin.

## Recommended Layout

- add `{:weld, "~> 0.6.0", runtime: false}` to the root project
- store manifests under a stable repo-local path such as `packaging/weld/`
- keep artifact-owned tests beside the manifest
- declare canonical external package requirements in the manifest when source
  projects use non-publishable `:path` or SCM transports
- declare source-only monolith test support in
  `monolith_opts[:test_support_projects]` instead of relying on implicit
  projector behavior
- call `weld` from CI or release automation rather than wrapping it in large
  custom shell logic

## Recommended Override Policy

Consumer repos should keep Weld dependency override policy repo-local. A common
shape is:

- local implementation and debugging: `WELD_PATH=../weld`
- shared pre-release validation: `WELD_GIT_REF=<commit_sha>` with an optional
  `WELD_GIT_URL=<repo_url>`
- normal steady-state consumption: Hex `{:weld, "~> 0.6.0", runtime: false}`

That keeps `weld` responsible for projection and verification behavior while
letting each consumer repo choose how aggressively it tracks unreleased Weld
commits.

## Suggested CI Shape

```bash
mix deps.get
mix test
mix credo --strict
mix dialyzer
mix weld.inspect packaging/weld/my_bundle.exs
mix weld.verify packaging/weld/my_bundle.exs
```

## Suggested Release Shape

```bash
mix test
mix credo --strict
mix dialyzer
mix weld.release.prepare packaging/weld/my_bundle.exs
mix weld.release.track packaging/weld/my_bundle.exs
mix hex.publish --yes
mix weld.release.archive packaging/weld/my_bundle.exs
```

If you want tracked generated source before a release, push the default
`projection/<package_name>` branch and consume a pinned commit or prerelease tag
from there. Official release semantics should stay on tags, not on a separate
`releases/*` branch.

For internal-only artifacts, keep `verify.hex_build` and `verify.hex_publish`
explicit in the manifest so CI and release automation skip Hex-only checks by
policy instead of by ad hoc shell branching.

## Integration Rule

If a repo needs bespoke behavior that meaningfully changes how workspace
discovery, selection, projection, or release bundling work, that behavior
should usually be implemented in `weld` itself rather than in repo-local shell
wrappers.
