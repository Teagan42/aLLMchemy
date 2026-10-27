#!/usr/bin/env bash
# Claude Code adapter. Blocks a Stop or SubagentStop whose final message interrogates the
# user; there is no human in this run, so a question is a deadlock rather than a request.
#
# Transport only: extracting the last assistant message and emitting the hook's JSON. The
# matching rule lives in bin/detect-question.sh so the Codex wrapper enforces the same one.
#
# Fails open: any missing dependency or parse failure allows the stop. A hook that blocked
# on its own bug would be worse than the behaviour it guards.

set -uo pipefail

# The no-questions rule is a property of a FACTORY RUN, not of this repository. Developing
# the package is a conversation: grilling a human for a decision is the point, and blocking
# it stalls the work. The launchers export FACTORY_RUN; nothing else does, so an unset value
# means a human is present and the guard must stand down.
#
# Fail open, like every other check here: a guard that cannot tell which context it is in
# must not block.
[ -n "${FACTORY_RUN:-}" ] || exit 0

MAX_BLOCKS=3
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
DETECT="$ROOT/bin/detect-question.sh"
payload=$(cat)

command -v jq >/dev/null 2>&1 || exit 0
[ -x "$DETECT" ] || exit 0

session=$(printf '%s' "$payload" | jq -r '.session_id // "nosession"')
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // "Stop"')
# agent_id is absent on a main-session Stop; agent_type is the only id a plugin subagent has.
agent=$(printf '%s' "$payload" | jq -r '.agent_id // .agent_type // "main"')

# Runaway guard: never block more than MAX_BLOCKS times in a row per key, so a pattern bug
# cannot deadlock the run this is meant to protect. The budget is consecutive, not lifetime:
# a clean stop clears the counter even once it is exhausted, or one pattern false positive
# disarms the guard for the rest of a long run.
#
# One script serves Stop and SubagentStop and
# session_id is identical for both, so the key carries the event and agent as well —
# otherwise seven role subagents spend the orchestrator's budget, and one clean subagent
# stop refills it.
key="${session//[^A-Za-z0-9_-]/_}-${event//[^A-Za-z0-9_-]/_}-${agent//[^A-Za-z0-9_-]/_}"
counter="${TMPDIR:-/tmp}/no-questions-${key}.count"
blocks=$(cat "$counter" 2>/dev/null || echo 0)
# Corrupt or empty counter content must not abort the hook under `set -u`.
case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac

# Stop and SubagentStop carry the turn's final text directly. Prefer it: transcript_path is
# written asynchronously and can still hold the previous turn when this fires.
last=$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""')

if [ -z "${last//[[:space:]]/}" ]; then
  transcript=$(printf '%s' "$payload" | jq -r '.agent_transcript_path // .transcript_path // empty')
  [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
  last=$(jq -rs '
    [ .[]
      | select(type == "object")
      | select(.type == "assistant")
      | .message.content
      | if type == "array" then
          [ .[] | select(.type == "text") | .text ] | join("\n")
        else (. // "") | tostring end
    ] | last // ""
  ' "$transcript" 2>/dev/null)
fi

if printf '%s' "$last" | "$DETECT"; then
  [ "$blocks" -ge "$MAX_BLOCKS" ] && exit 0
  # The write is authoritative. An unwritable counter means the runaway guard cannot count,
  # and a guard that cannot count must not block: that is a non-terminating rewrite loop.
  echo $((blocks + 1)) > "$counter" 2>/dev/null || exit 0
  jq -n --arg guide "$ROOT/playbook/autonomy-contract.md" '{
    decision: "block",
    reason: ("Your final message asks the user something. No human will answer; the run would hang.\n\n" +
             "Resolve it yourself with the decision ladder in " + $guide + ":\n" +
             "  1. intake.yaml answer\n" +
             "  2. documented default in the owning playbook document\n" +
             "  3. cheapest reversible option\n" +
             "  4. record the assumption in DECISIONS.md and proceed\n\n" +
             "If this is a genuine external blocker (invalid credential, provider needs manual\n" +
             "account verification), it is still not a question: append a BLOCKER entry to\n" +
             "HANDOFF.md with exact remediation steps, finish every unblocked part of the scope,\n" +
             "then report as statements only. Rewrite your closing message with no questions in it.")
  }'
  exit 0
fi

rm -f "$counter" 2>/dev/null
exit 0
