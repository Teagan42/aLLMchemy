#!/usr/bin/env bash
# Gate `recurrence` — the subscription justification. A product that passes every other
# gate and fails this one is a one-time purchase with a recurring charge attached.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate recurrence'
say 'required assertions: fixture output, idempotency across two runs for one period,'
say 'the deployed job endpoint writing a run record, and last_cron_success in /healthz.'

delegate recurrence "${RECURRENCE_TEST_CMD:-pnpm test:gate:recurrence}"

# The deployed half of this gate is checked by gates/operations.sh against $APP_URL. With no
# public URL there is no deployed job endpoint to trigger, so that half is a declared SKIP
# rather than a weakened assertion.
rec_host=$(host_of "${APP_URL:-}")
if [ -z "${APP_URL:-}" ] || is_local_host "$rec_host"; then
  note_skip 'recurrence deployed half unproven: no public URL to trigger the job endpoint against (Tier D)'
fi

finish recurrence
