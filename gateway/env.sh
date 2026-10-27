# Sourceable. Points Claude Code at the gateway instead of at a provider.
#
#     . gateway/env.sh
#
# Source this in the HARNESS shell, not before gateway/up.sh. It unsets AWS_PROFILE and
# AWS_REGION so Claude Code cannot bypass the gateway, and the gateway's own tier 1 needs
# those same variables. Start the gateway first, then source this.

# shellcheck shell=bash

GATEWAY_HOST="${GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${GATEWAY_PORT:-4000}"
GATEWAY_MASTER_KEY="${GATEWAY_MASTER_KEY:-sk-factory-local}"

_gw_root="$(cd "$(dirname "${BASH_SOURCE[0]:-gateway/env.sh}")/.." && pwd)"

# Measured by gateway/up.sh from /api/ps. The floor it enforces is the fallback.
_gw_ollama_ctx="$(cat "$_gw_root/artifacts/gateway-context" 2>/dev/null)"
case "$_gw_ollama_ctx" in ''|*[!0-9]*) _gw_ollama_ctx=32768 ;; esac

# Must stay strictly below the Ollama context: Claude Code counts only its own window, so
# if the two are equal the response tokens push the request past the server limit and
# Ollama truncates the prompt silently. 8k is the reserved output budget.
_gw_reserve=8192
CLAUDE_CODE_MAX_CONTEXT_TOKENS=$(( _gw_ollama_ctx - _gw_reserve ))
[ "$CLAUDE_CODE_MAX_CONTEXT_TOKENS" -lt 16384 ] && CLAUDE_CODE_MAX_CONTEXT_TOKENS=16384

# Provider names come from the rendered chain, never from a literal here: the chain is
# reorderable, so a hardcoded primary silently points the harness at the wrong tier.
_gw_chain_env="$_gw_root/artifacts/litellm.generated.env"
if [ -f "$_gw_chain_env" ]; then
  # shellcheck source=/dev/null
  . "$_gw_chain_env"
fi

export ANTHROPIC_BASE_URL="http://$GATEWAY_HOST:$GATEWAY_PORT"
export ANTHROPIC_API_KEY="$GATEWAY_MASTER_KEY"
export ANTHROPIC_MODEL="${CHAIN_PRIMARY:-cloud}"
# Without this (or the "*" entry in the rendered config) Claude Code's haiku-class calls 400.
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${CHAIN_WILDCARD:-${CHAIN_PRIMARY:-cloud}}"
# 25 tok/s generation makes any idle timeout a false positive mid-answer.
export API_FORCE_IDLE_TIMEOUT=0
export CLAUDE_CODE_MAX_CONTEXT_TOKENS
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Each of these wins over ANTHROPIC_BASE_URL or redirects auth, so a leftover value from
# the operator's shell routes the run straight past the gateway to the provider that failed.
unset CLAUDE_CODE_USE_BEDROCK
unset CLAUDE_CODE_USE_VERTEX
unset ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_SMALL_FAST_MODEL
unset AWS_PROFILE
unset AWS_REGION

unset _gw_root _gw_ollama_ctx _gw_reserve _gw_chain_env

printf 'gateway env: %s model=%s max_context=%s\n' \
  "$ANTHROPIC_BASE_URL" "$ANTHROPIC_MODEL" "$CLAUDE_CODE_MAX_CONTEXT_TOKENS"
