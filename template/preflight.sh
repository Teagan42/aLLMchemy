#!/usr/bin/env bash
# Credential probe. Runnable form of the snippet in playbook/deploy-pipeline.md; extend it
# with the providers this product needs rather than rewriting it.
#
# A key that exists is not a key that works: wrong environment, insufficient scope and
# expired tokens all look identical in an env file. So every row is a live read-only call.
#
# ABSENT, FAIL and UNKNOWN are three different facts and must not be collapsed. ABSENT means
# the operator never supplied the key, so take the fallback tier silently. FAIL means a
# supplied key does not work, which needs a BLOCKER naming the remediation. UNKNOWN means
# nothing probed it — a missing client binary, not a bad credential — which is also a
# BLOCKER, naming the missing probe. Collapsing UNKNOWN into FAIL tells the operator to fix
# credentials that are fine and silently discards the resource they supplied.
#
# Exits 0 even when every probe fails. A dead probe must not end preflight, and nothing
# downstream can read CAPABILITIES.md if this aborts.

set -uo pipefail

out=''
case "${1:-}" in
  -h|--help) printf 'usage: preflight.sh [--out CAPABILITIES.md]\n'; exit 0 ;;
  --out)     out="${2:?--out needs a path}" ;;
  '')        ;;
  *)         printf 'preflight: unknown argument %s\n' "$1" >&2; exit 2 ;;
esac

# Intake `credentials_file` arrives as $CREDENTIALS_FILE. Default per QUESTIONNAIRE item 16.
CREDENTIALS_FILE="${CREDENTIALS_FILE:-./.env.intake}"
if [ -f "$CREDENTIALS_FILE" ]; then
  # Parsed, never sourced. Sourcing runs the operator's file as code: a stray `exit` from a
  # pasted dashboard snippet would end preflight before CAPABILITIES.md is written, and a
  # syntax error mid-file would load half the environment and continue silently.
  ignored=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    case "$line" in *=*) ;; *) ignored=$((ignored + 1)); continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in ''|*[!A-Za-z0-9_]*) ignored=$((ignored + 1)); continue ;; esac
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$key=$val"
  done < "$CREDENTIALS_FILE"
  creds_note="credentials file $CREDENTIALS_FILE parsed"
  [ "$ignored" -gt 0 ] && creds_note="$creds_note; $ignored line(s) ignored, not KEY=VALUE"
else
  creds_note="credentials file absent: probing the environment only"
fi
printf '%s\n\n' "$creds_note"

results=$(mktemp) || exit 1
trap 'rm -f "$results"' EXIT INT TERM

# Emits exactly one of OK / FAIL / ABSENT / UNKNOWN.
#
# UNKNOWN when the probe's own client binary is not installed: a 127 from a missing psql or
# flyctl is indistinguishable from an auth rejection, and calling that FAIL downgrades the
# whole run over a credential that works.
check() {
  name=$1
  value=$2
  shift 2
  if [ -z "$value" ]; then
    status=ABSENT
  elif ! command -v "$1" >/dev/null 2>&1; then
    status=UNKNOWN
  elif "$@" >/dev/null 2>&1; then
    status=OK
  else
    status=FAIL
  fi
  printf '%-28s %s\n' "$name" "$status"
  printf '%s\t%s\n' "$name" "$status" >> "$results"
}

status_of() { awk -F'\t' -v n="$1" '$1 == n { print $2; found=1 } END { if (!found) print "UNKNOWN" }' "$results"; }

# Secrets are never printed; only the key shape is, and only enough to resolve the mode.
stripe_mode=unknown
case "${STRIPE_SECRET_KEY:-}" in
  sk_live_*) stripe_mode=live ;;
  sk_test_*) stripe_mode=test ;;
  '')        stripe_mode=absent ;;
  *)         stripe_mode=unrecognised ;;
esac

# Every provider intake.schema.json accepts gets a row. A schema-valid provider with no
# probe used to resolve to `none`, which collapsed a run with working credentials to Tier D.
check stripe   "${STRIPE_SECRET_KEY:-}" \
  curl -sf -m 15 -u "${STRIPE_SECRET_KEY:-}:" https://api.stripe.com/v1/balance
