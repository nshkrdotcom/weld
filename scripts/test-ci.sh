#!/usr/bin/env bash
set -euo pipefail

export MIX_ENV=test
mix compile

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
fast=$!
run_group release --trace --only integration test/weld/release_test.exs &
release=$!
run_group verifier --trace --only integration test/weld/verifier_test.exs &
verify=$!
run_group projection --trace --only integration test/weld/mix_tasks_test.exs test/weld/projector_{monolith,package_mode}_test.exs &
project=$!

status=0
for pid in "$fast" "$release" "$verify" "$project"; do
  wait "$pid" || status=1
done
exit "$status"
