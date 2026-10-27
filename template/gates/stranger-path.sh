#!/usr/bin/env bash
# Gate `stranger-path` — the gate that subsumes the others. Ten steps in a clean browser
# profile with no seeded state, desktop and 390px mobile, against the deployed public URL.
#
# A local container is a Tier D target, so it is a declared SKIP with a named BLOCKER, never
# a PASS. Passing here is what the HANDOFF.md tier line is derived from: if a local run
# could pass, nothing downstream could tell Tier D from Tier L.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate stranger-path'

target="${APP_URL:-}"
if [ -z "$target" ]; then
  bad 'APP_URL is unset: there is no deployed URL to exercise. Tier D runs must set it to the local container.'
  finish stranger-path
fi

case "$target" in
  http://*|https://*) ;;
  *) bad "APP_URL is not an http(s) URL: $target"; finish stranger-path ;;
esac

host=$(host_of "$target")
if is_local_host "$host"; then
  say "target $target (host $host)"
  skip "stranger-path verified against local container only, no public URL (Tier D). Deploy to a public URL and re-run."
fi

ok "target $target"

# Reachability before delegating. The product command may not read APP_URL at all, so
# without this the gate can certify a deployment that does not exist.
if ! command -v curl >/dev/null 2>&1; then
  bad 'curl is not on PATH, so APP_URL is unprobed'
else
  code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$target" 2>/dev/null)
  case "${code:-000}" in
    2??|3??) ok "$target answered $code" ;;
    000)     bad "$target did not respond: a stranger cannot reach this deployment" ;;
    *)       bad "$target answered $code; a stranger's first request must not be an error" ;;
  esac
fi

delegate stranger-path "${STRANGER_PATH_TEST_CMD:-pnpm test:gate:stranger-path}"

finish stranger-path
