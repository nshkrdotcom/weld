# Workflow

1. Edit the declared source projects and their tests, not generated trees.
2. Inspect `mix weld plan`, `mix weld graph`, and `mix weld query deps PROJECT` for the chosen artifact.
3. Materialize with `mix weld project --kind live` or `--kind full`. Refresh structural changes; never publish a live view.
4. Run `mix weld diff --kind full` to compare against the planned inventory. Use `mix weld affected --base BASE --head HEAD --task verify` for change analysis.
5. Verify in an isolated run with `mix weld verify`; prepare with `mix weld prepare` from a clean Git revision.
6. Inspect status and the exact bundle identity. Track, archive or publish that pinned bundle, not a regenerated checkout.

All examples accept `--artifact NAME` and `--manifest PATH` as appropriate. Use `--format json` for scripted results.
