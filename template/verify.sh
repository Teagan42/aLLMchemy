#!/usr/bin/env bash
# The gate runner. Contract in playbook/acceptance-gates.md.
#
#   ./verify.sh                  all gates, exit 0 only if all pass
#   ./verify.sh --gate billing   one gate
#   ./verify.sh --list           gate names
#
# A subagent reporting success does not pass a gate. Only this script does, and only by
# exit code. That is the load-bearing rule of the whole package: self-reported completion
# is where unattended runs quietly ship broken products.
#
# Extend the gates under gates/. Do not reinvent this runner — a hand-rolled one is where
# the "exit 0 only if all pass" rule gets broken by accident.

set -uo pipefail

GATES='build core recurrence billing security legal operations cost stranger-path'

# Reserved exit code for "I could not run, and here is the BLOCKER". A gate may also
# request a skip by printing a line beginning `SKIP: ` at column zero.
SKIP_EXIT=77

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ARTIFACT_DIR="${ARTIFACT_DIR:-./artifacts}"

usage() {
  printf 'usage: verify.sh [--gate NAME | --list]\n\n'
  printf 'gates, in run order:\n'
  for g in $GATES; do printf '  %s\n' "$g"; done
  printf '\nexit 0 only when every gate PASSed. A SKIP is not a pass.\n'
}

only=''
while [ $# -gt 0 ]; do
  case "$1" in
    --list)    for g in $GATES; do printf '%s\n' "$g"; done; exit 0 ;;
    --gate)    only="${2:?--gate needs a name}"; shift ;;
    --gate=*)  only="${1#--gate=}" ;;
    -h|--help) usage; exit 0 ;;
    *)         printf 'verify: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$only" ]; then
  matched=0
  for g in $GATES; do [ "$g" = "$only" ] && matched=1; done
  if [ "$matched" -eq 0 ]; then
    printf 'verify: no gate named %s. The nine are: %s\n' "$only" "$GATES" >&2
    exit 2
  fi
  GATES="$only"
fi

mkdir -p "$ARTIFACT_DIR" || { printf 'verify: cannot create %s\n' "$ARTIFACT_DIR" >&2; exit 2; }
stamp=$(date -u '+%Y%m%dT%H%M%SZ')
artifact="$ARTIFACT_DIR/verify-$stamp.txt"
# Second granularity collides inside a repair loop, and the failing run's output is the one
# record of what broke. Never clobber: verify-latest.txt already covers "most recent".
n=1
while [ -e "$artifact" ]; do
  artifact="$ARTIFACT_DIR/verify-$stamp-$n.txt"
  n=$((n + 1))
done
summary=$(mktemp) || exit 2
gate_out=$(mktemp) || exit 2
trap 'rm -f "$summary" "$gate_out"' EXIT INT TERM

{
  printf 'verify run %s\n' "$stamp"
  printf 'project  %s\n' "$PWD"
  printf 'runner   %s\n' "$0"
  printf 'gates    %s\n\n' "$GATES"
} > "$artifact"

env_key() { printf 'GATE_SKIP_%s' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"; }

for gate in $GATES; do
  script="$ROOT/gates/$gate.sh"
  cmd="$script"
  key=$(env_key "$gate")
  eval "declared_skip=\${$key:-}"

  started=$(date -u '+%H:%M:%S')

  if [ ! -f "$script" ]; then
    status=FAIL
    blocker="gate script missing: $script"
    : > "$gate_out"
    printf '%s\n' "$blocker" > "$gate_out"
    code=127
  elif [ -n "$declared_skip" ]; then
    # Declared in the environment, so the gate is not run at all.
    status=SKIP
    blocker="$declared_skip"
    printf 'not run: %s=%s\n' "$key" "$declared_skip" > "$gate_out"
    code=0
  else
    # Run the script directly, never through `sh -c "$cmd"`: a template path containing a
    # space would word-split there and every gate would fail with a bare exit 127 that
    # looks like a broken gate rather than a bad path. `cmd` stays the display string.
    if [ -x "$script" ]; then
      "$script" > "$gate_out" 2>&1
    else
      cmd="bash $script"
      bash "$script" > "$gate_out" 2>&1
    fi
    code=$?
    reason=$(sed -n 's/^SKIP:[[:space:]]*//p' "$gate_out" | tail -1)

    if [ "$code" -eq 0 ] && [ -z "$reason" ]; then
      status=PASS
      blocker=''
    elif [ -n "$reason" ] && { [ "$code" -eq 0 ] || [ "$code" -eq "$SKIP_EXIT" ]; }; then
      status=SKIP
      blocker="$reason"
    elif [ "$code" -eq "$SKIP_EXIT" ]; then
      # An unexplained skip counts as a failure. Otherwise "no check was written" and
      # "the check passed" produce the same report.
      status=FAIL
      blocker="skipped without naming a BLOCKER (exit $SKIP_EXIT, no 'SKIP: <reason>' line)"
    else
      status=FAIL
      blocker="exit $code"
    fi
  fi

  printf '%s\t%s\t%s\t%s\n' "$gate" "$status" "$code" "$blocker" >> "$summary"

  {
    printf -- '----------------------------------------------------------------------\n'
    printf 'gate     %s\n' "$gate"
    printf 'status   %s\n' "$status"
    printf 'command  %s\n' "$cmd"
    printf 'exit     %s\n' "$code"
    printf 'started  %sZ\n' "$started"
    # BLOCKER is reserved for a SKIP: the contract is that a skip names one.
    [ "$status" = SKIP ] && printf 'BLOCKER  %s\n' "$blocker"
    [ "$status" = FAIL ] && printf 'detail   %s\n' "$blocker"
    # Full output for failures and skips only. A passing gate's output is noise that
    # buries the one thing a reader came for.
    if [ "$status" = PASS ]; then
      printf 'output   suppressed (passed)\n'
    else
      printf 'output\n'
      sed 's/^/  | /' "$gate_out"
    fi
    printf '\n'
  } >> "$artifact"

  printf '%-14s %s\n' "$gate" "$status"
  [ "$status" = PASS ] || sed 's/^/    /' "$gate_out"
done

passed=$(awk -F'\t' '$2 == "PASS" { n++ } END { print n + 0 }' "$summary")
total=$(awk 'END { print NR + 0 }' "$summary")

table=$(
  printf '| Gate | Status | Exit | BLOCKER / detail |\n'
  printf '|---|---|---|---|\n'
  awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, ($4 == "" ? "—" : $4) }' "$summary"
  printf '\n%s of %s gate(s) passed.\n' "$passed" "$total"
)

printf '\n%s\n' "$table"
printf 'artifact: %s\n' "$artifact"

{ printf -- '----------------------------------------------------------------------\n'; printf '%s\n' "$table"; } >> "$artifact"

# playbook/autonomy-contract.md cites this path in the BLOCKER template, so keep it current.
cp "$artifact" "$ARTIFACT_DIR/verify-latest.txt" 2>/dev/null

# A SKIP is not a pass. It is an explained non-pass: route it to HANDOFF.md as a BLOCKER,
# where a FAIL is routed to its owning agent for repair.
[ "$passed" -eq "$total" ] || exit 1
exit 0
