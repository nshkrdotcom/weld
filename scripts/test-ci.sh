#!/usr/bin/env bash
set -euo pipefail

export MIX_ENV=test
mix compile

# Each independent build starts its own BEAM and inherits this scheduler budget.
export ERL_FLAGS="${ERL_FLAGS:-+S 4:4}"

run_group() {
  local name=$1
  shift
  printf '[%s] Starting\n' "$name"

  if mix test --no-compile "$@" 2>&1 | sed -u "s/^/[$name] /"; then
    printf '[%s] Passed\n' "$name"
  else
    printf '[%s] Failed\n' "$name" >&2
    return 1
  fi
}

run_group fast &
pids=("$!")
for build in release formatter internal package runtime monolith prepare_cli monolith_tests package_config; do
  run_group "$build" --trace --only "ci_build:$build" &
  pids+=("$!")
done

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
exit "$status"
