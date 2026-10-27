#!/usr/bin/env bash
# Regression suite for the shared question detector. Run after editing question-patterns.txt.
#
# Both directions matter. A missed question deadlocks the run; a false positive on a status
# report burns budget on rewrites and can block a correct final message. The false-positive
# cases are all real: quoted example questions and the DECISIONS.md "question that went
# unasked" column both appear in legitimate reports.
#
# Also exercises the Claude Code hook adapter, since it owns the runaway guard.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
DETECT=./bin/detect-question.sh
HOOK=./.claude/hooks/no-questions.sh
fails=0

check() {  # label, text, expect(QUESTION|CLEAN)
  if printf '%s' "$2" | "$DETECT"; then got=QUESTION; else got=CLEAN; fi
  if [ "$got" = "$3" ]; then printf '  PASS  %-42s %s\n' "$1" "$got"
  else printf '  FAIL  %-42s got %s want %s\n' "$1" "$got" "$3"; fails=$((fails + 1)); fi
}

echo "Detector — must flag as QUESTION:"
check "bare question"           'Which billing provider would you prefer?' QUESTION
check "should we"               'Should we enable SMS on the base plan, or keep it as an add-on?' QUESTION
check "please confirm"          'Deployed. Please confirm the pricing before I go live.' QUESTION
check "awaiting input"          'Build is green. Awaiting your input on the domain.' QUESTION
check "let me know"             'Shipped 8 of 9 gates. Let me know how you want to handle the last one.' QUESTION
check "before I proceed"        'Schema ready. Before I proceed I need to know the retention window.' QUESTION
check "deferring the choice"    'Option A is cheaper, option B is faster. Either way it is your call.' QUESTION
check "needs your decision"     'The catalog is synced. I need your decision on the annual discount.' QUESTION
check "need you to confirm"     'Billing is wired. I need you to confirm the price before launch.' QUESTION
check "contractions, ? midline" "I can't confirm: which host do you want? That's the open item." QUESTION
check "contractions, two spans" "It isn't done. Should we ship? Here's the state." QUESTION

echo; echo "Detector — must pass as CLEAN:"
check "quoted example question" 'Verified: blocks "Which billing provider would you prefer?", allows a report.' CLEAN
check "backticked question"     'The hook rejects `Should I use Stripe or Paddle?` in a closing message.' CLEAN
check "DECISIONS table row"     'Decisions recorded:
| # | Question that went unasked | Choice |
| 1 | Which host, given auto? | Fly.io |
All 9 gates pass.' CLEAN
check "plain status report"     'Deployed to https://x.fly.dev. All 9 gates pass. Two blockers in HANDOFF.md.' CLEAN
check "rhetorical in prose"     'The gate asks whether the cron fired, and healthz confirms it did.' CLEAN
check "fenced code with ?"      'Done.
```sh
# Should I deploy? no: verify.sh decides
test -f verify.sh
```
All gates green.' CLEAN
check "blocker report"          'BLOCKER 1: SMS disabled, TWILIO_ACCOUNT_SID absent. Remediation in HANDOFF.md.' CLEAN
check "handoff says what human does" 'HANDOFF.md lists what we need you to do: rotate the Stripe key and verify the domain.' CLEAN
check "single-quoted question"  "The hook rejects 'Should I use Stripe or Paddle?' in a closing message." CLEAN

# Counter paths mirror the hook's key: session-event-agent, agent defaulting to "main".
C_STOP="${TMPDIR:-/tmp}/no-questions-guard-Stop-main.count"
C_SUB="${TMPDIR:-/tmp}/no-questions-guard-SubagentStop-sub1.count"
C_TS="${TMPDIR:-/tmp}/no-questions-tscript-Stop-main.count"
rm -f "$C_STOP" "$C_SUB" "$C_TS"

# FACTORY_RUN is what arms the guard: the hook stands down without it, because an unset
# value means a human is present. Every case below asserts factory-run behaviour, so it
# declares that context. The gate itself is covered separately at the end.
hook() {  # payload -> BLOCK|ALLOW
  if [ -n "$(printf '%s' "$1" | FACTORY_RUN=1 "$HOOK")" ]; then printf BLOCK; else printf ALLOW; fi
}

hcheck() {  # label, payload, expect(BLOCK|ALLOW)
  r=$(hook "$2")
  if [ "$r" = "$3" ]; then printf '  PASS  %-42s %s\n' "$1" "$r"
  else printf '  FAIL  %-42s got %s want %s\n' "$1" "$r" "$3"; fails=$((fails + 1)); fi
}

