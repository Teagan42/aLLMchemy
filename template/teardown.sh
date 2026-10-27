#!/usr/bin/env bash
# Destroys every resource in PROVISIONED.md, in reverse creation order.
#
# This is what makes the launchers' bypassed approvals acceptable: full autonomy is
# tolerable only because it is reversible by one command. So the dry run is the default and
# has to be complete enough for a human to audit without reading the ledger themselves.
#
# A row with no teardown command is a ledger defect, not a resource to skip: it means
# something was created that nobody can destroy. So is a row this script cannot parse. Both
# modes exit 1 on either, and both are reported rather than dropped.

set -uo pipefail

ledger='./PROVISIONED.md'
mode=dry

usage() {
  printf 'usage: teardown.sh [--dry-run|--yes] [--ledger PATH]\n'
  printf '  --dry-run  (default) enumerate every row and its teardown command\n'
  printf '  --yes      actually destroy, in reverse order\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) mode=dry ;;
    --yes)     mode=execute ;;
    --ledger)  ledger="${2:?--ledger needs a path}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         printf 'teardown: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f "$ledger" ]; then
  printf 'teardown: FAIL — ledger %s not found. Nothing can be reversed without it.\n' "$ledger" >&2
  exit 1
fi

# Locates the header by name rather than position, so an added column does not shift the
# parse. Emits tab-separated: num, provider, resource, fixed, teardown.
#
# Teardown is the last column, so trailing fields are rejoined: an unescaped `|` inside a
# teardown command would otherwise truncate the command to its first pipe stage.
parse_ledger() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unquote(s) { gsub(/`/, "", s); return trim(s) }
    function lastfield() { return ($NF ~ /^[ \t]*$/) ? NF - 1 : NF }
    function joinfrom(a, b,   s, i) { s = $a; for (i = a + 1; i <= b; i++) s = s "|" $i; return s }
    BEGIN { FS = "|"; have = 0 }
    /^[[:space:]]*\|/ {
      last = lastfield()
      if (!have) {
        for (i = 2; i <= last; i++) {
          k = tolower(trim($i))
          if (k == "#")        c_num = i
          if (k == "provider") c_prov = i
          if (k == "resource") c_res = i
          if (k ~ /^fixed/)    c_fix = i
          if (k == "teardown") c_down = i
        }
        if (c_num && c_prov && c_res && c_fix && c_down) have = 1
        next
      }
      if ($0 ~ /^[[:space:]]*\|[[:space:]]*:?-/) next
      # A blank # cell is a malformed row, not a row to skip. Skipping it is how a
      # provisioned database ends up referenced by nothing that can destroy it.
      if (trim($c_num) == "") { printf "MALFORMED\t%s\t\t\t\n", trim($0); next }
      printf "%s\t%s\t%s\t%s\t%s\n", \
        trim($c_num), trim($c_prov), unquote($c_res), trim($c_fix), unquote(joinfrom(c_down, last))
    }
    END { if (!have) exit 3 }
  ' "$ledger"
}

rows_file=$(mktemp) || exit 1
trap 'rm -f "$rows_file"' EXIT INT TERM

parse_ledger > "$rows_file" 2>/dev/null
parse_status=$?
if [ "$parse_status" -ne 0 ]; then
  printf 'teardown: FAIL — %s has no row with all of: # Provider Resource "Fixed USD/mo" Teardown\n' "$ledger" >&2
  exit 1
fi

# Read into an indexed array to walk it backwards. bash 3.2 has no mapfile.
i=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  rows[$i]="$line"
  i=$((i + 1))
done < "$rows_file"
total=$i

if [ "$total" -eq 0 ]; then
  printf 'teardown: ledger %s has no rows; nothing was provisioned\n' "$ledger"
  exit 0
fi

printf 'teardown: ledger %s, %s row(s), mode %s\n' "$ledger" "$total" \
  "$([ "$mode" = execute ] && echo 'EXECUTE (destructive)' || echo 'dry run')"
printf 'teardown: reverse creation order\n\n'

missing=0
malformed=0
failed=0
idx=$((total - 1))
while [ "$idx" -ge 0 ]; do
  IFS=$'\t' read -r num provider resource fixed cmd <<EOF
${rows[$idx]}
EOF
  if [ "$num" = MALFORMED ]; then
    printf 'row ?  MALFORMED — cannot be parsed, so it cannot be reversed\n'
    printf '  source   : %s\n\n' "$provider"
    malformed=$((malformed + 1))
    idx=$((idx - 1))
    continue
  fi
  printf 'row %s  %s\n' "$num" "$provider"
  printf '  resource : %s\n' "$resource"
  printf '  fixed    : %s USD/mo\n' "$fixed"

  if [ -z "$cmd" ]; then
    printf '  teardown : MISSING — this resource cannot be reversed\n\n'
    missing=$((missing + 1))
  elif [ "$mode" = dry ]; then
    printf '  teardown : %s\n\n' "$cmd"
  else
    printf '  teardown : %s\n' "$cmd"
    if sh -c "$cmd"; then
      printf '  result   : OK\n\n'
    else
      printf '  result   : FAILED (exit %s) — destroy this one by hand\n\n' "$?"
      failed=$((failed + 1))
    fi
  fi
  idx=$((idx - 1))
done

printf 'teardown: %s row(s) enumerated, %s missing a teardown command, %s malformed\n' \
  "$total" "$missing" "$malformed"

if [ "$mode" = dry ]; then
  # Refuses to destroy without --yes. An unattended run must not trip over this script and
  # delete the product it just shipped.
  printf 'teardown: dry run only, nothing destroyed. Re-run with --yes to execute.\n'
fi
[ "$mode" = execute ] && printf 'teardown: %s command(s) failed\n' "$failed"

[ "$missing" -gt 0 ] && exit 1
[ "$malformed" -gt 0 ] && exit 1
[ "$failed" -gt 0 ] && exit 1
exit 0
