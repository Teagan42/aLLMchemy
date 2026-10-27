#!/usr/bin/env bash
# Regression suite for bin/run-factory.sh. Run after editing the tier chain or the
# classifier.
#
# No real model is reached. Every case drives the supervisor with a fake `claude` on PATH
# that replays one scripted outcome per invocation, and a fake gateway directory. A
# self-reported success never passes a gate in this package, and that applies to the
# failover layer itself.
#
# Both directions matter. A tier that fails to advance hangs an unattended run, which is the
# expired-SSO-token failure this layer exists for; a tier that advances on a policy refusal
# is laundering the refusal across models.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
T=

ck() {  # label, got, want
  if [ "$2" = "$3" ]; then printf '  PASS  %-48s %s\n' "$1" "$2"
  else printf '  FAIL  %-48s got %s want %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

write_fake_claude() {
  cat > "$1" <<'FAKE'
#!/usr/bin/env bash
# Fake claude. One scripted outcome per invocation; records argv and the env that reached it.
set -uo pipefail
i=$(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0)
i=$((i + 1))
printf '%s\n' "$i" > "$FAKE_DIR/calls"
printf '%s\n' "$@" > "$FAKE_DIR/argv.$i"
printf 'ANTHROPIC_MODEL=%s\nANTHROPIC_BASE_URL=%s\nAWS_PROFILE=%s\n' \
  "${ANTHROPIC_MODEL:-}" "${ANTHROPIC_BASE_URL:-}" "${AWS_PROFILE:-}" > "$FAKE_DIR/env.$i"
outcome=$(awk -v n="$i" 'NR == n { print }' "$FAKE_SCRIPT")
[ -n "$outcome" ] || outcome=ok
case "$outcome" in
  ok)       printf '{"result":"Deployed to https://x.example. All 9 gates pass. Two blockers are recorded in HANDOFF.md."}\n'; exit 0 ;;
  question) printf '{"result":"Which billing provider would you prefer?"}\n'; exit 0 ;;
  empty)    printf '{"result":""}\n'; exit 0 ;;
  fail)     printf 'Could not load AWS credentials\n' >&2; exit 1 ;;
  weird)    printf 'ouroboros\n' >&2; exit 99 ;;
  refusal)  printf '{"result":"I cannot help with that. The request violates the content policy."}\n'; exit 0 ;;
  # Wedged: never returns, never writes. The failure mode a wall-clock cap cannot tell from
  # legitimately slow local inference.
  hang)     sleep 600; exit 0 ;;
  # Slow but productive. Must survive the watchdog: emits NDJSON events, then a result.
  slow)     for _ in 1 2 3 4; do printf '{"type":"system","subtype":"tool_use"}\n'; sleep 1; done
            printf '{"type":"result","result":"All 9 gates pass. Deployed to https://x.example."}\n'
            exit 0 ;;
  crumb:*)  printf 'class=%s session=s1 ts=1970-01-01T00:00:00Z\n' "${outcome#crumb:}" >> "$FACTORY_API_FAILURE_FILE"
            printf 'upstream error\n' >&2; exit 1 ;;
  *)        printf 'unscripted fake outcome: %s\n' "$outcome" >&2; exit 42 ;;
esac
FAKE
  chmod +x "$1"
}

new_case() {  # newline-separated outcome script
  [ -n "$T" ] && rm -rf "$T"
  T=$(mktemp -d) || exit 1
  mkdir -p "$T/bin" "$T/fake" "$T/work" "$T/gw" "$T/gwbad"
  write_fake_claude "$T/bin/claude"
  printf '%s\n' "$1" > "$T/script"
  for g in gw gwbad; do
    printf '#!/bin/sh\nexit 0\n' > "$T/$g/probe.sh"
    printf '#!/bin/sh\n: > "$FAKE_DIR/gateway-down"\nexit 0\n' > "$T/$g/down.sh"
    printf 'ANTHROPIC_BASE_URL=http://127.0.0.1:4000\nANTHROPIC_API_KEY=sk-fake-not-a-secret\n' > "$T/$g/env.sh"
    chmod +x "$T/$g/probe.sh" "$T/$g/down.sh"
  done
  printf '#!/bin/sh\n: > "$FAKE_DIR/gateway-up"\nexit 0\n' > "$T/gw/up.sh"
  printf '#!/bin/sh\nexit 1\n' > "$T/gwbad/up.sh"
  chmod +x "$T/gw/up.sh" "$T/gwbad/up.sh"
}

