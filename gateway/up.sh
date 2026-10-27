#!/usr/bin/env bash
# Starts the failover gateway, idempotently, and refuses to start it broken.
#
# Every precondition below is a failure already observed on this machine. A gateway that
# starts and then serves truncated garbage is worse than one that refuses to start, because
# an unattended run has nobody to notice the difference.
#
# Overrides are environment variables, not flags, so a supervisor can export once and
# call this from anywhere. See gateway/README.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GATEWAY_HOST="${GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${GATEWAY_PORT:-4000}"
# Chain order IS the configuration: position 1 is primary, the rest are fallbacks in order.
# A local provider leads or backstops by changing this string alone.
FACTORY_MODEL_CHAIN="${FACTORY_MODEL_CHAIN:-cloud ollama ollama2}"
# Generated, not committed: gateway/providers.conf plus the chain is the source of truth.
GATEWAY_CONFIG="${GATEWAY_CONFIG:-artifacts/litellm.generated.yaml}"
GATEWAY_MASTER_KEY="${GATEWAY_MASTER_KEY:-sk-factory-local}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
GATEWAY_LOCAL_MODEL="${GATEWAY_LOCAL_MODEL:-gpt-oss:20b}"
# Below roughly 32k, Claude Code silently truncates and starts auto-compacting — it
# summarises instead of working, and reports success. 16384 is this machine's default.
GATEWAY_MIN_CONTEXT="${GATEWAY_MIN_CONTEXT:-32768}"
# First load of a 12GB model is slow. A port-open check would pass long before this.
GATEWAY_READY_TIMEOUT="${GATEWAY_READY_TIMEOUT:-240}"
# Tier 1. Carries its own provider prefix; credentials stay in the ambient environment.
FACTORY_PRIMARY_MODEL="${FACTORY_PRIMARY_MODEL:-bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0}"

