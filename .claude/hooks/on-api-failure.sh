#!/usr/bin/env bash
# StopFailure breadcrumb. The hook has no decision control — Claude Code ignores its output
# and its exit code — so its only job is to leave a precise record of why the turn died.
#
# The payload's `matcher` is the harness's own typed error class: rate_limit, overloaded,
# authentication_failed, cloud_credential_error, invalid_request, server_error, unknown, and
# the rest. bin/run-factory.sh treats that token as authoritative. Regex-matching error
# prose is the alternative, and that is why an unrecognised failure used to be fatal.
#
# Fails open and silent: a broken breadcrumb must never affect the run. Records the class,
# the session id and a timestamp only — never a prompt, a message, or a credential value.

set -uo pipefail

payload=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# FACTORY_API_FAILURE_FILE is exported by bin/run-factory.sh, which may run the harness in a
# work directory other than the package root.
out="${FACTORY_API_FAILURE_FILE:-}"
if [ -z "$out" ]; then
  root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
  [ -n "$root" ] || exit 0
  out="$root/artifacts/.api-failure"
fi
mkdir -p "$(dirname "$out")" 2>/dev/null || exit 0

class=$(printf '%s' "$payload" | jq -r '.matcher // .error_class // .error.type // empty' 2>/dev/null)
session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)

# Keep every field a single token: the supervisor parses this file with sed, and a class
# carrying whitespace would truncate at the first space.
class=$(printf '%s' "${class:-unknown}" | tr -c 'A-Za-z0-9_.:-' '_')
session=$(printf '%s' "${session:-nosession}" | tr -c 'A-Za-z0-9_.:-' '_')
[ -n "$class" ] || class=unknown

printf 'class=%s session=%s ts=%s\n' \
  "$class" "$session" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out" 2>/dev/null || exit 0
exit 0