# env -i so an ambient ANTHROPIC_* or AWS_PROFILE cannot change a case's outcome.
run_sup() {  # VAR=VAL ...
  env -i PATH="$T/bin:$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    FAKE_DIR="$T/fake" FAKE_SCRIPT="$T/script" \
    FACTORY_WORKDIR="$T/work" GATEWAY_DIR="$T/gw" \
    "$@" ./bin/run-factory.sh > "$T/out" 2>&1
  SRC=$?
}

calls()    { n=$(cat "$T/fake/calls" 2>/dev/null); printf '%s' "${n:-0}"; }
drows()    { n=$(grep -c '^|[[:space:]]*[0-9]' "$T/work/DECISIONS.md" 2>/dev/null); printf '%s' "${n:-0}"; }
blockers() { n=$(grep -c '^## BLOCKER' "$T/work/HANDOFF.md" 2>/dev/null); printf '%s' "${n:-0}"; }
yn()       { if [ -n "${2:-}" ] && grep -Fq -- "$2" "$1" 2>/dev/null; then printf yes; else printf no; fi }
ynx()      { if grep -Fqx -- "$2" "$1" 2>/dev/null; then printf yes; else printf no; fi }
exists()   { if [ -e "$1" ]; then printf yes; else printf no; fi }

echo "A clean first tier finishes and touches nothing below it:"
new_case 'ok'
run_sup
ck "exit status"                      "$SRC" 0
ck "harness called once"              "$(calls)" 1
ck "no DECISIONS failover row"        "$(drows)" 0
ck "no HANDOFF.md written"            "$(exists "$T/work/HANDOFF.md")" no
ck "first attempt does not resume"    "$(ynx "$T/fake/argv.1" '--continue')" no
ck "gateway env reached the harness"  "$(yn "$T/fake/env.1" 'ANTHROPIC_BASE_URL=http://127.0.0.1:4000')" yes
ck "no local model forced"            "$(yn "$T/fake/env.1" 'ANTHROPIC_MODEL=gpt-oss')" no
ck "gateway torn down on exit"        "$(exists "$T/fake/gateway-down")" yes
# OpenCode is opt-in, not default: it wedges often enough that putting it in an unattended
# chain trades one hang for another.
ck "opencode not in the default chain" "$(yn "$T/out" 'local-opencode')" no

echo; echo "An opted-in tier whose launcher is absent is skipped, not fatal:"
new_case 'ok'
run_sup FACTORY_TIERS="cloud local-opencode"
ck "exit status"                      "$SRC" 0
ck "missing launcher skipped"         "$(yn "$T/out" 'tier local-opencode unavailable')" yes

echo; echo "A nonzero exit advances a tier and the next attempt resumes:"
new_case 'fail
ok'
run_sup
ck "exit status"                      "$SRC" 0
ck "harness called twice"             "$(calls)" 2
ck "one failover row"                 "$(drows)" 1
ck "row names the typed cause"        "$(yn "$T/work/DECISIONS.md" 'failed (exit-1)')" yes
ck "row names the successor tier"     "$(yn "$T/work/DECISIONS.md" '| `local-claude` |')" yes
ck "row names the ladder rung"        "$(yn "$T/work/DECISIONS.md" '2 — tier chain in bin/run-factory.sh')" yes
ck "second attempt resumes"           "$(ynx "$T/fake/argv.2" '--continue')" yes
ck "continue-note reached harness"    "$(yn "$T/fake/argv.2" 'Do not restart the run')" yes
ck "single-context note reached it"   "$(yn "$T/fake/argv.2" 'Do not dispatch subagents')" yes
ck "degradation note reached it"      "$(yn "$T/fake/argv.2" 'failed over to a fallback model tier')" yes
ck "local model forced"               "$(yn "$T/fake/env.2" 'ANTHROPIC_MODEL=gpt-oss:20b')" yes
ck "model tier stated in HANDOFF.md"  "$(yn "$T/work/HANDOFF.md" '**Model tier:** `local-claude`')" yes
ck "no BLOCKER on a recovered run"    "$(blockers)" 0

echo; echo "Exit 0 with an empty final message advances:"
new_case 'empty
ok'
run_sup
ck "exit status"                      "$SRC" 0
ck "harness called twice"             "$(calls)" 2
ck "one failover row"                 "$(drows)" 1
ck "cause is the empty message"       "$(yn "$T/work/DECISIONS.md" 'failed (empty-final-message)')" yes

echo; echo "An unknown, unclassifiable failure advances — the regression this layer exists for:"
new_case 'weird
ok'
run_sup
ck "exit status"                      "$SRC" 0
ck "harness called twice"             "$(calls)" 2
ck "one failover row"                 "$(drows)" 1
ck "cause records the bare exit code" "$(yn "$T/work/DECISIONS.md" 'failed (exit-99)')" yes

