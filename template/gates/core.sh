#!/usr/bin/env bash
# Gate `core` — unit and integration tests for the thing the user pays for, including a
# failure-mode test per external dependency. Delegating: the product owns the assertions.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate core'
say 'coverage thresholds (>= 80% on src/core and src/billing, 100% of webhook handlers)'
say 'are asserted by the product command, not here — the paths are product-specific.'

delegate core "${CORE_TEST_CMD:-pnpm test:gate:core}"

finish core
