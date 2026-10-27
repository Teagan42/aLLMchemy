# Deploy Pipeline

Two failure modes to design against. First, discovering in Phase 6 that a credential was
never valid — which is why preflight happens in Phase 1, before a single line of code
depends on a platform. Second, treating a missing credential as a question. Every gap here
has a documented fallback; take it, log a `BLOCKER`, keep moving.

## Preflight

Probe each credential with the cheapest read-only call available. A key that exists is not
a key that works: wrong environment, insufficient scope, and expired tokens all look
identical in an env file.

**Run `template/preflight.sh`.** Extend that script with the providers this product needs;
do not retype it here. Only its `check` helper is reproduced below, because the surrounding
machinery — credential parsing, the results file, `status_of`, the Stripe mode detection,
the provider-preference resolution and the tier computation — is the part a rewrite gets
wrong.

```sh
# Emits exactly one of OK / FAIL / ABSENT / UNKNOWN. A dead probe must not end preflight.
#
# -m 15 on every curl, without exception. A provider endpoint that accepts the connection
# and never answers would hang Phase 1 forever, which is the permanent stall the whole
# autonomy contract exists to prevent.
check() {
  name=$1
  value=$2
  shift 2
  if [ -z "$value" ]; then
    status=ABSENT
  elif ! command -v "$1" >/dev/null 2>&1; then
    status=UNKNOWN            # the client binary is missing, not the credential
  elif "$@" >/dev/null 2>&1; then
    status=OK
  else
    status=FAIL
  fi
  printf '%-28s %s\n' "$name" "$status"
  printf '%s\t%s\n' "$name" "$status" >> "$results"
}
```

`ABSENT`, `FAIL` and `UNKNOWN` are three different facts and must not be collapsed.
`ABSENT` means the operator never supplied the key, so take the fallback tier silently.
`FAIL` means a supplied key does not work, which needs a `BLOCKER` naming the remediation.
`UNKNOWN` means nothing probed it — a missing `psql` or `flyctl`, not a bad credential —
which is also a `BLOCKER`, naming the missing probe. Calling that `FAIL` tells the operator
to fix credentials that are fine and silently discards the database they supplied.

The credentials file is **parsed, never sourced.** Sourcing runs the operator's file as
code: a stray `exit` from a pasted dashboard snippet would end preflight before
`CAPABILITIES.md` is written, and a syntax error mid-file would load half the environment
and continue silently. Read `KEY=VALUE` lines, reject anything that is not, and export each.

Probe every provider `intake.schema.json` accepts, not just the two with a client installed.
A schema-valid provider with no probe row used to resolve to `none`, which collapsed a run
with working Render and Polar credentials to Tier D.

The credentials file is optional. README step 2 lets the operator skip it, and preflight
must still probe whatever the environment already carries.

Also detect, for Stripe: whether the key is `sk_test_` or `sk_live_` — this resolves
test-vs-live mode per `playbook/subscription-billing.md` without consulting anyone.

### CAPABILITIES.md

Preflight's only output, and the contract every later phase reads. Nothing downstream may
assume a capability absent from this file.

```markdown
# Capabilities (probed <timestamp>)

| Capability | Provider | Status | Resolution |
|---|---|---|---|
| Billing | stripe | OK | `billing_provider: auto` → stripe; mode → test |
| Billing | paddle | ABSENT | not used |
| Hosting | fly | OK | `hosting: auto` → fly (native cron via machines) |
| Hosting | vercel | FAIL | Token lacks scope (403); not used |
| Database | supplied URL | OK | `database: auto` → supplied DATABASE_URL |
| Email | Resend | OK | Sends from `onboarding@resend.dev` until DNS verified |
| SMS | — | UNKNOWN | not probed; SMS add-on built and disabled; BLOCKER 1 |
| DNS | — | UNKNOWN | not probed; platform subdomain; `domain` ignored; BLOCKER 2 |
| Error tracking | — | UNKNOWN | not probed; structured stderr logging only |

## Resolved configuration
hosting=fly database=supplied billing=stripe mode=test domain=<app>.fly.dev region=us-east tier=T
```

The Status cell is a bare `OK` / `FAIL` / `ABSENT` / `UNKNOWN` and nothing else. Annotation
goes in the Resolution column: a downstream grep for a status word must not match a
parenthetical. An unprobed row is `UNKNOWN`, never `ABSENT` — collapsing "nobody looked"
into "the operator supplied nothing" is the exact failure the three-state rule prevents.

`tier` is the achievable outcome tier from `playbook/00-kickoff.md` — L, T, or D. It is
decided here, in Phase 1, because every later phase's definition of done depends on it.

## Fallback tiers

