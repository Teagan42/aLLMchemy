#!/usr/bin/env bash
# Codex launcher. Codex has no Stop hook, so the no-questions guard is enforced here:
# run non-interactively, apply the shared detector to the final message, and re-prompt with
# the decision ladder if the run tried to interrogate the user.
#
# Codex exec is already headless — a question there just ends the turn silently, which is
# the deadlock this wrapper converts back into progress.
#
# Flag names move between Codex versions. Override with CODEX_BIN and CODEX_FLAGS rather
# than editing this file, and check `codex exec --help` if a flag is rejected.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CODEX_BIN="${CODEX_BIN:-codex}"
MAX_RETRIES="${MAX_RETRIES:-3}"
# A typo would make the `-ge` below error instead of compare, and the correction loop then
# never breaks: an unbounded spend loop on an unattended run.
case "$MAX_RETRIES" in ''|*[!0-9]*) MAX_RETRIES=3 ;; esac
OUT="${OUT:-artifacts/codex-run.log}"
# Follows OUT. A LAST with its own hard-coded directory breaks the detector's input silently
# the moment OUT is overridden.
LAST="$(dirname "$OUT")/.last-turn"
mkdir -p "$(dirname "$OUT")"

command -v "$CODEX_BIN" >/dev/null 2>&1 || { echo "codex not found; set CODEX_BIN" >&2; exit 1; }

# Full autonomy. Without it Codex pauses for command approval, which is a human
# interaction by another name and will hang an unattended run.
DEFAULT_FLAGS="--dangerously-bypass-approvals-and-sandbox"
FLAGS="${CODEX_FLAGS-$DEFAULT_FLAGS}"

# Probe both version-dependent features once, up front. Capture --help into a variable
# rather than piping to grep: under pipefail a SIGPIPE'd codex would fail the probe.
RESUME_OK=0
RESUME_HELP=$("$CODEX_BIN" exec resume --last --help 2>&1) && RESUME_OK=1
LAST_MSG_OK=0
HELP=$("$CODEX_BIN" exec --help 2>&1 || true)
case "$HELP" in *--output-last-message*) LAST_MSG_OK=1 ;; esac
# Probed separately: a version that takes the flag on `exec` but not on `exec resume` would
# fail every correction turn, and the flag is passed on resume turns too.
RESUME_LAST_MSG_OK=0
[ "$RESUME_OK" = 1 ] && case "$RESUME_HELP" in *--output-last-message*) RESUME_LAST_MSG_OK=1 ;; esac

PROMPT=$(cat <<'EOF'
Read AGENTS.md, then playbook/00-kickoff.md, and execute the run described there.
No human is available. Never ask a question; resolve every unknown with the decision
ladder in playbook/autonomy-contract.md and record it in DECISIONS.md.
EOF
)

CORRECTION=$(cat <<'EOF'
Your last message asked the user something. No human will answer; the run would hang.

Re-read playbook/autonomy-contract.md and resolve it yourself:
  1. intake.yaml answer
  2. documented default in the owning playbook document
  3. cheapest reversible option
  4. record the assumption in DECISIONS.md and proceed

If it is a genuine external blocker, append a BLOCKER entry to HANDOFF.md with exact
remediation steps, finish every unblocked part of the scope, and report as statements
only. Continue the run now; do not ask anything.
EOF
)

CONTINUE_NOTE=$(cat <<'EOF'
Prior work from this run is already in the repo. Read DECISIONS.md and HANDOFF.md first and
continue from the phase they leave off at. Do not restart the run or redo finished phases.
EOF
)

# Sets RC to codex's own exit status. The wrapper's exit code is a CI signal, so a codex
# that died must never reach the clean path.
run() {  # $1 = prompt, $2 = "resume" to continue the prior session
  local prompt=$1 mode=${2:-} resuming=0
  set -- exec
  if [ "$mode" = resume ] && [ "$RESUME_OK" = 1 ]; then set -- exec resume --last; resuming=1; fi
  : > "$LAST"   # Never judge a previous turn if this one writes nothing.
  local want_flag=$LAST_MSG_OK
  [ "$resuming" = 1 ] && want_flag=$RESUME_LAST_MSG_OK
  if [ "$want_flag" = 1 ]; then
    "$CODEX_BIN" "$@" --output-last-message "$LAST" $FLAGS "$prompt" >>"$OUT" 2>&1
    RC=$?
  else
    # Fallback: the tail carries tool calls and file contents, so a turn that merely read
    # playbook/*.md or bin/question-patterns.txt trips the detector on their example
    # questions. Costs a spurious correction cycle per turn; prefer the flag.
    "$CODEX_BIN" "$@" $FLAGS "$prompt" 2>&1 | tee -a "$OUT" | tail -200 > "$LAST"
    RC=${PIPESTATUS[0]}
  fi
  return "$RC"
}

correct() {
  if [ "$RESUME_OK" = 1 ]; then
    run "$CORRECTION" resume
  else
    echo "== 'codex exec resume' unsupported; replaying the prompt with a continue-in-place note ==" >&2
    run "$PROMPT

$CORRECTION

$CONTINUE_NOTE"
  fi
}

# A turn that failed or said nothing is not a clean run. Without this an empty $LAST makes
# the detector exit 1 ("no question"), which the loop below reads as "run complete".
die_if_dead() {
  if [ "$RC" -ne 0 ]; then
    echo "== codex exited $RC; see $OUT ==" >&2
    rm -f "$LAST"
    exit "$RC"
  fi
  if [ ! -s "$LAST" ]; then
    echo "== codex produced no final message; see $OUT ==" >&2
    rm -f "$LAST"
    exit 1
  fi
}

: > "$OUT"
echo "== codex run 1 =="
RC=0
run "$PROMPT"
die_if_dead

# Check, then correct. The check must follow the last correction too: with the check inside
# the loop a correction that landed clean still fell through to exit 1, and MAX_RETRIES=0
# never checked at all.
attempt=0
while :; do
  if ! ./bin/detect-question.sh < "$LAST"; then
    echo "== no question detected; run complete =="
    rm -f "$LAST"
    exit 0
  fi
  [ "$attempt" -ge "$MAX_RETRIES" ] && break
  attempt=$((attempt + 1))
  echo "== question detected; re-prompting ($attempt/$MAX_RETRIES) ==" >&2
  correct
  die_if_dead
done

echo "== still interrogating after $MAX_RETRIES retries; see $OUT ==" >&2
rm -f "$LAST"
exit 1