Q='{"session_id":"guard","hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"Which option would you prefer?"}'
QSUB='{"session_id":"guard","hook_event_name":"SubagentStop","agent_id":"sub1","stop_hook_active":true,"last_assistant_message":"Which option would you prefer?"}'
CSUB='{"session_id":"guard","hook_event_name":"SubagentStop","agent_id":"sub1","stop_hook_active":true,"last_assistant_message":"All 9 gates pass."}'

echo; echo "Claude hook adapter — runaway guard releases on the 4th block:"
for n in 1 2 3 4; do
  want=BLOCK; [ "$n" = 4 ] && want=ALLOW
  hcheck "Stop attempt $n" "$Q" "$want"
done

echo; echo "Claude hook adapter — Stop and SubagentStop do not share a budget:"
# The Stop budget is exhausted above; a subagent must still get its own three blocks.
hcheck "SubagentStop after Stop exhausted" "$QSUB" BLOCK
hcheck "clean SubagentStop allowed" "$CSUB" ALLOW
# That clean stop cleared only the subagent key, so the parent stays exhausted.
hcheck "Stop still exhausted after clean sub" "$Q" ALLOW
hcheck "SubagentStop budget reset by clean stop" "$QSUB" BLOCK

echo; echo "Claude hook adapter — the budget is consecutive, not lifetime:"
# The Stop budget is exhausted above. A clean stop must re-arm it, or one pattern false
# positive disarms the guard for every remaining phase of the run.
hcheck "clean Stop clears an exhausted budget" \
  '{"session_id":"guard","hook_event_name":"Stop","last_assistant_message":"All 9 gates pass."}' ALLOW
hcheck "Stop re-armed after the clean stop" "$Q" BLOCK

echo; echo "Claude hook adapter — fails open rather than looping:"
C_RO="${TMPDIR:-/tmp}/no-questions-ro-Stop-main.count"
RO='{"session_id":"ro","hook_event_name":"Stop","last_assistant_message":"Which option would you prefer?"}'
# An unwritable counter means the guard cannot count, so it must not block at all.
r=$(printf '%s' "$RO" | TMPDIR=/nonexistent-dir/ "$HOOK" 2>/dev/null)
hcheck_raw() {
  if [ "$2" = "$3" ]; then printf '  PASS  %-42s %s\n' "$1" "$2"
  else printf '  FAIL  %-42s got %s want %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
hcheck_raw "unwritable counter allows the stop" "$([ -n "$r" ] && printf BLOCK || printf ALLOW)" ALLOW

# A corrupt counter must be normalised, not crash the shell under `set -u`.
printf 'abc\n' > "$C_RO"
hcheck "corrupt counter recovers to a block" "$RO" BLOCK
rm -f "$C_RO"

echo; echo "Claude hook adapter — falls back to the transcript when no last message:"
D=$(mktemp -d)
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Which option would you prefer?"}]}}\n' > "$D/g.jsonl"
hcheck "transcript fallback blocks" \
  "$(printf '{"session_id":"tscript","hook_event_name":"Stop","transcript_path":"%s","stop_hook_active":true}' "$D/g.jsonl")" BLOCK
rm -rf "$D"
rm -f "$C_STOP" "$C_SUB" "$C_TS"

# The guard is a property of a factory run, not of this repository. Developing the package
# is a conversation, and a blocked question stalls it. Without this the hook fires during
# its own development, which is how the rule got applied to the wrong context once already.
echo; echo "Claude hook adapter — stands down outside a factory run:"
C_SD="${TMPDIR:-/tmp}/no-questions-standdown-Stop-main.count"
rm -f "$C_SD"
SD='{"session_id":"standdown","hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"Which option would you prefer?"}'
r=$(if [ -n "$(printf '%s' "$SD" | env -u FACTORY_RUN "$HOOK")" ]; then printf BLOCK; else printf ALLOW; fi)
if [ "$r" = ALLOW ]; then
  printf '  PASS  %-40s %s\n' "no FACTORY_RUN allows a question" "$r"
else
  printf '  FAIL  %-40s got %s want ALLOW\n' "no FACTORY_RUN allows a question" "$r"; fails=$((fails + 1))
fi
# And the same payload must still block once armed, so the test proves the gate rather
# than a broken detector.
hcheck "same payload blocks once armed" "$SD" BLOCK
rm -f "$C_SD"

echo; [ "$fails" -eq 0 ] && echo "all pass" || echo "$fails failing"
exit "$fails"
