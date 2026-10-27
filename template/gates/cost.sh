#!/usr/bin/env bash
# Gate `cost` — product-independent, so it is implemented here.
#
# An asserted budget that is never summed against what was actually created is not a
# ceiling. PROVISIONED.md is the only thing that makes `monthly_infra_budget_usd` real, so
# this gate parses it rather than trusting a claim about it.
#
# The Usage risk column is parsed, not merely required to exist: "never enable usage-based
# autoscaling without a provider-side spend cap" is unenforceable if nothing reads the cell.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate cost'

# Intake `monthly_infra_budget_usd` arrives as $MONTHLY_INFRA_BUDGET_USD. A silent default
# would pass a $20 resource against 25 when the operator asked for 5, so the intake file is
# read when the variable is unset and a missing value is a FAIL rather than a guess.
budget="${MONTHLY_INFRA_BUDGET_USD:-}"
intake="${INTAKE_FILE:-$PROJECT_DIR/intake.yaml}"
if [ -z "$budget" ] && [ -f "$intake" ]; then
  budget=$(sed -E -n 's/^[[:space:]]*monthly_infra_budget_usd:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' "$intake" | tail -1)
  [ -n "$budget" ] && say "budget from $intake"
fi
if [ -z "$budget" ]; then
  bad 'no budget to sum against: export MONTHLY_INFRA_BUDGET_USD or set monthly_infra_budget_usd in intake.yaml'
  finish cost
fi

ledger="${PROVISIONED_LEDGER:-$PROJECT_DIR/PROVISIONED.md}"

if ! file_present "$ledger"; then
  bad 'without the ledger nothing was summed against the budget, so the budget is not a ceiling'
  finish cost
fi