Descend until something works. Each descent is a `DECISIONS.md` row; each exhausted class
is a `BLOCKER`.

**Hosting:** intake choice → any platform with a valid token, preferring native scheduled
jobs → Docker + compose + `deploy.sh`, verified by running the container locally and
passing E2E against it.

The first two tiers reach a public URL: **Tier L** with `go_live: true` and live keys that
validate, **Tier T** otherwise. The last tier is **Tier D** — a tested, deployable artifact
and better than nothing, but not a launch. It is always a `BLOCKER`. The three tiers are
defined in `playbook/00-kickoff.md`.

**Scheduled jobs**, in order of preference, since G6 products are nothing without them:

| Tier | Mechanism | Note |
|---|---|---|
| 1 | Platform scheduler (Fly machines, Vercel cron, Render cron, Cloudflare Triggers) | Preferred |
| 2 | External pinger (GitHub Actions schedule) hitting an authed `/api/cron/*` route | Needs a secret header |
| 3 | In-process scheduler on an always-on instance | Breaks on multi-instance; add an advisory lock |
| 4 | DB-backed queue drained on request | Degraded; log a BLOCKER |

Whatever the tier, the job endpoint must require a bearer secret, be idempotent per period,
and record its last successful run so the verifier can prove it fired.

**Database:** intake choice → host-adjacent managed option → any valid managed credential →
SQLite on a mounted volume. Migrations must be identical across all tiers, so use a
migration tool rather than hand-written DDL.

**Email:** Resend → Postmark → SendGrid → log transport behind the same interface. With the
log transport, email tests assert against the outbox rather than being skipped — the feature
stays verified even when delivery is not.

**Domain and TLS:** intake `domain` with valid DNS creds → platform subdomain. Never block
on DNS propagation beyond 5 minutes; proceed on the subdomain and log the blocker. TLS is
whatever the platform issues automatically; do not hand-roll certificates.

## Secret injection

```sh
# Read from the credentials file, write to the host's secret store. Never into the repo.
fly secrets set DATABASE_URL="$DATABASE_URL" STRIPE_SECRET_KEY="$STRIPE_SECRET_KEY" --stage
vercel env add STRIPE_SECRET_KEY production < <(printf '%s' "$STRIPE_SECRET_KEY")
```

Checks before the first deploy: `.gitignore` covers `.env*` with a `!.env.example`
exception; `.env.example` has every key with empty values; no secret appears in any
committed file, Dockerfile `ARG`, or CI log.

## Release sequence

Order matters — each step's failure mode is cheaper to hit before the next.

1. **Build locally.** Typecheck, lint, unit tests, production build. Never deploy an
   unbuilt tree.
2. **Provision database.** Create, capture the URL, store as a secret.
3. **Migrate.** Forward-only. Verify the schema landed by querying it.
4. **Deploy.** Capture the deployment URL from CLI output — do not assume its shape.
5. **Wait for health.** Poll `/healthz` until 200, 60s timeout. It must check database
   connectivity, not just return a literal.
6. **Sync the plan catalog.** Create products and prices via API, idempotently by lookup
   key, so a re-run does not duplicate them.
7. **Register the webhook endpoint** at the real deployed URL; store the returned signing
   secret as a secret. Then send a test event and confirm a 200 plus a `billing_events` row.
8. **Schedule the cron** at the chosen tier. Trigger it once manually and assert it produced
   output.
9. **DNS**, if applicable. Then re-verify health on the custom domain.
10. **Smoke test** against the public URL, per `playbook/acceptance-gates.md`.
11. **Tag and record** the release SHA in `HANDOFF.md`.

## Rollback

Required before the deploy is considered done — an untested rollback is not a rollback.

- Record the previous deployment ID or image digest before deploying.
- `rollback.sh` reverts to it in one command, documented in `RUNBOOK.md`.
- Migrations are forward-only and additive. No destructive migration in the same release
  as the code that stops using the column; a rollback would then hit a missing field.
- **Kill switch:** `FEATURE_KILL=true` serves a maintenance page and halts cron and
  outbound messaging, while leaving billing webhooks answering 200. Tested, not just
  written — an untested kill switch fails exactly when it is needed.

## Observability floor

- `/healthz` — database connectivity, last cron success timestamp, build SHA.
- Structured JSON logs with a request ID. Never log secrets, full emails, or message bodies.
- Error tracking if a DSN exists; otherwise structured stderr, which the platform retains.
- A daily cost-and-usage log line: active subscribers, messages sent, inference tokens,
  estimated spend. This is what proves the G4 unit-economics ceiling holds in production
  rather than just on paper.
- Daily automated database backup, with the restore command written in `RUNBOOK.md`.
