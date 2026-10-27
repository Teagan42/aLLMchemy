#!/usr/bin/env bash
# Gate `legal` — reachable policies, real subprocessors, working export and deletion.
# Delegating: every assertion needs the product's own routes and copy.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate legal'
say 'required assertions: ToS, privacy and refund policy linked from footer and checkout;'
say 'subprocessors and retention matching PRODUCT-SPEC.md; GET /api/account/export complete;'
say 'DELETE /api/account leaving no orphaned rows; consent banner when audience_region is'
say 'eu or global; pricing page stating price, interval, renewal and how to cancel.'

delegate legal "${LEGAL_TEST_CMD:-pnpm test:gate:legal}"

finish legal