echo; echo "A policy refusal stops the run and never advances a tier:"
new_case 'refusal
ok'
run_sup
ck "exit status nonzero"              "$([ "$SRC" -ne 0 ] && printf nonzero || printf 0)" nonzero
ck "harness called once only"         "$(calls)" 1
ck "no failover row"                  "$(drows)" 0
ck "one BLOCKER naming the refusal"   "$(blockers)" 1
ck "BLOCKER explains laundering"      "$(yn "$T/work/HANDOFF.md" 'laundering, not')" yes
ck "stderr names the reason"          "$(yn "$T/out" 'policy/safety refusal (refusal:final-message)')" yes

echo; echo "A typed refusal breadcrumb stops the run too:"
new_case 'crumb:content_policy
ok'
run_sup
ck "exit status nonzero"              "$([ "$SRC" -ne 0 ] && printf nonzero || printf 0)" nonzero
ck "harness called once only"         "$(calls)" 1
ck "no failover row"                  "$(drows)" 0
ck "one BLOCKER"                      "$(blockers)" 1

echo; echo "The breadcrumb class outranks exit-code guessing:"
new_case 'crumb:authentication_failed
ok'
run_sup
ck "exit status"                      "$SRC" 0
ck "one failover row"                 "$(drows)" 1
ck "cause is the typed class"         "$(yn "$T/work/DECISIONS.md" 'failed (authentication_failed)')" yes
ck "cause is not the exit code"       "$(yn "$T/work/DECISIONS.md" 'exit-1')" no

echo; echo "A stale breadcrumb does not classify the next attempt:"
new_case 'crumb:rate_limit
ok'
run_sup
ck "exit status"                      "$SRC" 0
ck "run completed on tier 2"          "$(yn "$T/out" 'run complete on tier local-claude')" yes
ck "exactly one failover row"         "$(drows)" 1

echo; echo "The detector loop still evaluates the final turn:"
new_case 'ok'
run_sup MAX_RETRIES=0
ck "MAX_RETRIES=0 clean turn exits 0" "$SRC" 0
ck "harness called once"              "$(calls)" 1

new_case 'question
ok'
run_sup MAX_RETRIES=1
ck "question corrected, then clean"   "$SRC" 0
ck "harness called twice"             "$(calls)" 2
ck "correction resumed"               "$(ynx "$T/fake/argv.2" '--continue')" yes
ck "correction text reached harness"  "$(yn "$T/fake/argv.2" 'Your last message asked the user something')" yes
ck "no failover row"                  "$(drows)" 0

new_case 'question
ok'
run_sup MAX_RETRIES=0
ck "exhausted corrections advance"    "$SRC" 0
ck "cause is the interrogation loop"  "$(yn "$T/work/DECISIONS.md" 'failed (interrogation-loop)')" yes

echo; echo "Tiers exhausted writes one BLOCKER and one row per failover:"
new_case 'fail
fail'
run_sup
ck "exit status nonzero"              "$([ "$SRC" -ne 0 ] && printf nonzero || printf 0)" nonzero
ck "harness called twice"             "$(calls)" 2
ck "two failover rows"                "$(drows)" 2
ck "last row has no successor"        "$(yn "$T/work/DECISIONS.md" '| `none` |')" yes
ck "exactly one BLOCKER"              "$(blockers)" 1
ck "remediation names aws sso login"  "$(yn "$T/work/HANDOFF.md" 'aws sso login --profile')" yes
ck "blocker proves what still works"  "$(yn "$T/work/HANDOFF.md" 'Verification that the rest is unaffected')" yes

echo; echo "A gateway that will not start fails the tier over instead of hanging:"
new_case 'ok'
run_sup FACTORY_TIERS=local-claude GATEWAY_DIR="$T/gwbad"
ck "exit status nonzero"              "$([ "$SRC" -ne 0 ] && printf nonzero || printf 0)" nonzero
ck "harness never called"             "$(calls)" 0
ck "cause is the gateway"             "$(yn "$T/work/DECISIONS.md" 'failed (gateway-unavailable)')" yes
ck "one BLOCKER"                      "$(blockers)" 1

echo; echo "An absent gateway only costs the cloud tier its per-request failover:"
new_case 'ok'
run_sup FACTORY_TIERS=cloud GATEWAY_DIR="$T/nonexistent"
ck "exit status"                      "$SRC" 0
ck "harness called once"              "$(calls)" 1
ck "degradation logged"               "$(yn "$T/out" 'runs without per-request failover')" yes