check lemonsqueezy "${LEMONSQUEEZY_API_KEY:-}" \
  curl -sf -m 15 -H "Authorization: Bearer ${LEMONSQUEEZY_API_KEY:-}" \
       -H 'Accept: application/vnd.api+json' https://api.lemonsqueezy.com/v1/users/me
check paddle   "${PADDLE_API_KEY:-}" \
  curl -sf -m 15 -H "Authorization: Bearer ${PADDLE_API_KEY:-}" https://api.paddle.com/event-types
check polar    "${POLAR_ACCESS_TOKEN:-}" \
  curl -sf -m 15 -H "Authorization: Bearer ${POLAR_ACCESS_TOKEN:-}" https://api.polar.sh/v1/organizations/

check vercel   "${VERCEL_TOKEN:-}" \
  curl -sf -m 15 -H "Authorization: Bearer ${VERCEL_TOKEN:-}" https://api.vercel.com/v2/user
check fly      "${FLY_API_TOKEN:-}"  flyctl auth whoami
check render   "${RENDER_API_KEY:-}" \
  curl -sf -m 15 -H "Authorization: Bearer ${RENDER_API_KEY:-}" 'https://api.render.com/v1/services?limit=1'
check railway  "${RAILWAY_TOKEN:-}" \
  curl -sf -m 15 -H "Authorization: Bearer ${RAILWAY_TOKEN:-}" -H 'Content-Type: application/json' \
       -d '{"query":"{ me { id } }"}' https://backboard.railway.com/graphql/v2
check cloudflare "${CLOUDFLARE_API_TOKEN:-}" \
  curl -sf -m 15 -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN:-}" \
       https://api.cloudflare.com/client/v4/user/tokens/verify
check vps-ssh  "${SSH_HOST:-}" ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_HOST:-}" true

check resend   "${RESEND_API_KEY:-}" \
  curl -sf -m 15 -H "Authorization: Bearer ${RESEND_API_KEY:-}" https://api.resend.com/domains
check database "${DATABASE_URL:-}"   psql "${DATABASE_URL:-}" -c 'select 1'

stripe_status=$(status_of stripe)
resend_status=$(status_of resend)
db_status=$(status_of database)

BILLERS='stripe lemonsqueezy paddle polar'
HOSTS='fly vercel render railway cloudflare vps-ssh'

# First provider in preference order whose probe returned $1. Resolves `*: auto` without
# asking: an OK pass, then an UNKNOWN pass, so a token nobody could probe still counts as
# supplied. UNKNOWN is not ABSENT.
first_with() {
  want=$1
  shift
  for p in "$@"; do
    [ "$(status_of "$p")" = "$want" ] && { printf '%s' "$p"; return 0; }
  done
  printf 'none'
}

billing=$(first_with OK $BILLERS)
billing_probed=1
if [ "$billing" = none ]; then
  billing=$(first_with UNKNOWN $BILLERS)
  billing_probed=0
fi

hosting=$(first_with OK $HOSTS)
hosting_probed=1
if [ "$hosting" = none ]; then
  hosting=$(first_with UNKNOWN $HOSTS)
  hosting_probed=0
fi

billing_resolution="billing_provider: auto -> none; BLOCKER, no billing"
if [ "$billing" != none ] && [ "$billing_probed" -eq 1 ]; then
  billing_resolution="billing_provider: auto -> $billing"
  [ "$billing" = stripe ] && billing_resolution="$billing_resolution; mode -> $stripe_mode"
elif [ "$billing" != none ]; then
  billing_resolution="billing_provider: auto -> $billing, credential present but unprobed; BLOCKER, install its client and re-run"
elif [ "$(first_with FAIL $BILLERS)" != none ]; then
  billing_resolution="key supplied but rejected by $(first_with FAIL $BILLERS); BLOCKER"
fi

hosting_resolution='no host token; Docker artifact only'
if [ "$hosting" != none ] && [ "$hosting_probed" -eq 1 ]; then
  hosting_resolution="hosting: auto -> $hosting"
  [ "$hosting" = fly ] && hosting_resolution='hosting: auto -> fly (native cron via machines)'
