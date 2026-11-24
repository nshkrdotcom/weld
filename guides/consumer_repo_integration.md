# Consumer Repo Integration

`Weld` distinguishes two roles:

1. **Source-repository maintainers** who configure a manifest and run `Weld` to project, verify, and prepare artifacts.
2. **Downstream package consumers** who depend on a repository root, a generated projection, a `projection/<package_name>` branch, or a published Hex package using ordinary Mix—**without installing Weld**.

## Integrating Weld In A Source Repository (Maintainers)

- **Workspace-root or isolated maintainer installation:**
  - In workspaces whose root `mix.exs` already coordinates workspace tooling, add `{:weld, "~> 0.15.0", only: [:dev, :test], runtime: false}` to the root `mix.exs`.
  - In `:source_project` repositories where the root `mix.exs` is itself the public library package, you can either add `weld` as a `runtime: false` `:dev/:test` dependency or place `{:weld, "~> 0.15.0", runtime: false}` in a dedicated project such as `tools/maintainer/mix.exs` so the public root `mix.exs` and `mix.lock` carry zero packaging dependencies.
- **Standard manifest locations:** Store the manifest at `build_support/weld.exs`, `build_support/weld_contract.exs`, or a single `packaging/weld/*.exs` so CLI tasks auto-discover it from the checkout root.
- **Initialize `.weld/` once:** Run `mix weld.setup` and commit the `.weld/` entry in `.gitignore` before running clean-tree `mix release.prepare`.
- **Canonical external dependencies:** In `:package_projection` and `:monolith` modes, declare canonical external requirements in `dependencies` whenever workspace subprojects use `:path`, `:git`, or `:github` transports that must be rewritten for publication.
- **Explicit monolith test support:** Declare any non-selected test support projects in `monolith_opts[:test_support_projects]` so `Weld` validates the boundary fail-closed.

### Maintainer Dependency Policy

Keep the committed Weld dependency simple:

- **Steady state:** `{:weld, "~> 0.15.0", only: [:dev, :test], runtime: false}` from Hex.
- **Coordinated pre-release validation:** Bump to a published prerelease such as `0.15.0-rc.1` rather than embedding ad hoc path/Git override logic in every repository.

## Consuming Projections Without Installing Weld

Every projection `Weld` produces is a standard Mix project. Downstream consumers never add `weld` to their dependencies and never invoke `mix weld.*` tasks:

| Target Surface | Typical Use | Consumer Mix Dependency Shape |
| --- | --- | --- |
| Authoritative `:source_project` root | Local checkout or Git revision when the root `mix.exs` owns compilation directly | `{:my_pkg, "~> 0.1.0", path: "../my_pkg"}` or `{:my_pkg, "~> 0.1.0", github: "org/my_pkg", ref: "<sha>"}` |
| Live projection (`.weld/live/<artifact>`) | Local `:source_project` iteration with symlinked source/assets and structural staleness checks | `{:my_pkg, "~> 0.1.0", path: "../my_pkg/.weld/live/my_pkg"}` |
| Refreshable full projection (`.weld/full/<artifact>/project`) | Standalone local Mix verification of a projected package, monolith, or source-project copy | `{:my_pkg, "~> 0.1.0", path: "../my_pkg/.weld/full/my_pkg/project"}` |
| Prepared release project (`.weld/releases/<artifact>/<identity>/project`) | Pinning an immutable, verified local candidate whose bytes will not change during concurrent rebuilds | `{:my_pkg, "~> 0.1.0", path: "../my_pkg/.weld/releases/my_pkg/<identity>/project"}` |
| Tracked projection branch (`projection/<package_name>`) | Consuming a projected standalone package over Git (e.g., from a `:package_projection` workspace) | `{:my_pkg, "~> 0.1.0", github: "org/my_repo", ref: "<projection_sha>"}` |
| Published Hex package | Released versions | `{:my_pkg, "~> 0.1.0"}` |

Note on local path concurrency: plain Mix consumers do not participate in `.weld/.lock`. When multiple processes build against a local projection while maintainers might re-project, prefer an immutable `.weld/releases/<artifact>/<identity>/project` path over the refreshable `.weld/full/` or `.weld/live/` targets.

## Suggested Maintainer CI Shape

```bash
mix deps.get
mix test
mix credo --strict
mix dialyzer
mix weld.agents.verify
mix weld.inspect
mix weld.verify
```

## Suggested Maintainer Release Shape

```bash
mix test
mix credo --strict
mix dialyzer
mix release.prepare
mix release.track
# From .weld/releases/<artifact>/<identity>/project when publishing to Hex:
# mix hex.publish --yes
mix release.archive
```

For internal-only artifacts that intentionally use Git dependencies, set `verify: [hex_build: false]` (or `verify: [hex_publish: false]` when building internal tarballs). `mix release.prepare`, `mix release.track`, and `mix release.archive` work identically without a tarball.
