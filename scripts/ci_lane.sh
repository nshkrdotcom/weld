#!/usr/bin/env bash
# Build isolation only. Blitz owns resource admission and CPU affinity.
set -euo pipefail
source_build=$1
build_root=$2
shift 2
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
exec "$@"
