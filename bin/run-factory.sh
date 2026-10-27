#!/usr/bin/env bash
# Factory supervisor. Layer 2 of model failover: per-run.
#
# The gateway (`gateway/up.sh`, `gateway/probe.sh`, `gateway/env.sh`, `gateway/down.sh`) is
# layer 1 and fails a single request over to a local model. It cannot cover the three cases
# this script owns: the harness PROCESS dies, the gateway itself will not start, or the run
# ends with no usable final message. Those hang an unattended run exactly like a question
# does, so they get the same treatment — convert into a recorded decision and continue.
#
# Policy inversion, deliberate: ANY unrecognised failure advances to the next tier. The
# OpenCode launcher treats an unrecognised failure as terminal, and that policy is precisely
# how an unattended run died when nine parallel agents hit an expired AWS SSO token.
#
# One carve-out: a policy or safety refusal stops the run and never advances a tier. See
# run_tier().
#
# The tier chain is data, not control flow. Override it with FACTORY_TIERS, add a tier with
# FACTORY_TIER_FILE. Nothing below needs editing to gain a tier.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
# The run builds the product in WORK; the package's own tooling stays under ROOT. They are
# the same directory in a real run and differ only under bin/test-failover.sh.
WORK="${FACTORY_WORKDIR:-$ROOT}"
mkdir -p "$WORK/artifacts" || exit 1
cd "$WORK" || exit 1

DETECT="$ROOT/bin/detect-question.sh"
GATEWAY_DIR="${GATEWAY_DIR:-$ROOT/gateway}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${FACTORY_CLAUDE_FLAGS---permission-mode bypassPermissions}"

OUT="${OUT:-$WORK/artifacts/factory-run.log}"
RAW="$WORK/artifacts/.harness-raw"
ERRF="$WORK/artifacts/.harness-err"
LAST="$WORK/artifacts/.factory-last-turn"
FAILURE_FILE="$WORK/artifacts/.api-failure"
DECISIONS="$WORK/DECISIONS.md"
HANDOFF="$WORK/HANDOFF.md"

# .claude/hooks/on-api-failure.sh writes here. Exported so the hook lands in WORK even when
# the harness's project dir is elsewhere.
export FACTORY_API_FAILURE_FILE="$FAILURE_FILE"

# A typo would make the `-ge` in run_tier error instead of compare, leaving the correction
# loop unbounded: an unbounded spend loop on an unattended run.
MAX_RETRIES="${MAX_RETRIES:-3}"
case "$MAX_RETRIES" in ''|*[!0-9]*) MAX_RETRIES=3 ;; esac

LOCAL_MODEL="${FACTORY_LOCAL_MODEL:-gpt-oss:20b}"
# Empty means "whatever gateway/env.sh or the ambient environment already selects". A
# hardcoded cloud model id here would rot and silently pin the run to an old model.
CLOUD_MODEL="${FACTORY_CLOUD_MODEL:-}"
# local-opencode is deliberately absent: OpenCode wedges often enough that handing an
# unattended run to it trades one hang for another. Add it with FACTORY_TIERS to opt in.
TIERS="${FACTORY_TIERS:-cloud local-claude}"

# The intake's documented chain must actually steer the run; a field nothing reads is a lie,
# which is what `model_fallback` was before this. Explicit env wins, then intake, then default.
if [ -z "${FACTORY_MODEL_CHAIN:-}" ] && command -v node >/dev/null 2>&1; then
  FACTORY_MODEL_CHAIN=$(node bin/validate-intake.mjs --json 2>/dev/null \
    | sed -E -n 's/.*"model_chain"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
fi
FACTORY_MODEL_CHAIN="${FACTORY_MODEL_CHAIN:-cloud ollama}"
export FACTORY_MODEL_CHAIN

# A wedged harness writes nothing and never returns, so the run waits forever — the same
# permanent hang a question causes. Inactivity is the signal, not wall clock: local
# inference is slow but noisy, while a wedged process is fast and silent.
FACTORY_STALL_SECS="${FACTORY_STALL_SECS:-900}"
FACTORY_POLL_SECS="${FACTORY_POLL_SECS:-15}"
case "$FACTORY_STALL_SECS" in ''|*[!0-9]*) FACTORY_STALL_SECS=900 ;; esac
case "$FACTORY_POLL_SECS" in ''|*[!0-9]*) FACTORY_POLL_SECS=15 ;; esac
[ "$FACTORY_POLL_SECS" -lt 1 ] && FACTORY_POLL_SECS=1

