# Intake Questionnaire

The only human interaction in this project. Fill it once.

**Every field has a default. Leaving the whole file blank is a valid submission.** The
agent resolves blanks from the default ladder in `playbook/autonomy-contract.md` and records
what it chose in `DECISIONS.md`. It will not come back to you.

Answers go in `intake.yaml`. Secrets go in `.env.intake`. Keep them separate — the agent
commits the former and never the latter.

---

## Part 1 — Product direction (1 question)

**1. `product_direction`** — free text, ≤ 200 characters, or blank.

A nudge, not a spec. "Something for parents", "aimed at small landlords", "nothing to do
with fitness". Blank means the agent picks freely.

> The agent will not build what you describe if it fails one of the `G1`–`G8` hard gates in
> `playbook/product-selection.md` (e.g. needs human labor, needs a content license, costs
> more than $1/user/month to run). It will pick the nearest archetype that passes and record
> why.

---

## Part 2 — Commercial (4 questions)

**2. `billing_provider`** — `stripe` | `lemonsqueezy` | `paddle` | `polar` | `auto`
Default `auto` → Stripe if its keys validate, else first provider whose keys validate.
Merchant-of-record providers (Lemon Squeezy, Paddle) remove your sales-tax/VAT burden;
Stripe does not. Pick one of those if you don't want to handle tax.

**3. `go_live`** — `true` | `false`. Default `false`.
`false` ships a real deployment on a real URL wired to the provider's **test** mode — this
is **Tier T** in `playbook/00-kickoff.md`, a success and not a degradation. Real cards are
refused; test cards complete the flow. Flip to `true` later with one env change, documented
in `RUNBOOK.md`.
`true` targets **Tier L**: live keys present, a verified provider account, real cards
accepted. If live keys are absent the agent deploys in test mode, lands on Tier T, and logs
a `BLOCKER` — it does not ask.

The agent exports this value as `GO_LIVE` and `template/preflight.sh` reads it from there,
the same way `credentials_file` reaches `CREDENTIALS_FILE` (item 16). Without that export
Tier L is unreachable through the executable path: preflight defaults `GO_LIVE` to `false`,
writes `tier=T`, and a live launch silently reports as test mode with no gate to catch it.

**4. `price_usd`** — number. Default `5`.
The base monthly price. Changing this changes the unit-economics ceiling the product must
design to.

**5. `addons_enabled`** — `true` | `false`. Default `true`.
`true` pursues the stretch goal: an entitlements system, at least one priced add-on, and an
annual plan. `false` ships the single plan only.

---

## Part 3 — Infrastructure (5 questions)

**6. `hosting`** — `vercel` | `fly` | `render` | `railway` | `cloudflare` | `vps-ssh` | `auto`
Default `auto` → first platform whose credentials validate, preferring one that supports
scheduled jobs natively (most of these products need a cron).

**7. `database`** — `neon` | `supabase` | `turso` | `planetscale` | `sqlite-volume` | `auto`
Default `auto`. Must be compatible with the chosen host; the agent reconciles conflicts in
favour of the host.

**8. `domain`** — apex domain you control, or blank.
Blank → the platform-issued subdomain. If set, DNS credentials must be in `.env.intake` or
the agent falls back to the subdomain and logs a `BLOCKER`.

**9. `region`** — default `us-east`. Set `eu-west` if `audience_region` is `eu`.

**10. `monthly_infra_budget_usd`** — default `25`.
A hard ceiling on **fixed and scheduled-to-become-fixed** monthly price. The agent must
choose free and low tiers to fit it, and must enforce per-user quotas in code so that growth
cannot silently exceed it. Metered usage is bounded separately, by those quotas and by a
provider-side spend cap, not by this number.

Every resource it creates is logged to `PROVISIONED.md` with its fixed monthly price, a
Usage risk ceiling, and a teardown command. The agent exports this value as
`MONTHLY_INFRA_BUDGET_USD`; the `cost` gate sums the ledger's fixed column plus every
`converts-to:` amount against it, FAILs on a Usage risk cell that names no ceiling, and
FAILs rather than guessing a default if neither the variable nor this intake field is
present. `teardown.sh` destroys every row.

---

## Part 4 — Operating (6 questions)

**11. `comms_channel`** — `email` | `email+sms`. Default `email`.
SMS materially raises COGS (~$0.008/message) and needs 10DLC registration in the US, which
can take days. `email+sms` makes SMS a paid add-on, never a base-plan feature.

**12. `audience_region`** — `us` | `eu` | `global`. Default `us`.
Drives legal documents, cookie consent, data-subject request endpoints, and tax handling.
`eu` or `global` forces GDPR-grade export/delete endpoints and a consent banner.

**13. `operator_email`** — your email, or blank.
Receives the admin account, deploy notifications, and error digests. Blank → the agent
creates an admin account with generated credentials and writes them to `HANDOFF.md` only.

**14. `brand_tone`** — default `plain, friendly, concrete, no hype, no exclamation marks`.

**15. `escalation`** — `ship-degraded` | `halt`. Default `ship-degraded`.
What to do when an external blocker cannot be resolved (a credential is invalid, a provider
requires manual account verification).
- `ship-degraded`: complete every unblocked part of the scope, deploy what works, write the
  blocker and its exact remediation steps to `HANDOFF.md`. **Recommended.**
