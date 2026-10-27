#!/usr/bin/env bash
# Gate `security` — product-independent, so it is implemented here rather than delegated.
#
# A committed secret and an unauthenticated mutating route are two of the three failures
# that must never be downgraded to blockers, so this gate proves both by file and by test,
# not by an inventory handed over by another agent.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate security'

cd "$PROJECT_DIR" || { bad "cannot enter $PROJECT_DIR"; finish security; }

# Working tree plus every reachable commit. Exit 0 clean, 1 on a hit.
scan="${SECRET_SCAN:-$TEMPLATE_DIR/secret-scan.sh}"
if [ -x "$scan" ]; then
  run_sh "'$scan' '$PROJECT_DIR'"
else
  bad "the only sanctioned secret scan is missing or not executable: $scan"
fi

if command -v pnpm >/dev/null 2>&1; then
  run_sh "${AUDIT_CMD:-pnpm audit --audit-level=high}"
elif command -v npm >/dev/null 2>&1; then
  run_sh "npm audit --audit-level=high"
else
  bad 'no package manager on PATH, so dependency vulnerabilities are unproven'
fi

# Locates a test file by any of several conventional names, then proves it carries the
# assertion. A missing file is a FAIL and so is an empty one: presence is self-report, and
# two `touch`ed files would otherwise certify both never-downgradable security failures.
#
# `find` rather than a `src/**/` glob: bash 3.2 has no globstar, so `**` collapses to `*`
# and a real test one directory deeper is never matched.
locate() {
  label=$1
  marker=$2
  what=$3
  nested=$4
  shift 4
  found=''
  for p in "$@"; do
    for f in $p; do
      [ -f "$f" ] && { found=$f; break; }
    done
    [ -n "$found" ] && break
  done
  if [ -z "$found" ] && [ -d src ]; then
    found=$(find src -type f -name "$nested" 2>/dev/null | head -1)
  fi
  if [ -z "$found" ]; then
    bad "$label test file not found (looked for: $*, and src/**/$nested)"
    return 1
  fi
  if [ ! -s "$found" ]; then
    bad "$label test file is empty: $found. The assertion it carries is the gate."
    return 1
  fi
  if ! grep -Eqi -- "$marker" "$found"; then
    bad "$label test file $found does not assert $what (no match for /$marker/)"
    return 1
  fi
  ok "$label: $found"
}

locate 'security headers' \
  'content-security-policy|strict-transport-security|x-frame-options|x-content-type-options|referrer-policy' \
  'the response header names' \
  'headers.test.*' \
  "${SECURITY_HEADERS_TEST:-}" \
  'tests/security/headers.*' 'test/security/headers.*' 'e2e/security/headers.*'

locate 'auth on every mutating route' \
  '40[13]|unauthori[sz]ed|forbidden' \
  'a 401 or 403 on an unauthenticated request' \
  'auth-routes.test.*' \
  "${AUTH_ROUTES_TEST:-}" \
  'tests/security/auth-routes.*' 'test/security/auth-routes.*' 'e2e/security/auth-routes.*'

# Present is not passing. The suite that owns those two files has to exit 0.
delegate security "${SECURITY_TEST_CMD:-pnpm test:gate:security}"

say 'also asserted by that suite: no horizontal privilege escalation, rate limits on auth,'
say 'signup, reset and expensive endpoints, argon2id or bcrypt >= 12, HttpOnly/Secure/'
say 'SameSite=Lax cookies, parameterised queries only, escaped output, CSRF-exempt but'
say 'signature-verified webhook route.'

finish security