elif [ "$hosting" != none ]; then
  hosting_resolution="hosting: auto -> $hosting, token present but unprobed; BLOCKER, install its client and re-run"
elif [ "$(first_with FAIL $HOSTS)" != none ]; then
  hosting_resolution="host token supplied but rejected by $(first_with FAIL $HOSTS); BLOCKER"
fi

database_resolution='database: auto -> none; SQLite on a mounted volume'
[ "$db_status" = OK ] && database_resolution='database: auto -> supplied DATABASE_URL'
# A supplied URL nobody could probe is still the operator's database. Discarding it for a
# missing psql is the bug this state exists to prevent.
[ "$db_status" = UNKNOWN ] && database_resolution='database: auto -> supplied DATABASE_URL, unverified (no psql on PATH); BLOCKER'
[ "$db_status" = FAIL ] && database_resolution='DATABASE_URL supplied but rejected; BLOCKER'

email_resolution='no transport; log transport behind the same interface'
[ "$resend_status" = OK ] && email_resolution='Resend; sends from onboarding@resend.dev until DNS verified'

# Tier is the achievable outcome tier from playbook/00-kickoff.md. Decided here, in Phase 1,
# because every later phase's definition of done depends on it.
#
# Intake `go_live` arrives as $GO_LIVE. Without it Tier L is unreachable, so it is in
# QUESTIONNAIRE item 3 and template/README.md's Environment table.
tier=D
if [ "$hosting" != none ] && [ "$hosting_probed" -eq 1 ]; then
  tier=T
  [ "${GO_LIVE:-false}" = true ] && [ "$stripe_mode" = live ] && [ "$stripe_status" = OK ] && tier=L
fi

# Status is a bare OK / FAIL / ABSENT / UNKNOWN. Annotation belongs in the Resolution
# column, so a downstream grep for a status word cannot match a parenthetical.
render() {
  printf '# Capabilities (probed %s)\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '| Capability | Provider | Status | Resolution |\n'
  printf '|---|---|---|---|\n'
  [ "$billing" = none ] && printf '| Billing | — | ABSENT | %s |\n' "$billing_resolution"
  for p in $BILLERS; do
    printf '| Billing | %s | %s | %s |\n' "$p" "$(status_of "$p")" \
      "$([ "$p" = "$billing" ] && printf '%s' "$billing_resolution" || printf 'not used')"
  done
  [ "$hosting" = none ] && printf '| Hosting | — | ABSENT | %s |\n' "$hosting_resolution"
  for p in $HOSTS; do
    printf '| Hosting | %s | %s | %s |\n' "$p" "$(status_of "$p")" \
      "$([ "$p" = "$hosting" ] && printf '%s' "$hosting_resolution" || printf 'not used')"
  done
  printf '| Database | %s | %s | %s |\n' \
    "$([ "$db_status" = ABSENT ] && echo '—' || echo 'supplied URL')" "$db_status" "$database_resolution"
  printf '| Email | %s | %s | %s |\n' \
    "$([ "$resend_status" = ABSENT ] && echo '—' || echo 'Resend')" "$resend_status" "$email_resolution"
  printf '| SMS | — | UNKNOWN | not probed; SMS add-on built and disabled |\n'
  printf '| DNS | — | UNKNOWN | not probed; platform subdomain |\n'
  printf '| Error tracking | — | UNKNOWN | not probed; structured stderr logging only |\n'
  printf '\n## Resolved configuration\n'
  # Every key a later phase reads. release-captain reads domain= to decide whether to wire
  # DNS, so a key documented but never emitted is a phase that re-derives it silently.
  printf 'hosting=%s database=%s billing=%s mode=%s domain=%s region=%s tier=%s\n' \
    "$hosting" "$([ "$db_status" = ABSENT ] && echo sqlite || echo supplied)" \
    "$billing" "$stripe_mode" "${APP_DOMAIN:-platform-subdomain}" "${APP_REGION:-provider-default}" "$tier"
}

printf '\n'
render
if [ -n "$out" ]; then
  render > "$out"
  printf '\npreflight: wrote %s\n' "$out"
fi

exit 0