echo; echo "A chain with no usable tier blocks rather than silently exiting 0:"
new_case 'ok'
run_sup FACTORY_TIERS=local-opencode
ck "exit status nonzero"              "$([ "$SRC" -ne 0 ] && printf nonzero || printf 0)" nonzero
ck "harness never called"             "$(calls)" 0
ck "tier skipped cleanly, not failed" "$(yn "$T/out" 'tier local-opencode unavailable')" yes
ck "cause recorded"                   "$(yn "$T/work/DECISIONS.md" 'failed (no-usable-tier)')" yes
ck "one BLOCKER"                      "$(blockers)" 1

echo; echo "FACTORY_TIER_FILE adds a pluggable tier without touching control flow:"
new_case 'fail'
printf '#!/bin/sh\nprintf "resume=%%s model=%%s\\n" "$FACTORY_RESUME" "$FACTORY_MODEL" > "$FAKE_DIR/oc.log"\nprintf "All 9 gates pass. Deployed.\\n" > "$FACTORY_LAST_MESSAGE_FILE"\nexit 0\n' > "$T/bin/fake-oc"
chmod +x "$T/bin/fake-oc"
printf '# name|harness|model|mode|launcher|gateway\nfake-local|opencode|tinymodel|single-context|%s|none\n' "$T/bin/fake-oc" > "$T/tiers"
run_sup FACTORY_TIERS="cloud fake-local" FACTORY_TIER_FILE="$T/tiers"
ck "exit status"                      "$SRC" 0
ck "cloud failed over to the new tier" "$(yn "$T/work/DECISIONS.md" '| `fake-local` |')" yes
ck "pluggable launcher was resumed"   "$(yn "$T/fake/oc.log" 'resume=1 model=tinymodel')" yes
ck "model tier stated in HANDOFF.md"  "$(yn "$T/work/HANDOFF.md" '**Model tier:** `fake-local`')" yes

echo; echo "The StopFailure hook records a typed class and never leaks a message:"
new_case 'ok'
HOOKOUT="$T/work/artifacts/.api-failure"
mkdir -p "$T/work/artifacts"
printf '{"session_id":"abc 123","hook_event_name":"StopFailure","matcher":"cloud_credential_error","last_assistant_message":"sk-live-SHOULD-NOT-APPEAR"}' \
  | FACTORY_API_FAILURE_FILE="$HOOKOUT" ./.claude/hooks/on-api-failure.sh
ck "typed class recorded"             "$(yn "$HOOKOUT" 'class=cloud_credential_error')" yes
ck "session id sanitised to one token" "$(yn "$HOOKOUT" 'session=abc_123')" yes
ck "message never written"            "$(yn "$HOOKOUT" 'SHOULD-NOT-APPEAR')" no
printf '{"session_id":"abc","hook_event_name":"StopFailure"}' \
  | FACTORY_API_FAILURE_FILE="$HOOKOUT" ./.claude/hooks/on-api-failure.sh
ck "missing matcher becomes unknown"  "$(yn "$HOOKOUT" 'class=unknown')" yes
printf 'not json' | FACTORY_API_FAILURE_FILE="$HOOKOUT" ./.claude/hooks/on-api-failure.sh
ck "garbage payload fails open"       "$?" 0

echo; echo "A wedged harness is killed and failed over, not waited on forever:"
new_case 'hang
ok'
run_sup FACTORY_STALL_SECS=2 FACTORY_POLL_SECS=1
ck "exit status"                      "$SRC" 0
ck "stalled tier handed over"         "$(calls)" 2
ck "stall named as the cause"         "$(yn "$T/work/DECISIONS.md" 'stalled')" yes
ck "no process left behind"           "$(pgrep -f "$T/bin/claude" >/dev/null 2>&1 && printf yes || printf no)" no

echo; echo "A slow but productive harness is left alone:"
# Local inference runs at 25-27 tok/s, so "quiet for a while" must not mean "wedged".
new_case 'slow'
run_sup FACTORY_STALL_SECS=3 FACTORY_POLL_SECS=1
ck "exit status"                      "$SRC" 0
ck "never retried"                    "$(calls)" 1
ck "no failover recorded"             "$(drows)" 0
ck "final message survived NDJSON"    "$(yn "$T/out" 'run complete')" yes

[ -n "$T" ] && rm -rf "$T"
echo; [ "$fails" -eq 0 ] && echo "all pass" || echo "$fails failing"
exit "$fails"
