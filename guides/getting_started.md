# Getting started

Use Weld 0.20.0 as a maintainer-only Mix dependency (`{:weld, "~> 0.20.0", runtime: false}`). After resolving dependencies, declare the workspace in `build_support/weld.exs`, run `mix weld setup`, and commit the ignore rule. Start with `mix weld plan --artifact NAME --format json` and inspect the dependency closure and inventory. Run `mix weld project --artifact NAME --kind live` for editing and `--kind full` for a detached project. Run `mix weld verify --artifact NAME` before preparing a release.

See [the manifest reference](manifest_reference.md) and [the command reference](cli_reference.md). Do not put `.weld/v2` under version control.