# Resolved per provider, never left empty: LiteLLM's Bedrock path reads an empty api_base
# as a real endpoint and dies with "'NoneType' object has no attribute 'split'", which the
# router then reports as an ordinary tier-1 failure. Silent permanent failover is worse
# than no failover. gateway/probe.sh --induce-failure overrides this with a dead host.
if [ -z "${FACTORY_PRIMARY_API_BASE:-}" ]; then
  case "$FACTORY_PRIMARY_MODEL" in
    bedrock/*)
      AWS_RGN="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
      [ -n "$AWS_RGN" ] || AWS_RGN=$(aws configure get region 2>/dev/null)
      [ -n "$AWS_RGN" ] || AWS_RGN="us-east-1"
      FACTORY_PRIMARY_API_BASE="https://bedrock-runtime.$AWS_RGN.amazonaws.com" ;;
    anthropic/*)
      FACTORY_PRIMARY_API_BASE="https://api.anthropic.com" ;;
    *)
      printf 'gateway: FAIL FACTORY_PRIMARY_MODEL=%s needs FACTORY_PRIMARY_API_BASE set explicitly.\n' \
        "$FACTORY_PRIMARY_MODEL" >&2
      exit 1 ;;
  esac
fi

ART="artifacts"
# Port-scoped. One shared artifacts/gateway.pid lets a run on a second port overwrite the
# first one's pidfile, and down.sh then orphans a live proxy.
PIDFILE="$ART/gateway-$GATEWAY_PORT.pid"
LOGFILE="$ART/gateway-$GATEWAY_PORT.log"
CTXFILE="$ART/gateway-context"
BASE="http://$GATEWAY_HOST:$GATEWAY_PORT"

mkdir -p "$ART" || exit 1

say()  { printf '%s\n' "$*"; }
die()  { printf 'gateway: FAIL %s\n' "$*" >&2; exit 1; }

# --- Render the chain ------------------------------------------------------------------
# Render before anything else reads a provider name: the sidecar it writes is where the
# rest of this script learns the chain, so nothing here hardcodes a provider.
command -v node >/dev/null 2>&1 || die "node not on PATH; bin/render-gateway-config.mjs needs it."
node bin/render-gateway-config.mjs --chain "$FACTORY_MODEL_CHAIN" \
  --out "$GATEWAY_CONFIG" || die "could not render $GATEWAY_CONFIG from gateway/providers.conf"

CHAIN_ENV="${GATEWAY_CONFIG%.yaml}.env"
CHAIN_ENV="${CHAIN_ENV%.yml}.env"
[ -f "$CHAIN_ENV" ] || die "renderer wrote no sidecar at $CHAIN_ENV"
# shellcheck source=/dev/null
. "$CHAIN_ENV"

# Reads one column out of the sidecar's PROVIDER_<NAME> row. Indirect expansion keeps this
# bash 3.2 safe, where associative arrays do not exist.
provider_field() {  # name, field(1=model 2=api_base 3=local 4=tools)
  pf_key=$(printf 'PROVIDER_%s' "$1" | tr 'a-z-' 'A-Z_')
  eval "pf_row=\${$pf_key:-}"
  printf '%s' "$pf_row" | awk -F'|' -v f="$2" '{ printf "%s", $f }'
}

# Two local providers in one chain do not share memory: loading the second evicts or OOMs
# the first. Measured the hard way — an MLX load killed a running Ollama on a 32 GB machine.
if [ "${CHAIN_LOCAL_HOSTS:-0}" -gt 1 ] && [ "${FACTORY_ALLOW_MULTI_LOCAL:-0}" != 1 ]; then
  die "chain has $CHAIN_LOCAL_HOSTS local inference servers ($CHAIN_LOCALS) competing for the
  same memory. The second to load evicts or OOM-kills the first, which reads as flaky
  inference rather than as a configuration error.

  Pick one local provider, or accept the eviction with FACTORY_ALLOW_MULTI_LOCAL=1."
fi

# Prints the env block a harness needs. The context value is read back out of
# gateway/env.sh rather than recomputed, so the two can never disagree about the headroom
# Claude Code must leave below the Ollama window.
print_env_block() {
  maxctx=$( . gateway/env.sh >/dev/null 2>&1; printf '%s' "${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-}" )
  [ -n "$maxctx" ] || maxctx="$GATEWAY_MIN_CONTEXT"
  cat <<EOF

Harness environment (or: . gateway/env.sh):

  export ANTHROPIC_BASE_URL=$BASE
  export ANTHROPIC_API_KEY=$GATEWAY_MASTER_KEY
  export ANTHROPIC_MODEL=$CHAIN_PRIMARY
  export ANTHROPIC_DEFAULT_HAIKU_MODEL=$CHAIN_WILDCARD
  export API_FORCE_IDLE_TIMEOUT=0
  export CLAUDE_CODE_MAX_CONTEXT_TOKENS=$maxctx
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX ANTHROPIC_AUTH_TOKEN \\
        ANTHROPIC_SMALL_FAST_MODEL AWS_PROFILE AWS_REGION
EOF
}

# Confirms the listener is this config and not someone else's proxy. Two proxies fighting
# for one port is a failure that looks like flaky inference.
is_our_gateway() {
  models=$(curl -s --max-time 10 -H "Authorization: Bearer $GATEWAY_MASTER_KEY" \
    "$BASE/v1/models" 2>/dev/null) || return 1
  case "$models" in
    *"\"$CHAIN_PRIMARY\""*) case "$models" in *"\"$CHAIN_WILDCARD\""*) return 0 ;; esac ;;
  esac
  return 1
}

# A TCP connect, not an HTTP request: a listener that never answers HTTP still owns the
# port, and litellm would then die on bind with thirty lines of banner instead of a reason.
port_busy() {
  (exec 3<>"/dev/tcp/$GATEWAY_HOST/$GATEWAY_PORT") 2>/dev/null
}

# --- Idempotency -----------------------------------------------------------------------
if port_busy; then
  if is_our_gateway; then
    say "gateway: already up on $BASE (reusing; pid $(cat "$PIDFILE" 2>/dev/null || echo unknown))"
    print_env_block
    exit 0
  fi
  die "port $GATEWAY_PORT is held by something that is not this gateway.
  Inspect it:  lsof -nP -iTCP:$GATEWAY_PORT -sTCP:LISTEN
  Then either stop it or re-run with GATEWAY_PORT set to a free port."
fi

# A pidfile without a listener is a crashed run, not a running one.
if [ -f "$PIDFILE" ]; then
  STALE=$(cat "$PIDFILE" 2>/dev/null)
  case "$STALE" in
    ''|*[!0-9]*) : ;;
    *) kill -0 "$STALE" 2>/dev/null && kill "$STALE" 2>/dev/null ;;
  esac
  rm -f "$PIDFILE"
fi

# --- Preconditions ---------------------------------------------------------------------
command -v uvx >/dev/null 2>&1 || die "uvx not on PATH.
  LiteLLM runs ephemerally through it; nothing is installed globally.
  Install:  curl -LsSf https://astral.sh/uv/install.sh | sh
  Or add it:  export PATH=\"\$HOME/.local/bin:\$PATH\""

[ -f "$GATEWAY_CONFIG" ] || die "config missing: $GATEWAY_CONFIG"

# Which local runtimes this chain actually needs. Probing one nothing uses would fail the
# run for an irrelevant reason.
NEED_OLLAMA=0
NEED_OPENAI_LOCAL=
for p in ${CHAIN_LOCALS:-}; do
  case "$(provider_field "$p" 2)" in
    *:11434*) NEED_OLLAMA=1
              # Strip the LiteLLM prefix: `anthropic/gpt-oss:20b` -> `gpt-oss:20b`.
              GATEWAY_LOCAL_MODEL="$(provider_field "$p" 1 | sed -E 's#^[a-z0-9_]+/##')" ;;
    *)        NEED_OPENAI_LOCAL="$NEED_OPENAI_LOCAL $p" ;;
  esac
done

# OpenAI-compatible local servers — MLX and friends. They are not started for you: a model
# load is minutes and gigabytes, and guessing one is worse than refusing.
for p in $NEED_OPENAI_LOCAL; do
  p_base=$(provider_field "$p" 2)
  p_model=$(provider_field "$p" 1 | sed -E 's#^openai/##')
  p_models=$(curl -s --max-time 15 "$p_base/models" 2>/dev/null) || p_models=""
  case "$p_models" in
    *'"data"'*) say "gateway: $p reachable at $p_base" ;;
    *) die "provider $p is not answering at $p_base.
  It is an OpenAI-compatible server this chain lists; nothing here starts it for you.
  For MLX:  uvx --from mlx-lm mlx_lm.server --model $p_model --host 127.0.0.1 --port 8099
  Then re-run. Or drop $p from FACTORY_MODEL_CHAIN." ;;
  esac
  case "$p_models" in
    *"$p_model"*) : ;;
    *) say "gateway: WARN $p does not list $p_model; the server may hold a different model." ;;
  esac
done

if [ "$NEED_OLLAMA" = 1 ]; then
TAGS=$(curl -s --max-time 10 "$OLLAMA_URL/api/tags" 2>/dev/null) || TAGS=""
case "$TAGS" in
  *'"models"'*) say "gateway: ollama reachable at $OLLAMA_URL" ;;
  *) die "ollama is not answering at $OLLAMA_URL.
  Start it:  ollama serve        (headless, honours OLLAMA_CONTEXT_LENGTH)
  Or:        open -a Ollama      (macOS desktop app)
  Then re-run this script." ;;
esac

case "$TAGS" in
  *"\"name\":\"$GATEWAY_LOCAL_MODEL\""*) say "gateway: local model present: $GATEWAY_LOCAL_MODEL" ;;
  *) die "local model $GATEWAY_LOCAL_MODEL is not pulled.
  Pull it:  ollama pull $GATEWAY_LOCAL_MODEL
  This is a multi-gigabyte download and is deliberately not automatic." ;;
esac

# Warm load. Doubles as the context measurement below: /api/ps reports the context a
# loaded model actually got, which is the only value that cannot lie.
say "gateway: warming $GATEWAY_LOCAL_MODEL (cold load of a multi-GB model is slow)"
curl -s -o /dev/null --max-time 600 "$OLLAMA_URL/api/generate" \
  -d "{\"model\":\"$GATEWAY_LOCAL_MODEL\",\"prompt\":\"ok\",\"stream\":false,\"options\":{\"num_predict\":1}}" \
  2>/dev/null

MODEL_RE=$(printf '%s' "$GATEWAY_LOCAL_MODEL" | sed -E 's/[.[*^$\/]/\\&/g')
CTX=$(curl -s --max-time 15 "$OLLAMA_URL/api/ps" 2>/dev/null \
  | sed -E "s/.*\"model\":\"$MODEL_RE\"//" \
  | grep -o -E '"context_length":[0-9]+' | head -1 | sed -E 's/[^0-9]//g')

# Fallback for an Ollama too old to report it: ask the server process what it was told.
if [ -z "$CTX" ]; then
  CTX=$(launchctl getenv OLLAMA_CONTEXT_LENGTH 2>/dev/null)
  case "$CTX" in ''|*[!0-9]*) CTX="" ;; esac
fi

if [ -z "$CTX" ]; then
  say "gateway: WARN cannot read the effective context length."
  say "         Confirm it by hand:  curl -s $OLLAMA_URL/api/ps"
  say "         Below $GATEWAY_MIN_CONTEXT tokens the local tier produces plausible garbage."
elif [ "$CTX" -lt "$GATEWAY_MIN_CONTEXT" ]; then
  die "ollama context is $CTX, below the $GATEWAY_MIN_CONTEXT floor.
  Claude Code truncates silently at this size and auto-compacts: the model starts
  summarising instead of working, and the run reports success having built nothing.
  num_ctx cannot fix this — it is ignored on the Anthropic passthrough path.

  Headless ollama:
      pkill -f 'ollama serve'; OLLAMA_CONTEXT_LENGTH=$GATEWAY_MIN_CONTEXT ollama serve &
  macOS desktop app (it passes its own value and OVERRIDES launchctl setenv):
      Ollama menu bar icon -> Settings -> Context length -> $GATEWAY_MIN_CONTEXT, then reopen the app.
  Max for $GATEWAY_LOCAL_MODEL is 131072. Then re-run this script."
else
  printf '%s\n' "$CTX" > "$CTXFILE"
  say "gateway: ollama context $CTX (floor $GATEWAY_MIN_CONTEXT)"
fi
fi  # NEED_OLLAMA

# Not fatal. A primary that fails over on its first call is the designed behaviour, not an
# error — but silently losing tier 1 to a sourced env.sh is worth one line.
case "$FACTORY_PRIMARY_MODEL" in
  bedrock/*)
    if [ -z "${AWS_PROFILE:-}${AWS_REGION:-}${AWS_ACCESS_KEY_ID:-}${AWS_BEARER_TOKEN_BEDROCK:-}" ]; then
      say "gateway: WARN no AWS variables visible; tier 1 ($FACTORY_PRIMARY_MODEL) will fail over on first call."
    fi ;;
  anthropic/*)
    [ -z "${ANTHROPIC_API_KEY:-}" ] &&
      say "gateway: WARN ANTHROPIC_API_KEY absent; tier 1 ($FACTORY_PRIMARY_MODEL) will fail over on first call." ;;
esac

# --- Start -----------------------------------------------------------------------------
: > "$LOGFILE"
GATEWAY_MASTER_KEY="$GATEWAY_MASTER_KEY" \
FACTORY_PRIMARY_API_KEY="${FACTORY_PRIMARY_API_KEY:-${ANTHROPIC_API_KEY:-unused}}" \
  uvx --from 'litellm[proxy]' litellm \
    --config "$GATEWAY_CONFIG" --host "$GATEWAY_HOST" --port "$GATEWAY_PORT" \
    >> "$LOGFILE" 2>&1 &
PID=$!
printf '%s\n' "$PID" > "$PIDFILE"
say "gateway: starting litellm pid $PID -> $LOGFILE"
say "gateway: tier 1 = $CHAIN_PRIMARY ($(provider_field "$CHAIN_PRIMARY" 1))"

# --- Health gate -----------------------------------------------------------------------
# A trivial real completion, not a port check. LiteLLM binds the port well before the
# router can serve anything, and the local model may still be loading behind it.
DEADLINE=$(( $(date +%s) + GATEWAY_READY_TIMEOUT ))
READY=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    rm -f "$PIDFILE"
    say "--- last 30 lines of $LOGFILE ---" >&2
    tail -30 "$LOGFILE" >&2
    die "litellm exited during startup. Log above."
  fi
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 \
    -H "Authorization: Bearer $GATEWAY_MASTER_KEY" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    "$BASE/v1/messages" \
    -d "{\"model\":\"$CHAIN_WILDCARD\",\"max_tokens\":4,\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}" \
    2>/dev/null)
  [ "$CODE" = "200" ] && { READY=1; break; }
  sleep 3
done

if [ "$READY" != 1 ]; then
  kill "$PID" 2>/dev/null
  rm -f "$PIDFILE"
  say "--- last 30 lines of $LOGFILE ---" >&2
  tail -30 "$LOGFILE" >&2
  die "gateway did not serve /v1/messages within ${GATEWAY_READY_TIMEOUT}s. Log above."
fi

say "gateway: ready on $BASE (chain: $(printf '%s' "$CHAIN_NAMES" | sed 's/ / -> /g'))"
say "gateway: verify the chain with ./gateway/probe.sh"
print_env_block
