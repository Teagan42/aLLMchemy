#!/usr/bin/env bash
# Proves the chain on demand. The response's `model` field names the backend that actually
# answered, which is the only evidence that failover happened — the request shape is
# identical either way, by design.
#
#   ./gateway/probe.sh                   trivial request through the chain's primary
#   ./gateway/probe.sh --tool-call       the local tier can still drive an agent loop
#   ./gateway/probe.sh --induce-failure  tier 1 unreachable; a local tier must still answer
#
# --induce-failure starts a second, short-lived gateway on GATEWAY_PORT+1 from the same
# config with tier 1 pointed at a dead host. It does not disturb a running gateway, and
# changing one variable rather than one file is what makes the result mean something.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GATEWAY_HOST="${GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${GATEWAY_PORT:-4000}"
GATEWAY_CONFIG="${GATEWAY_CONFIG:-artifacts/litellm.generated.yaml}"
GATEWAY_MASTER_KEY="${GATEWAY_MASTER_KEY:-sk-factory-local}"
# Default to the rendered chain's primary: probing a literal would test the wrong tier
# whenever the chain is reordered.
_pr_env="$(dirname "$0")/../artifacts/litellm.generated.env"
[ -f "$_pr_env" ] && . "$_pr_env"
PROBE_MODEL="${PROBE_MODEL:-${CHAIN_PRIMARY:-cloud}}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-300}"

MODE=trivial
case "${1:-}" in
  '')                : ;;
  --induce-failure)  MODE=induce ;;
  --tool-call)       MODE=tools ;;
  *) printf 'usage: %s [--induce-failure|--tool-call]\n' "$0" >&2; exit 2 ;;
esac

PORT="$GATEWAY_PORT"
CHILD=""
cleanup() { [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; }
trap cleanup EXIT INT TERM

post() {
  curl -s --max-time "$PROBE_TIMEOUT" \
    -H "Authorization: Bearer $GATEWAY_MASTER_KEY" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    "http://$GATEWAY_HOST:$PORT/v1/messages" -d "$1" 2>/dev/null
}

field() { printf '%s' "$2" | grep -o -E "\"$1\":\"[^\"]*\"" | head -1 | sed -E 's/.*:"//; s/"$//'; }

# --- Induced failure: identical config, tier 1 pointed at a closed port ------------------
if [ "$MODE" = induce ]; then
  PORT=$((GATEWAY_PORT + 1))
  LOG="artifacts/gateway-induced.log"
  mkdir -p artifacts
  : > "$LOG"
  printf 'probe: tier 1 forced to http://127.0.0.1:1 (closed); gateway on port %s\n' "$PORT"
  GATEWAY_MASTER_KEY="$GATEWAY_MASTER_KEY" \
  FACTORY_PRIMARY_MODEL="anthropic/claude-sonnet-4-5-20250929" \
  FACTORY_PRIMARY_API_BASE="http://127.0.0.1:1" \
  ANTHROPIC_API_KEY="sk-ant-unreachable-on-purpose" \
    uvx --from 'litellm[proxy]' litellm \
      --config "$GATEWAY_CONFIG" --host "$GATEWAY_HOST" --port "$PORT" >> "$LOG" 2>&1 &
  CHILD=$!
  DEADLINE=$(( $(date +%s) + 240 ))
  UP=0
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    kill -0 "$CHILD" 2>/dev/null || break
    curl -s -o /dev/null --max-time 5 "http://$GATEWAY_HOST:$PORT/health/liveliness" 2>/dev/null \
      && { UP=1; break; }
    sleep 2
  done
  if [ "$UP" != 1 ]; then
    tail -20 "$LOG" >&2
    printf 'probe: FAIL induced gateway never came up. Log above.\n' >&2
    exit 1
  fi
fi

# --- Request ----------------------------------------------------------------------------
# Token budgets are generous because gpt-oss:20b spends most of a small budget on a
# thinking block and then stops at max_tokens with no text at all.
if [ "$MODE" = tools ]; then
  REQ='{"model":"'"$PROBE_MODEL"'","max_tokens":1024,
        "tools":[{"name":"get_port","description":"Return the TCP port a service listens on.",
                  "input_schema":{"type":"object","properties":{"service":{"type":"string"}},
                  "required":["service"]}}],
        "tool_choice":{"type":"tool","name":"get_port"},
        "messages":[{"role":"user","content":"Which port does the gateway listen on? Use get_port."}]}'
else
  REQ='{"model":"'"$PROBE_MODEL"'","max_tokens":512,
        "messages":[{"role":"user","content":"Reply with the single word: alive"}]}'
fi

RESP=$(post "$REQ")

if [ -z "$RESP" ]; then
  printf 'probe: FAIL no response from http://%s:%s/v1/messages\n' "$GATEWAY_HOST" "$PORT" >&2
  printf '  Is the gateway up?  ./gateway/up.sh\n' >&2
  exit 1
fi

case "$RESP" in
  *'"error"'*)
    printf 'probe: FAIL requested=%s\n%s\n' "$PROBE_MODEL" "$RESP" >&2
    exit 1 ;;
esac

BACKEND=$(field model "$RESP")
[ -n "$BACKEND" ] || BACKEND="(unreported)"

# LiteLLM echoes the requested group name on a direct hit but the real deployment name
# after a fallback, so both spellings have to count as local.
case "$BACKEND" in
  local-*|gpt-oss*|qwen3*|deepseek*) TIER="LOCAL" ;;
  *) TIER="CLOUD" ;;
esac

printf 'probe: requested=%s  served-by=%s  tier=%s\n' "$PROBE_MODEL" "$BACKEND" "$TIER"
printf 'probe: stop_reason=%s\n' "$(field stop_reason "$RESP")"

if [ "$MODE" = tools ]; then
  case "$RESP" in
    *'"type":"tool_use"'*)
      printf 'probe: tool_use present: %s\n' \
        "$(printf '%s' "$RESP" | grep -o -E '\{"type":"tool_use".{0,200}' | head -1)" ;;
    *) printf 'probe: FAIL no tool_use block in the response\n%s\n' "$RESP" >&2; exit 1 ;;
  esac
else
  printf 'probe: text=%s\n' \
    "$(printf '%s' "$RESP" | grep -o -E '"text":"[^"]*"' | head -1 | sed -E 's/^"text":"//; s/"$//')"
fi

if [ "$MODE" = induce ]; then
  if [ "$TIER" != LOCAL ]; then
    printf 'probe: FAIL tier 1 was unreachable yet a non-local backend answered.\n' >&2
    exit 1
  fi
  printf 'probe: PASS tier 1 unreachable, request still served locally by %s\n' "$BACKEND"
fi