- `halt`: stop at the blocker and write the same report. Still never asks.

**16. `credentials_file`** — default `./.env.intake`.
The agent exports this value as `CREDENTIALS_FILE` and `template/preflight.sh` reads it from
there. The file is optional: if it does not exist, preflight prints `credentials file absent:
probing the environment only` and probes whatever the environment already carries.

**17. `model_chain`** — space-separated provider names. Default `cloud ollama`.
What the agent does when the model it is running on stops answering — an expired token, a
quota wall, a provider outage. Without a fallback that is fatal rather than slow: one run lost
nine parallel agents to an expired AWS SSO token and shipped nothing. The ladder is in
`playbook/autonomy-contract.md` under "Model availability".

The order *is* the configuration. The first name is the primary; the rest are fallbacks, tried
in order. Names come from `gateway/providers.conf`, which ships `cloud`, `ollama`, `ollama2`
and `mlx`.

| Chain | Means |
|---|---|
| `cloud ollama` | Cloud primary, local backstop. The default. |
| `cloud` | No fallback. A lapsed credential writes a `BLOCKER` and halts the affected scope — buys you a product no small local model touched, and costs you the run. |
| `mlx ollama` | Local primary, local backstop. Nothing leaves the machine. |
| `ollama cloud` | Local primary, cloud rescue. Cheap by default, correct when it matters. |

A local primary costs quality and wall-clock: 25–27 tokens/second, sequential phases only,
and a materially simpler product. It buys a finished handoff you can re-run on a cloud model
rather than a dead run and an empty repo.

Two providers on different local servers (`mlx` and `ollama` together) each hold their own
weights and will evict or OOM each other; the gateway refuses that chain unless you set
`FACTORY_ALLOW_MULTI_LOCAL=1`. Two models on the *same* server are fine.

Whatever the chain, the achieved model tier goes on `HANDOFF.md`'s first line, and a safety or
policy refusal is never re-routed to another model.

---

## Credential template

Write only the lines you have. The agent probes each one with a cheap read-only API call
during preflight and routes around whatever fails.

```sh
# .env.intake — never committed, never pasted into chat

# --- Billing (at least one provider) ---
STRIPE_SECRET_KEY=sk_test_...          # or sk_live_ if go_live=true
STRIPE_WEBHOOK_SECRET=whsec_...        # agent can create this itself if API key allows
LEMONSQUEEZY_API_KEY=
LEMONSQUEEZY_STORE_ID=
PADDLE_API_KEY=
POLAR_ACCESS_TOKEN=

# --- Hosting (at least one) ---
VERCEL_TOKEN=
FLY_API_TOKEN=
RENDER_API_KEY=
RAILWAY_TOKEN=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
VPS_SSH_HOST=                          # for hosting=vps-ssh
VPS_SSH_USER=
VPS_SSH_KEY_PATH=

# --- Database ---
NEON_API_KEY=
SUPABASE_ACCESS_TOKEN=
TURSO_API_TOKEN=
DATABASE_URL=                          # a ready-made connection string beats all of the above

# --- DNS (only if `domain` is set) ---
CLOUDFLARE_DNS_API_TOKEN=
VERCEL_DNS_TOKEN=

# --- Transactional email (required if the product emails users) ---
RESEND_API_KEY=
POSTMARK_SERVER_TOKEN=
SENDGRID_API_KEY=

# --- SMS (only if comms_channel=email+sms) ---
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_FROM_NUMBER=

# --- Optional: model inference, if the product needs it ---
ANTHROPIC_API_KEY=

# --- Optional: error tracking ---
SENTRY_AUTH_TOKEN=
SENTRY_DSN=
```

### What happens when a credential is missing

No question. A documented fallback:

| Missing | Fallback |
|---|---|
| All billing keys | Provider port implemented, Stripe adapter wired, test-mode stubs, checkout gated behind a flag. `BLOCKER` logged. |
| All hosting keys | **Tier D:** Dockerfile + compose + `deploy.sh`, build and E2E verified locally against a container. Not a launch; `BLOCKER` logged, and `verify.sh` exits non-zero because `stranger-path`, `operations` and `recurrence` all record a `SKIP`. |
| A hosting key whose client binary is absent | `UNKNOWN`, not `ABSENT`: the token is still the operator's. `BLOCKER` naming the missing probe; the tier stays D until something validates. |
| Live billing keys with `go_live: true` | **Tier T:** deploy on the public URL in test mode. `BLOCKER` logged. |
| All database keys | SQLite on a mounted volume, migrations identical. |
| DNS creds with `domain` set | Platform subdomain. |
| All email keys | Console/log transport behind the same interface; email tests assert on the outbox. `BLOCKER` logged. |
| SMS keys with `email+sms` | SMS add-on built and tested against a mock transport, disabled in production config. |
| The agent's own model credentials, mid-run | Fails over down the gateway chain to a local model and continues the build, or with a `model_chain` of cloud providers only logs a `BLOCKER` and halts. Never a question. |

A `BLOCKER` means `HANDOFF.md` gets the exact command or dashboard click that fixes it.
