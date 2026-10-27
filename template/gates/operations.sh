#!/usr/bin/env bash
# Gate `operations` — product-independent, so it is implemented here.
#
# Every check is against an artifact or a live endpoint. Reading the schedule config proves
# the cron was configured; reading last_cron_success from /healthz proves it fired.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate operations'

cd "$PROJECT_DIR" || { bad "cannot enter $PROJECT_DIR"; finish operations; }

# --- /healthz --------------------------------------------------------------------------
# A local target cannot prove a deployed /healthz or a rollback against a previous
# deployment, so those assertions are a declared SKIP in Tier D. The gate keeps running:
# rollback.sh, the ledger and RUNBOOK.md are all provable locally, and verify.sh scores the
# whole gate SKIP, which is not a pass.
ops_host=$(host_of "${APP_URL:-}")
if [ -n "${APP_URL:-}" ] && is_local_host "$ops_host"; then
  note_skip "operations /healthz and rollback verified against local container only, no public URL (Tier D)"
  say "target ${APP_URL} (host $ops_host)"
elif [ -z "${APP_URL:-}" ]; then
  bad 'gate operations has no runnable check: APP_URL must point at the deployed app'
elif ! command -v curl >/dev/null 2>&1; then
  bad 'curl is not on PATH, so /healthz is unprobed'
else
  health_url="${APP_URL%/}/healthz"
  body=$(curl -s -m 20 -o - -w '\nHTTP_STATUS=%{http_code}' "$health_url" 2>/dev/null)
  code=$(printf '%s\n' "$body" | sed -n 's/^HTTP_STATUS=//p' | tail -1)
  body=$(printf '%s\n' "$body" | sed '$d')

  if [ "${code:-000}" = 200 ]; then ok "$health_url returned 200"; else bad "$health_url returned ${code:-no response}"; fi

  # Shape, not just a 200: a literal "ok" body passes a status check and proves nothing.
  printf '%s' "$body" | grep -Eq '"?database"?[[:space:]]*:' \
    && ok '/healthz reports a database check' \
    || bad '/healthz has no database field; a literal 200 is not a health check'

  printf '%s' "$body" | grep -Eq '"?(build_sha|buildSha|sha|revision)"?[[:space:]]*:[[:space:]]*"?[0-9a-f]{7,40}' \
    && ok '/healthz reports a build SHA' \
    || bad '/healthz has no build SHA, so a rollback cannot be confirmed from outside'

  # The field existing proves nothing: any string satisfies a presence check, and a cron
  # dead for years would ship green. `recurrence` delegates its whole deployed half here,
  # so this is the only live proof that the recurring job fires.
  cron_raw=$(printf '%s' "$body" \
    | sed -E -n 's/.*"?last_cron_success"?[[:space:]]*:[[:space:]]*"?([^",}]*).*/\1/p' | tail -1)
  max_age="${CRON_MAX_AGE_SECONDS:-172800}"

  if ! printf '%s' "$body" | grep -Eq '"?last_cron_success"?[[:space:]]*:'; then
    bad '/healthz has no last_cron_success field; the recurring job is unproven in production'
  elif [ -z "$cron_raw" ] || [ "$cron_raw" = null ]; then
    # Null is a legitimate first-deploy value, but a gate cannot pass on it.
    bad 'last_cron_success is null: trigger the job once, then re-run this gate'
  else
    cron_at=$(iso_epoch "$cron_raw")
    if [ -z "$cron_at" ]; then
      bad "last_cron_success is not an ISO-8601 UTC timestamp: $cron_raw"
    else
      age=$(( $(date -u '+%s') - cron_at ))
      if [ "$age" -le "$max_age" ]; then
        ok "last_cron_success is ${age}s old (limit ${max_age}s)"
      else
        bad "last_cron_success is ${age}s old, over the ${max_age}s limit: the recurring job is not firing"
      fi
    fi
  fi
fi

# --- reversibility and rollback ---------------------------------------------------------
file_present "$PROJECT_DIR/rollback.sh" \
  && { [ -x "$PROJECT_DIR/rollback.sh" ] && ok 'rollback.sh is executable' || bad 'rollback.sh is not executable'; }

teardown="${TEARDOWN_SH:-$PROJECT_DIR/teardown.sh}"
ledger="${PROVISIONED_LEDGER:-$PROJECT_DIR/PROVISIONED.md}"

if file_present "$teardown" && file_present "$ledger"; then
  # Dry run only. A gate must never destroy the thing it is checking.
  expected=$(awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { FS = "|"; have = 0; n = 0 }
    /^[[:space:]]*\|/ {
      if (!have) { if ($0 ~ /[Tt]eardown/) have = 1; next }
      if ($0 ~ /^[[:space:]]*\|[[:space:]]*:?-/) next
      if (trim($2) != "") n++
    }
    END { print n + 0 }
  ' "$ledger")

  dry=$(sh -c "'$teardown' --dry-run --ledger '$ledger'" 2>&1)
  dry_status=$?
  enumerated=$(printf '%s\n' "$dry" | grep -Ec '^row ')

  printf '  RUN   %s --dry-run --ledger %s\n' "$teardown" "$ledger"
  if [ "$dry_status" -eq 0 ] && [ "$enumerated" -eq "$expected" ] && [ "$expected" -gt 0 ]; then
    ok "teardown.sh --dry-run enumerated all $expected ledger row(s)"
  else
    bad "teardown.sh --dry-run enumerated $enumerated of $expected ledger row(s), exit $dry_status"
    printf '%s\n' "$dry"
  fi
fi

# --- RUNBOOK.md ------------------------------------------------------------------------
runbook="${RUNBOOK:-$PROJECT_DIR/RUNBOOK.md}"
if file_present "$runbook"; then
  contains "$runbook" 'deploy'                               'RUNBOOK covers deploy'
  contains "$runbook" 'roll ?back|rollback'                  'RUNBOOK covers roll back'
  contains "$runbook" 'live (billing|mode|key)|flip to live' 'RUNBOOK covers flipping to live billing'
  contains "$runbook" 'rotate'                               'RUNBOOK covers rotating a secret'
  contains "$runbook" 'restore'                              'RUNBOOK covers restoring a backup'
  contains "$runbook" 'stuck webhook|webhook.*(stuck|replay|dead)' 'RUNBOOK covers a stuck webhook'
  contains "$runbook" 'cost spike|spend spike|cost.*(spike|runaway)' 'RUNBOOK covers a cost spike'
fi

say 'the kill switch and the verified database backup are asserted by the product suite:'
say 'FEATURE_KILL serves maintenance, halts cron, and still answers billing webhooks 200.'
delegate operations "${OPERATIONS_TEST_CMD:-pnpm test:gate:operations}"

finish operations
