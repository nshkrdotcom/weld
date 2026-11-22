#!/usr/bin/env bash
set -eu

export MIX_ENV=test
mix compile

mix test --no-compile &
fast=$!
mix test --no-compile --only integration test/weld/release_test.exs &
release=$!
mix test --no-compile --only integration test/weld/verifier_test.exs &
verify=$!
mix test --no-compile --only integration test/weld/mix_tasks_test.exs test/weld/projector_{monolith,package_mode}_test.exs &
project=$!

status=0
for pid in "$fast" "$release" "$verify" "$project"; do
  wait "$pid" || status=1
done
exit "$status"