RC=0
CAUSE=
RUNG=0
TOTAL_ATTEMPTS=0
GATEWAY_STARTED=0
STALLED=0

: > "$OUT"
say()  { printf '== %s ==\n' "$*"; printf '== %s ==\n' "$*" >> "$OUT"; }
warn() { printf '== %s ==\n' "$*" >&2; printf '== %s ==\n' "$*" >> "$OUT"; }

cleanup() {
  if [ "$GATEWAY_STARTED" = 1 ] && [ -x "$GATEWAY_DIR/down.sh" ]; then
    "$GATEWAY_DIR/down.sh" >> "$OUT" 2>&1
  fi
  rm -f "$LAST" "$RAW" "$ERRF"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------- the tier chain

# Fields: name|harness|model|mode|launcher|gateway. `gateway` is none, optional or required:
# the cloud tier works without the gateway (it only loses per-request failover), the local
# tiers have no other route to a local model.
tier_table() {
  printf '%s\n' \
    "cloud|claude|$CLOUD_MODEL|delegating|$CLAUDE_BIN|optional" \
    "local-claude|claude|$LOCAL_MODEL|single-context|$CLAUDE_BIN|required" \
    "local-opencode|opencode|$LOCAL_MODEL|single-context|bin/run-opencode.sh|optional"
  if [ -n "${FACTORY_TIER_FILE:-}" ] && [ -f "$FACTORY_TIER_FILE" ]; then
    sed -E '/^[[:space:]]*(#|$)/d' "$FACTORY_TIER_FILE"
  fi
  return 0
}

# Last definition wins, so a FACTORY_TIER_FILE row overrides a built-in of the same name.
tier_field() {  # name, field number
  tier_table | awk -F'|' -v n="$1" -v f="$2" '$1 == n { v = $f } END { printf "%s", v }'
}

launcher_path() {
  case "$1" in
    /*)  printf '%s' "$1" ;;
    */*) printf '%s' "$ROOT/$1" ;;
    *)   command -v "$1" 2>/dev/null ;;
  esac
}

launcher_ok() {
  p=$(launcher_path "$1")
  [ -n "$p" ] && [ -x "$p" ]
}

# Drops unavailable tiers up front so that every DECISIONS.md row can name the tier that
# really took over. bin/run-opencode.sh lives on another branch; absence is normal.
CHAIN=
for t in $TIERS; do
  if [ -z "$(tier_field "$t" 2)" ]; then
    warn "tier $t has no descriptor; skipping"
    continue
  fi
  l=$(tier_field "$t" 5)
  if ! launcher_ok "$l"; then
    say "tier $t unavailable: launcher $l not found; skipping"
    continue
  fi
  CHAIN="$CHAIN $t"
