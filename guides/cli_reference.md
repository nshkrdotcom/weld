# CLI reference

Use `mix weld help` and `mix weld help COMMAND` for the registry. The public Elixir entry point is `Weld.run/2`. Commands take a schema 2 manifest via `--manifest PATH`, unless discovery is unambiguous. Select an artifact using `--artifact NAME`; `--all` is allowed for supported batch commands. `--format json` emits a `weld.result/2` envelope.

| Command | Principal options or arguments |
| --- | --- |
| `setup` | `--root PATH` |
| `plan`, `graph` | `--artifact NAME`, graph `--format dot` |
| `query` | `deps PROJECT` or `why FROM TO` |
| `affected` | `--base REF --head REF --task verify` |
| `project` | `--kind full` or `--kind live`, `--fresh` |
| `verify`, `prepare` | `--fresh`, artifact selection |
| `status` | artifact and optional `--identity ID` |
| `diff`, `path` | `--kind full`, `live` or `bundle`; optional identity |
| `doctor`, `lint` | repository diagnostics |
| `docs-check` | documentation directory |
| `release-plan` | dependency-ordered artifacts |
| `stage`, `track`, `archive` | `--identity ID` or `--current` |
| `verify-tag` | tag, optional artifact/identity |
| `publish` | explicit identity/current, `--dry-run` or `--yes` |
| `reconcile` | artifact and identity |
| `gc` | dry run by default; `--apply` requests deletion |
| `recover` | inspect interrupted operations |

State paths, machine output and exit codes are breaking changes. Do not call removed dotted tasks.
