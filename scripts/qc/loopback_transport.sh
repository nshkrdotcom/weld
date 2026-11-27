#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
exec env MIX_ENV=test mix test --warnings-as-errors test/weld/hex_transport_contract_test.exs test/weld/hex_publication_fault_test.exs test/weld/release_workflow_018_test.exs test/weld/hex_archive_contract_test.exs test/weld/runner_contract_test.exs