done
CHAIN=${CHAIN# }

next_tier() {
  printf '%s\n' $CHAIN | awk -v c="$1" 'f { printf "%s", $0; exit } $0 == c { f = 1 }'
}

# ---------------------------------------------------------------- prompts

KICKOFF=$(cat <<'EOF'
Read AGENTS.md, then playbook/00-kickoff.md, and execute the run described there.
No human is available. Never ask a question; resolve every unknown with the decision
ladder in playbook/autonomy-contract.md and record it in DECISIONS.md.
EOF
)

CONTINUE_NOTE=$(cat <<'EOF'
Prior work from this run is already in the repo. Read DECISIONS.md and HANDOFF.md first and
continue from the phase they leave off at. Do not restart the run or redo finished phases.
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

# Load-bearing, not advisory. No apostrophes in any heredoc here: bash 3.2 mis-parses one
# inside a command substitution.
SINGLE_CONTEXT_NOTE=$(cat <<'EOF'
Run in the single-threaded execution mode defined in the "Execution modes" section of
AGENTS.md. Adopt each playbook/roles/*.md role yourself, in sequence, following it to its
gate before moving on. Do not dispatch subagents and do not run phases concurrently;
Phase 4 and Phase 5 become sequential. This is a hardware constraint, not a preference:
parallel agents thrash the single KV cache slot of this model server, which destroys the
caching that makes local inference practical (measured 142x difference in time to first
token). Keep DECISIONS.md open as the running record, since there are no subagent reports
to reconstruct from.
EOF
)

# Records the degradation; does not restrict it. Scope stays full.
DEGRADED_NOTE=$(cat <<'EOF'
This run has failed over to a fallback model tier because an earlier tier could not serve
requests. The scope is unchanged: complete the full run through Phase 8. Append a
DECISIONS.md row noting that the build model is a fallback tier, and state the model tier in
HANDOFF.md alongside the outcome tier.
EOF
)

compose_prompt() {  # tier, correcting(0|1)
  notes=
  [ "$(tier_field "$1" 4)" = single-context ] && notes="$SINGLE_CONTEXT_NOTE

"
  [ "$RUNG" -gt 1 ] && notes="$notes$DEGRADED_NOTE

"
  # Notes go first so the resumed prefix stays stable across attempts and keeps its cache.
  if [ "$TOTAL_ATTEMPTS" -eq 0 ]; then
    printf '%s%s\n' "$notes" "$KICKOFF"
  elif [ "$2" = 1 ]; then
    printf '%s%s\n\n%s\n' "$notes" "$CONTINUE_NOTE" "$CORRECTION"
  else
    printf '%s%s\n' "$notes" "$CONTINUE_NOTE"
  fi
}

# ---------------------------------------------------------------- harness invocation

# Points Claude Code at the gateway and forces the tier's model. Sourced rather than
# duplicated: gateway/env.sh owns the base URL, key and context limits.
harness_env() {  # model
  if [ -f "$GATEWAY_DIR/env.sh" ]; then
    set -a
    . "$GATEWAY_DIR/env.sh"
    set +a
  fi
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    # Each of these silently outranks ANTHROPIC_BASE_URL and would send the run straight
    # back to the provider that just failed.
    unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX ANTHROPIC_AUTH_TOKEN \
          ANTHROPIC_SMALL_FAST_MODEL AWS_PROFILE AWS_REGION
    # Local generation runs at 25-27 tok/s. An idle timeout kills legitimate slow turns.
    : "${API_FORCE_IDLE_TIMEOUT:=0}"
    : "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:=1}"
    export API_FORCE_IDLE_TIMEOUT CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
  fi
  if [ -n "$1" ]; then
    export ANTHROPIC_MODEL="$1"
    # Without a haiku-class entry the harness's small-model calls 400 against the gateway.
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-$1}"
  fi
  return 0
}

# Waits on the harness, killing it once it stops writing. Returns 124 on a stall so
# classify() can name the cause instead of guessing from a signal-shaped exit code.
supervise() {  # pid
  s_pid=$1
  s_prev=-1
  s_idle=0
  STALLED=0
  while kill -0 "$s_pid" 2>/dev/null; do
    # Sleep in one-second steps rather than one long poll: a single `sleep $POLL` adds the
    # whole interval to every attempt, since a finished harness is not noticed until it ends.
    s_slept=0
    while [ "$s_slept" -lt "$FACTORY_POLL_SECS" ] && kill -0 "$s_pid" 2>/dev/null; do
      sleep 1
      s_slept=$(( s_slept + 1 ))
    done
    kill -0 "$s_pid" 2>/dev/null || break
    s_now=$(( $(wc -c < "$RAW" 2>/dev/null || echo 0) + $(wc -c < "$ERRF" 2>/dev/null || echo 0) ))
    if [ "$s_now" -ne "$s_prev" ]; then
      s_prev=$s_now
      s_idle=0
      continue
    fi
    s_idle=$(( s_idle + FACTORY_POLL_SECS ))
    [ "$s_idle" -lt "$FACTORY_STALL_SECS" ] && continue
    STALLED=1
    warn "harness silent for ${s_idle}s; killing it and failing this tier over"
    # Negative pid signals the whole group: the harness spawns children, and killing only
    # the shell that exec'd it would orphan them still holding the model and the port.
    kill -TERM -"$s_pid" 2>/dev/null || kill -TERM "$s_pid" 2>/dev/null
    s_grace=0
    while [ "$s_grace" -lt 5 ] && kill -0 "$s_pid" 2>/dev/null; do
      sleep 1
      s_grace=$(( s_grace + 1 ))
    done
    kill -KILL -"$s_pid" 2>/dev/null || kill -KILL "$s_pid" 2>/dev/null
    wait "$s_pid" 2>/dev/null
    return 124
  done
  wait "$s_pid"
  return $?
}

# Monitor mode puts the child in its own process group, which is what makes the watchdog's
# group kill reach the whole tree rather than just the spawning shell.
spawn_watched() {  # command...
  set -m
  ( "$@" ) > "$RAW" 2> "$ERRF" &
  w_pid=$!
  set +m
  supervise "$w_pid"
}

_exec_claude() {  # model, claude args...
  harness_env "$1"
  shift
  exec "$CLAUDE_BIN" $CLAUDE_FLAGS "$@"
}

# Captures ONLY the final assistant message. Feeding the whole event stream to the detector
# trips it on question-shaped lines inside tool output and file contents.
#
# stream-json, not json: a buffered format writes nothing until the turn ends, leaving the
# watchdog unable to tell a working harness from a wedged one.
run_claude() {  # model, prompt, resume(0|1)
  # Copy the arguments out first: `set --` below overwrites the positional parameters.
  model=$1
  resuming=$3
  set -- -p "$2" --output-format stream-json --verbose
  [ "$resuming" = 1 ] && set -- --continue "$@"
  [ -n "$model" ] && set -- --model "$model" "$@"
  spawn_watched _exec_claude "$model" "$@"
  RC=$?
  cat "$ERRF" >> "$OUT" 2>/dev/null
  # Slurped, so one NDJSON stream and one bare object both parse. Prefer the last `result`
  # event; fall back to the last object for a harness that emits a single blob.
  jq -rs '[ .[] | select(type == "object") ]
          | ((map(select(.type == "result")) | last) // last // {})
          | if (.is_error // false) then "" else (.result // "") end' \
     < "$RAW" > "$LAST" 2>/dev/null || : > "$LAST"
  return "$RC"
}

# Contract for a pluggable launcher, since bin/run-opencode.sh lives on another branch:
# prompt as $1, resume signalled by FACTORY_RESUME=1, model in FACTORY_MODEL, final
# assistant message written to FACTORY_LAST_MESSAGE_FILE. Stdout is the fallback and is
# worse — it carries tool output the detector will misread.
_exec_pluggable() {  # launcher, model, prompt, resume(0|1)
  export FACTORY_RESUME="$4" FACTORY_MODEL="$2" FACTORY_LAST_MESSAGE_FILE="$LAST"
  exec "$1" "$3"
}

run_pluggable() {  # launcher, model, prompt, resume(0|1)
  spawn_watched _exec_pluggable "$1" "$2" "$3" "$4"
  RC=$?
  cat "$ERRF" >> "$OUT" 2>/dev/null
  [ -s "$LAST" ] || cp "$RAW" "$LAST" 2>/dev/null || : > "$LAST"
  return "$RC"
}

run_attempt() {  # tier, prompt, resume(0|1)
  : > "$RAW"; : > "$ERRF"; : > "$LAST"
  # A stale breadcrumb from a previous attempt would classify this one.
  rm -f "$FAILURE_FILE"
  TOTAL_ATTEMPTS=$((TOTAL_ATTEMPTS + 1))
  a_harness=$(tier_field "$1" 2)
  a_model=$(tier_field "$1" 3)
  a_launcher=$(launcher_path "$(tier_field "$1" 5)")
  case "$a_harness" in
    claude) run_claude "$a_model" "$2" "$3" ;;
    *)      run_pluggable "$a_launcher" "$a_model" "$2" "$3" ;;
  esac
  # jq prints a bare newline for an empty .result, which `test -s` reads as a real message.
  [ -n "$(tr -d '[:space:]' < "$LAST" 2>/dev/null)" ] || : > "$LAST"
  return "$RC"
}

# ---------------------------------------------------------------- classification

# Narrow on purpose. A false positive here stops a healthy run instead of failing it over.
REFUSAL_RE='(content|usage) polic|safety (polic|filter|system|guideline)|content filter|\brefus(e|ed|al)\b|(violates|violation of) [^.]{0,40}(polic|guideline)|I (can.?t|cannot|will not|won.?t) (help|assist|comply|continue|proceed) with'

breadcrumb_class() {
  [ -s "$FAILURE_FILE" ] || return 1
  sed -E -n 's/^class=([^ ]+).*$/\1/p' "$FAILURE_FILE" | tail -1
}

is_refusal_class() {
  case "$1" in
    content_policy*|content_filter*|refusal*|safety*) return 0 ;;
  esac
  return 1
}

# Last resort, per the priority order. Scoped to the final message and this attempt's own
# error output; the whole log would include earlier tiers and tool noise.
is_refusal_text() {
  t=$( { cat "$LAST"; jq -r '(.result // ""), (.error // "")' < "$RAW"; cat "$ERRF"; } 2>/dev/null )
  [ -n "${t//[[:space:]]/}" ] || return 1
  printf '%s' "$t" | grep -Eqi -- "$REFUSAL_RE"
}

# Priority: the typed breadcrumb, then the exit code (which cannot say why), then text.
# Prints `ok`, `refusal:<source>`, or a cause token. The breadcrumb outranks a clean exit
# because StopFailure only fires when a turn ended on an API error.
classify() {
  # The watchdog outranks everything: we killed the harness, so its exit status is our
  # signal, not its own, and any breadcrumb predates the stall.
  [ "${STALLED:-0}" = 1 ] && { printf 'stalled-no-output'; return 0; }
  c=$(breadcrumb_class) || c=
  if [ -n "$c" ]; then
    if is_refusal_class "$c"; then printf 'refusal:%s' "$c"; else printf '%s' "$c"; fi
    return 0
  fi
  if [ "$RC" -eq 0 ] && [ -s "$LAST" ]; then
    # A finished run closes with a long status report; a refusal is a short apology. The
    # length bound is what keeps a report that merely mentions "refusal" from stopping us.
    if [ "$(wc -c < "$LAST" | tr -d ' ')" -lt 1200 ] && grep -Eqi -- "$REFUSAL_RE" "$LAST"; then
      printf 'refusal:final-message'
      return 0
    fi
    printf 'ok'
    return 0
  fi
  if is_refusal_text; then printf 'refusal:error-text'; return 0; fi
  if [ "$RC" -ne 0 ]; then printf 'exit-%s' "$RC"; return 0; fi
  printf 'empty-final-message'
}

# ---------------------------------------------------------------- audit trail

ensure_decisions() {
  [ -f "$DECISIONS" ] && return 0
  {
    printf '# Decisions\n\n'
    printf '| # | Phase | Question that went unasked | Choice | Ladder rung | Reversal cost |\n'
    printf '|---|-------|---------------------------|--------|-------------|---------------|\n'
  } >> "$DECISIONS"
}

next_decision_number() {
  [ -f "$DECISIONS" ] || { printf 1; return 0; }
  awk -F'|' '/^\|[[:space:]]*[0-9]+[[:space:]]*\|/ { n = $2 + 0 } END { printf "%d", n + 1 }' "$DECISIONS"
}

record_failover() {  # failed tier, cause, successor
  ensure_decisions
  printf '| %s | model-failover | Which model tier continues after `%s` failed (%s)? | `%s` | 2 — tier chain in bin/run-factory.sh | Low: re-run on `%s` once %s clears |\n' \
    "$(next_decision_number)" "$1" "$2" "$3" "$1" "$2" >> "$DECISIONS"
}

# A product built by a local 20B model is a materially different artifact. The outcome tier
# (L/T/D) cannot carry that, so it gets its own line directly under it.
record_model_tier() {  # tier, rung
  line="**Model tier:** \`$1\` — rung $2 of the failover chain ($CHAIN). The primary model tier did not complete this run."
  if [ ! -f "$HANDOFF" ]; then
    printf '# Model tier — `%s`\n\n%s\n' "$1" "$line" > "$HANDOFF"
    return 0
  fi
  tmp="$WORK/artifacts/.handoff.tmp"
  awk -v l="$line" '
    NR == 1 { print; print ""; print l; next }
    /^\*\*Model tier:\*\*/ { next }
    { print }
  ' "$HANDOFF" > "$tmp" && mv "$tmp" "$HANDOFF"
  return 0
}

blocker_header() {  # title
  [ -f "$HANDOFF" ] || printf '# Tier D — no model tier completed the run\n\n' > "$HANDOFF"
  n=$(awk '/^##[[:space:]]+BLOCKER[[:space:]]+[0-9]+/ { n = $3 + 0 } END { printf "%d", n + 1 }' "$HANDOFF")
  printf '\n## BLOCKER %s — %s\n\n' "$n" "$1" >> "$HANDOFF"
}

write_blocker_exhausted() {  # last tier, last cause
  blocker_header "every model tier failed; the run did not complete"
  {
    printf '**Impact:** The run stopped after every tier in the failover chain (%s) failed to\n' "$CHAIN"
    printf 'serve requests. Work completed by earlier phases is still in the repo and DECISIONS.md\n'
    printf 'records each failover with its cause. This invocation deployed nothing.\n\n'
    printf '**Cause:** Last failure was tier `%s` with class `%s`. The supervisor advances on every\n' "$1" "$2"
    printf 'failure class except a policy refusal, so this means no tier was reachable at all.\n\n'
    printf '**Remediation:**\n'
    printf '1. `aws sso login --profile <your profile>` — an expired SSO token is the most common\n'
    printf '   cause and surfaces as class `cloud_credential_error` or `Could not load AWS\n'
    printf '   credentials`. Set `awsAuthRefresh` in your own settings so the harness refreshes it\n'
    printf '   inside its retry budget instead of dying.\n'
    printf '2. `gateway/probe.sh` — confirms the local tier answers. Allow 120s; a cold model load\n'
    printf '   returns nothing before then and that is not a refusal.\n'
    printf '3. `ollama ps` and `curl -s http://localhost:11434/api/tags` — confirms the local model\n'
    printf '   server is up and the model named in `FACTORY_LOCAL_MODEL` is pulled.\n'
    printf '4. Re-run `./bin/run-factory.sh`. Every attempt after the first resumes the session, so\n'
    printf '   finished phases are not redone.\n'
    printf '5. To skip a known-bad tier: `FACTORY_TIERS="local-claude" ./bin/run-factory.sh`.\n\n'
    printf '**Verification that the rest is unaffected:** every attempt output is in\n'
    printf '`artifacts/factory-run.log`; the typed failure classes are in `artifacts/.api-failure`.\n'
    printf '`./bin/test-failover.sh` exercises this supervisor without reaching a model and must\n'
    printf 'still pass.\n'
  } >> "$HANDOFF"
}

write_blocker_refusal() {  # tier, cause
  blocker_header "run stopped by a policy or safety refusal"
  {
    printf '**Impact:** Tier `%s` returned a policy or safety refusal (`%s`) and the run stopped\n' "$1" "$2"
    printf 'there. No further tier was tried. Work completed by earlier phases is still in the repo.\n\n'
    printf '**Cause:** A refusal is a decision about the request, not a transport failure.\n'
    printf 'Re-rolling it on a different model to obtain a different answer is laundering, not\n'
    printf 'failover, so the failover chain is deliberately not applied to this class.\n\n'
    printf '**Remediation:**\n'
    printf '1. Read the refused turn in `artifacts/factory-run.log` and the class in\n'
    printf '   `artifacts/.api-failure`.\n'
    printf '2. Narrow the scope that triggered it — usually a product candidate or a provider\n'
    printf '   action — in `intake.yaml` or `PRODUCT-SPEC.md`, then re-run.\n'
    printf '3. Do not set `content_policy_fallbacks` in the gateway config. It is unset on purpose.\n\n'
    printf '**Verification that the rest is unaffected:** `artifacts/factory-run.log` holds the\n'
    printf 'full transcript of every tier attempted before the refusal.\n'
  } >> "$HANDOFF"
}

# ---------------------------------------------------------------- gateway

gateway_ensure() {  # requirement(none|optional|required), tier
  [ "$1" = none ] && return 0
  if [ ! -x "$GATEWAY_DIR/up.sh" ]; then
    if [ "$1" = required ]; then
      warn "gateway absent at $GATEWAY_DIR; tier $2 has no route to its model"
      return 1
    fi
    say "gateway absent at $GATEWAY_DIR; tier $2 runs without per-request failover"
    return 0
  fi
  [ "$GATEWAY_STARTED" = 1 ] && return 0
  # Set before the call: a half-started gateway still needs down.sh at exit.
  GATEWAY_STARTED=1
  if ! "$GATEWAY_DIR/up.sh" >> "$OUT" 2>&1; then
    warn "gateway up.sh failed"
    [ "$1" = required ] && return 1
    return 0
  fi
  if [ -x "$GATEWAY_DIR/probe.sh" ] && ! "$GATEWAY_DIR/probe.sh" >> "$OUT" 2>&1; then
    warn "gateway probe.sh failed"
    [ "$1" = required ] && return 1
    return 0
  fi
  return 0
}

# ---------------------------------------------------------------- the tier loop

# Returns 0 on a clean completed run, 1 to advance a tier, 2 to stop the whole run.
# CAUSE carries the typed reason.
run_tier() {  # tier
  attempt=0
  # A lower tier's first attempt is still a later attempt of the same run, so it resumes too.
  # Starting over is the expensive failure mode this package documents repeatedly.
  resume=0
  [ "$TOTAL_ATTEMPTS" -gt 0 ] && resume=1
  run_attempt "$1" "$(compose_prompt "$1" 0)" "$resume"
  CAUSE=$(classify)
  case "$CAUSE" in
    # Never advance. Re-rolling a refusal on a different model to get a different answer is
    # laundering, not failover, which is also why the gateway leaves
    # content_policy_fallbacks unset.
    refusal:*) return 2 ;;
    ok) ;;
    *) return 1 ;;
  esac

  # Check, then correct, so the final turn is always evaluated and MAX_RETRIES=0 still
  # checks once. Same structure as bin/run-codex.sh.
  while :; do
    if ! "$DETECT" < "$LAST"; then
      say "no question detected; run complete on tier $1"
      return 0
    fi
    [ "$attempt" -ge "$MAX_RETRIES" ] && break
    attempt=$((attempt + 1))
    warn "question detected; re-prompting ($attempt/$MAX_RETRIES)"
    run_attempt "$1" "$(compose_prompt "$1" 1)" 1
    CAUSE=$(classify)
    case "$CAUSE" in
      refusal:*) return 2 ;;
      ok) ;;
      *) return 1 ;;
    esac
  done
  # A model that will not stop interrogating is unusable for an unattended run. Another tier
  # may comply, so this advances rather than ending the run.
  CAUSE=interrogation-loop
  return 1
}