# Reports the fixed total, then every defect, then exits. Column lookup is by header name so
# an added column does not shift the parse; a missing required header is a FAIL, because a
# ledger this script cannot read is a ledger nobody is checking.
summary=$(awk -v budget="$budget" '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function lastfield() { return ($NF ~ /^[ \t]*$/) ? NF - 1 : NF }
  BEGIN { FS = "|"; have = 0; rows = 0; total = 0; converts = 0 }
  /^[[:space:]]*\|/ {
    last = lastfield()
    if (!have) {
      for (i = 2; i <= last; i++) {
        k = tolower(trim($i))
        if (k == "#")        c_num = i
        if (k == "provider") c_prov = i
        if (k == "resource") c_res = i
        if (k ~ /^fixed/)    c_fix = i
        if (k ~ /^usage/)    c_use = i
        if (k == "teardown") c_down = i
      }
      if (c_num && c_prov && c_res && c_fix && c_use && c_down) have = 1
      next
    }
    if ($0 ~ /^[[:space:]]*\|[[:space:]]*:?-/) next
    # A row with no number is still a resource somebody created. Skipping it silently is how
    # a provisioned database ends up in neither the sum nor the teardown.
    if (trim($c_num) == "") {
      rows++
      printf "DEFECT\ta ledger row has a blank # cell, so it cannot be summed or reversed: %s\n", trim($0)
      next
    }

    rows++
    fixed = trim($c_fix)
    if (fixed !~ /^[0-9]+(\.[0-9]+)?$/) {
      printf "DEFECT\trow %s fixed monthly price is not a number: \"%s\"\n", trim($c_num), fixed
    } else {
      total += fixed + 0
    }
    teardown = trim($c_down)
    for (i = c_down + 1; i <= last; i++) teardown = teardown trim($i)
    if (teardown == "") {
      printf "DEFECT\trow %s (%s, %s) has no teardown command\n", trim($c_num), trim($c_prov), trim($c_res)
    }

    # Controlled vocabulary, because free prose cannot be checked. Metered spend with no
    # provider-side cap is the failure mode that empties an account overnight.
    risk = tolower(trim($c_use))
    if (risk ~ /^none/ || risk ~ /capped[ -]/ || risk ~ /^capped$/) {
      ;
    } else if (match(risk, /provider-cap:[0-9]+(\.[0-9]+)?/)) {
      ;
    } else if (match(risk, /converts-to:[0-9]+(\.[0-9]+)?/)) {
      c = substr(risk, RSTART, RLENGTH)
      sub(/converts-to:/, "", c)
      converts += c + 0
    } else {
      printf "DEFECT\trow %s usage risk names no ceiling: \"%s\". Use none, capped-at-tier, provider-cap:<amount> or converts-to:<amount>\n", trim($c_num), trim($c_use)
    }
  }
  END {
    if (!have) { print "NOHEADER"; exit 0 }
    printf "ROWS\t%d\n", rows
    printf "TOTAL\t%.2f\n", total
    printf "CONVERTS\t%.2f\n", converts
    if (total > budget + 0.0001) {
      printf "DEFECT\tfixed monthly total %.2f exceeds budget %.2f\n", total, budget
    } else if (total + converts > budget + 0.0001) {
      printf "DEFECT\tceiling %.2f (fixed %.2f plus %.2f converting to paid) exceeds budget %.2f\n", total + converts, total, converts, budget
    }
  }
' "$ledger")

if printf '%s\n' "$summary" | grep -q '^NOHEADER$'; then
  bad "$ledger has no header row with all of: # Provider Resource \"Fixed USD/mo\" \"Usage risk\" Teardown"
  finish cost
fi

rows=$(printf '%s\n' "$summary" | awk -F'\t' '$1 == "ROWS" { print $2 }')
total=$(printf '%s\n' "$summary" | awk -F'\t' '$1 == "TOTAL" { print $2 }')
converts=$(printf '%s\n' "$summary" | awk -F'\t' '$1 == "CONVERTS" { print $2 }')
say "ledger $ledger"
say "rows: ${rows:-0}"
say "fixed monthly total: ${total:-0.00} USD, converting to paid: ${converts:-0.00} USD, budget ${budget} USD"

# A ledger with a header and no rows sums nothing. Either nothing was provisioned — in which
# case the deploy did not happen — or the ledger was never written.
if [ "${rows:-0}" -eq 0 ]; then
  bad 'ledger has no rows: nothing was summed against the budget, and nothing can be torn down'
  finish cost
fi

defects=$(printf '%s\n' "$summary" | awk -F'\t' '$1 == "DEFECT" { print $2 }')
if [ -n "$defects" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] && bad "$d"
  done <<EOF
$defects
EOF
else
  ok "every row has a teardown command and the fixed total is within budget"
fi

# Product-selection gate G4 is a unit-economics ceiling, and a self-reported verdict in
# PRODUCT-SPEC.md is not a check. The spec has to carry the figure in a parseable line so
# this gate can compare it against 20% of the price.
spec="${PRODUCT_SPEC:-$PROJECT_DIR/PRODUCT-SPEC.md}"
if file_present "$spec"; then
  cogs=$(sed -E -n 's/.*per-user COGS:[[:space:]]*\$?([0-9]+(\.[0-9]+)?).*/\1/p' "$spec" | tail -1)
  price=$(sed -E -n 's/^[[:space:]]*price_usd:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' "$intake" 2>/dev/null | tail -1)
  price="${PRICE_USD:-${price:-5}}"
  if [ -z "$cogs" ]; then
    bad "$spec has no \`per-user COGS: <amount>\` line, so G4's unit-economics ceiling is self-reported prose"
  else
    verdict=$(awk -v c="$cogs" -v p="$price" 'BEGIN { print (c <= p * 0.20 + 0.0001) ? "ok" : "over" }')
    if [ "$verdict" = ok ]; then
      ok "per-user COGS $cogs USD is within 20% of the $price USD price"
    else
      bad "per-user COGS $cogs USD exceeds 20% of the $price USD price: G4 fails, the margin is not there"
    fi
  fi
fi

# The other half of the gate is the per-user quota, which only the product can prove: an
# unenforced quota is not a cost control, so the denial path needs a test.
delegate cost "${COST_TEST_CMD:-pnpm test:gate:cost}"

say 'that suite must also assert: the PRODUCT-SPEC.md per-user cost model matches what the'
say 'code can consume, the quota is checked before the expensive call, the daily cost log'
say 'line emits, and projected cost at 1,000 users stays within the same budget.'

finish cost
