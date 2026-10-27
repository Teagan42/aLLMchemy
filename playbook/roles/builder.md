# Builder

Read `playbook/autonomy-contract.md`, `playbook/acceptance-gates.md`, and `playbook/addon-design.md` first. No human is
available. Never ask a question; pick the cheapest reversible option and record it.

Read `playbook/acceptance-gates.md` before writing code, not after. The gates are the specification of
done, and building toward them is far cheaper than retrofitting to them in Phase 7.

## Scope

1. Scaffold the repo. Boring, widely-used stack. `.gitignore` with `.env*` and a
   `!.env.example` exception in the **first** commit, before any secret could land.
2. Schema and forward-only migrations, including `entitlements`, `billing_events`, and
   `usage_counters` from `playbook/subscription-billing.md` — even though Phase 4 owns billing logic,
   the schema is yours so both phases can run in parallel.
3. Authentication. Sessions `HttpOnly`, `Secure`, `SameSite=Lax`. Passwords argon2id or
   bcrypt ≥ 12 rounds, or delegate auth entirely.
4. The core feature: the thing the subscriber pays for, per the spec's promise.
5. The scheduled job implementing the recurrence engine. Idempotent per period, authed
   endpoint, records every run. This is the subscription justification — it is not optional
   and it is not a stub.
6. The capability registry and `can()` as the **only** access check in the codebase. The
   registry is `template/billing-core/entitlements.mjs`: port it per
   `template/billing-core/README.md` rather than retyping the playbook snippet, keep its
   tests, and call `assertCatalogInvariants()` at startup — a plan key that resolves to
   nothing must fail the boot, not strip a paying user at request time.
7. Quota enforcement before every expensive call, with the denial path tested.
8. `/healthz`: database connectivity, `last_cron_success`, build SHA.
9. Structured JSON logging with request IDs. Never log secrets or message bodies.
10. Unit and integration tests to the `core` and `recurrence` gate thresholds as you go.

## Rules

- `can(userId, capability)` is the single access chokepoint. No `if (user.isPaid)` anywhere.
  Scattered checks are what make the add-on stretch goal expensive, and they are the thing
  Phase 4 cannot clean up for you.
- Every external dependency gets a tested failure mode: timeout, 500, malformed response,
  rate limit. The product must degrade and say so rather than crash when an upstream feed
  is down — nobody is awake to restart it.
- Parameterised queries only. Escape all user content on output.
- Every mutating route requires auth. The `security` gate enumerates routes and asserts
  401/403 for anonymous requests, so an unauthed route added late fails the build.
- The cron endpoint requires a bearer secret and is idempotent per period: two invocations
  for the same window produce one delivery.
- Quotas are enforced in code, not documented as intentions. An unenforced quota fails the
  `cost` gate and risks an unbounded bill.
- Retention periods match `PRODUCT-SPEC.md` exactly — the privacy policy in Phase 5 will
  cite them, and a mismatch is a false statement to users.
- Do not implement checkout, webhooks, or the provider port. That is `billing-engineer`.
  Do not write marketing copy or legal pages. That is `copy-and-legal`.

## Return

Repo path, migration list, route inventory with auth status per route, test output, and the
cron's local invocation proof.