if [ -z "$CHAIN" ]; then
  warn "no usable tier in FACTORY_TIERS=$TIERS"
  record_failover "none" "no-usable-tier" "none"
  write_blocker_exhausted "none" "no-usable-tier"
  exit 1
fi

set -- $CHAIN
TIER_COUNT=$#
say "tier chain: $CHAIN"

for tier in $CHAIN; do
  RUNG=$((RUNG + 1))
  say "tier $RUNG/$TIER_COUNT: $tier"
  if ! gateway_ensure "$(tier_field "$tier" 6)" "$tier"; then
    CAUSE=gateway-unavailable
  else
    run_tier "$tier"
    case $? in
      0)
        [ "$RUNG" -gt 1 ] && record_model_tier "$tier" "$RUNG"
        exit 0
        ;;
      2)
        warn "tier $tier returned a policy/safety refusal ($CAUSE); stopping without failover"
        write_blocker_refusal "$tier" "$CAUSE"
        exit 1
        ;;
    esac
  fi
  successor=$(next_tier "$tier")
  [ -n "$successor" ] || successor=none
  warn "tier $tier failed ($CAUSE); next tier: $successor"
  record_failover "$tier" "$CAUSE" "$successor"
done

warn "every tier in the chain failed; see $OUT"
write_blocker_exhausted "$tier" "$CAUSE"
exit 1
