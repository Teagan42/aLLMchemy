#!/usr/bin/env bash
# Gate `billing` — the 17-row matrix in playbook/subscription-billing.md.
#
# Runs the zero-dependency reference suite first, so the semantics are verified even before
# the product's own tests exist. Then delegates to the product suite, which is the only
# thing that can prove the real database, provider adapter and routes behave.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate billing'
say 'all seventeen rows; row 13 (live E2E) is proven by the `stranger-path` gate, not here.'
say 'non-negotiable subset: rows 2 (duplicate delivery, one state change), 3 (tampered'
say 'signature, 400), 11 (quota exceeded, graceful denial), 14 (apply fails, provider'
say 'retries), 15 (concurrent deliveries) and 7 (cancel then revoke at period end).'
say 'The daily reconciler is part of this gate: without it no row ever flips after the'
say 'period ends and no dead-lettered paid event is ever replayed.'

reference="$TEMPLATE_DIR/billing-core/test"
if [ -d "$reference" ]; then
  if command -v node >/dev/null 2>&1; then
    # Glob, not the directory: `node --test <dir>` is unsupported before Node 23 and
    # resolves the path as a module instead, which fails with MODULE_NOT_FOUND.
    run_sh "node --test '$reference'/*.test.mjs"
  else
    bad 'node is not on PATH, so the billing reference suite cannot run'
  fi
else
  # billing-core is ported rather than copied, so this is the expected state in a generated
  # repo. It still cannot be a silent `say`: a double-charge is a never-downgradable
  # failure, and without the reference suite the product's own test is the only proof. So
  # the port has to declare which matrix rows it covers, and the gate checks the list.
  manifest="${BILLING_MATRIX_MANIFEST:-$PROJECT_DIR/billing-matrix.txt}"
  say "reference suite absent at $reference (ported into the product)"
  if [ ! -f "$manifest" ]; then
    bad "no billing-core reference suite and no matrix manifest at $manifest. List the matrix rows the ported suite covers (1-12, 14-17), one per line, or set BILLING_MATRIX_MANIFEST."
  else
    missing=''
    for row in 1 2 3 4 5 6 7 8 9 10 11 12 14 15 16 17; do
      grep -Eq "(^|[^0-9])${row}([^0-9]|\$)" "$manifest" || missing="$missing $row"
    done
    if [ -n "$missing" ]; then
      bad "matrix manifest $manifest does not cover row(s):$missing"
    else
      ok "matrix manifest $manifest covers all sixteen non-E2E rows"
    fi
  fi
fi

delegate billing "${BILLING_TEST_CMD:-pnpm test:gate:billing}"

# The reconciler is the only thing that flips a row after the period ends and the only thing
# that replays an event that never applied, and the playbook calls it required. Nothing used
# to assert it exists, so a product could ship with no sweep and pass every billing test —
# access still revokes on time because can() reads dates, while no row ever flips.
reconciler="${RECONCILER:-}"
if [ -n "$reconciler" ]; then
  file_present "$reconciler"
elif [ -d "$PROJECT_DIR/src" ]; then
  if find "$PROJECT_DIR/src" -type f -iname '*reconcil*' 2>/dev/null | grep -q .; then
    ok 'reconciler source present under src/'
  else
    bad 'no reconciler found under src/: set $RECONCILER, or the drift sweep does not exist'
  fi
else
  bad 'no src/ to look for the reconciler in, and $RECONCILER is unset'
fi

# Scheduled, not merely written. A reconciler nobody runs is the safety net on the floor.
sched=$(find "$PROJECT_DIR" -maxdepth 2 \
  \( -name 'fly.toml' -o -name 'vercel.json' -o -name 'render.yaml' -o -name 'railway.json' \
     -o -name 'crontab' -o -name '*.cron' -o -name 'wrangler.toml' \) 2>/dev/null)
if [ -n "$sched" ] && printf '%s\n' "$sched" | xargs grep -liE 'reconcil|cron|schedule' 2>/dev/null | grep -q .; then
  ok 'a schedule config references a recurring job'
else
  bad 'no schedule config registers the daily reconciler; the `operations` gate proves it fired'
fi

finish billing
