#!/usr/bin/env bash
# Each Blitz worker owns its build. CPU slots are resource assignments, not a
# second scheduler. A slot lock is held by this shell, not inherited by Mix.
set -euo pipefail
source_build=$1
build_root=$2
slots=$3
shift 3
mkdir -p "$build_root/test"
printf 'Isolating compiled test build: %s\n' "$build_root"
if cp --help 2>/dev/null | grep -q -- '--reflink'; then
  cp -a --reflink=auto "$source_build/." "$build_root/test/"
else
  cp -a "$source_build/." "$build_root/test/"
fi
printf 'Executing:'
printf ' %q' "$@"
printf '\n'
if [[ -z "$slots" ]]; then
  exec "$@"
fi

# Blitz cannot have more live commands than slots. A worker acquires any free
# slot without waiting; the mask is inherited by every child process.
for mask_file in "$slots"/*.cpus; do
  exec {slot_fd}>"${mask_file%.cpus}.lock"
  if flock -n "$slot_fd"; then
    mask=$(cat "$mask_file")
    IFS=, read -r -a cpu_ids <<< "$mask"
    export ERL_FLAGS="+S ${#cpu_ids[@]}:${#cpu_ids[@]}"
    printf 'CPU slot: %s; ERL_FLAGS=%s\n' "$mask" "$ERL_FLAGS"
    taskset -c "$mask" "$@" {slot_fd}>&-
    exit $?
  fi
  exec {slot_fd}>&-
done
printf 'No free CPU slot: Blitz worker budget was exceeded\n' >&2
exit 1
