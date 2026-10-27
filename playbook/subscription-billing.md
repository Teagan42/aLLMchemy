# Subscription Billing

Billing bugs are the expensive kind: they charge people wrongly, or give away the product,
and nobody is watching. Two rules carry most of the safety.

**Rule 1 — the provider is not your database.** Never gate a feature on a live API call to
the billing provider. Mirror subscription state into your own `entitlements` table, updated
by webhooks, and read only that. A provider outage must degrade billing operations, not
revoke every user's access.

**Rule 2 — webhooks arrive more than once, out of order, and late.** Any handler that is not
idempotent will eventually double-grant or double-charge. Treat exactly-once delivery as
something you build, not something you receive.

## Provider port

Define the interface first, implement one adapter, keep the rest as stubs that throw. The
port is what makes provider choice a config value instead of a rewrite — relevant because
`billing_provider: auto` resolves at preflight from whichever credentials validate.

```ts
// Single source of billing truth. Nothing outside src/billing/ imports a provider SDK.
export interface BillingProvider {
  createCheckoutSession(p: {
    userId: string; planKey: string; addonKeys?: string[];
    successUrl: string; cancelUrl: string;
  }): Promise<{ url: string }>;

  createPortalSession(p: { customerId: string; returnUrl: string }): Promise<{ url: string }>;

  // Must verify the signature and throw on mismatch. Never parse before verifying.
  parseWebhook(raw: Buffer, signature: string): Promise<BillingEvent>;

  getSubscription(id: string): Promise<SubscriptionSnapshot>;
  cancelAtPeriodEnd(id: string): Promise<void>;

  // Only DELETE /api/account calls this. Erasure cannot coexist with a served paid period.
  cancelImmediately(id: string): Promise<void>;

  resumeSubscription(id: string): Promise<void>;
  syncPlanCatalog(catalog: PlanCatalog): Promise<PlanCatalogResult>;  // idempotent by lookup key
}

// Normalized across providers. Adapters map vendor vocabulary into this and nothing else.
export type BillingEvent =
  | { kind: 'subscription.activated';  providerEventId: string; occurredAt: Date; customerId: string; subscriptionId: string; planKey: string; addonKeys: string[]; currentPeriodEnd: Date }
  | { kind: 'subscription.renewed';    providerEventId: string; occurredAt: Date; subscriptionId: string; currentPeriodEnd: Date }
  | { kind: 'subscription.updated';    providerEventId: string; occurredAt: Date; subscriptionId: string; planKey: string; addonKeys: string[]; currentPeriodEnd: Date; cancelAt: Date | null }
  | { kind: 'subscription.resumed';    providerEventId: string; occurredAt: Date; subscriptionId: string }
  | { kind: 'subscription.canceled';   providerEventId: string; occurredAt: Date; subscriptionId: string; effectiveAt: Date }
  | { kind: 'payment.failed';          providerEventId: string; occurredAt: Date; subscriptionId: string; attemptCount: number; nextAttemptAt: Date | null }
  | { kind: 'refund.issued';           providerEventId: string; occurredAt: Date; subscriptionId: string; amountCents: number }
  | { kind: 'unknown';                 providerEventId: string };
```

`occurredAt` is the provider's own event timestamp (Stripe's `created`). Anchor every
derived window to it, never to the apply clock: a grace period computed from `now()` slides
forward on every re-apply, so the dunning window silently extends itself.

`subscription.updated` carries `cancelAt` because it is a full snapshot. An absent
cancellation means the provider reports none, which is how a resume arrives — and
`subscription.resumed` exists so a thin resume event has a kind of its own. Leaving a stale
`cancel_at` in place makes the reconciler revoke a subscriber who is paid through the period.

`unknown` is deliberate: an unrecognised event type must be recorded and acknowledged with
a 200, never 500. Returning an error to an event you simply don't handle makes the provider
retry forever and can disable the endpoint.

## Entitlement model

```sql
-- Access truth. Read by the app; written only by webhook handlers and the reconciler.
CREATE TABLE entitlements (
  user_id            TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  plan_key           TEXT NOT NULL DEFAULT 'free',
  addon_keys         TEXT NOT NULL DEFAULT '[]',        -- JSON array
  status             TEXT NOT NULL DEFAULT 'inactive',  -- active|past_due|canceled|inactive
  current_period_end TIMESTAMPTZ,
  cancel_at          TIMESTAMPTZ,                       -- set on cancel; status flips only once it passes
  grace_until        TIMESTAMPTZ,                       -- access survives payment failure until here
  provider           TEXT,
  customer_id        TEXT,
  subscription_id    TEXT,
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Idempotency ledger. A claim leases the event; processed_at is the only "done" marker.
CREATE TABLE billing_events (
  provider_event_id  TEXT PRIMARY KEY,
  kind               TEXT NOT NULL,
  payload            JSONB NOT NULL,
  attempts           INTEGER NOT NULL DEFAULT 0,
  claimed_at         TIMESTAMPTZ,                       -- lease start; expires after 5 minutes
  processed_at       TIMESTAMPTZ,
  error              TEXT,
  received_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE usage_counters (
  user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period    TEXT NOT NULL,            -- 'YYYY-MM'
  metric    TEXT NOT NULL,
  count     BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, period, metric)
);
```

Every feature check goes through one function. One chokepoint means one place to audit and
one place to test.

```ts
// Sole access check. Liveness comes from dates, never from status alone: a canceled
// subscription is still paid for until current_period_end.
const entry = <T>(table: Record<string, T>, key: string): T | undefined =>
  Object.prototype.hasOwnProperty.call(table, key) ? table[key] : undefined;

export async function can(userId: string, capability: Capability): Promise<boolean> {
  const e = await getEntitlement(userId);
  const now = new Date();
  const live =
       (e.status === 'active'   && (e.currentPeriodEnd == null || e.currentPeriodEnd > now))
    || (e.status === 'past_due' && e.graceUntil      != null && e.graceUntil      > now)
    || (e.status === 'canceled' && e.currentPeriodEnd != null && e.currentPeriodEnd > now);
  if (!live) return CAPABILITIES.free.includes(capability);
  // Own-property lookup only. A drifted catalog or provider payload with planKey
  // 'constructor' otherwise resolves to Object's constructor and throws on the spread.
  const fromPlan   = entry(CAPABILITIES, resolvePlan(e.planKey)) ?? [];
  const fromAddons = e.addonKeys.flatMap(k => entry(CAPABILITIES, k) ?? []);
  // free is the floor, not an alternative: registry entries list incremental grants only.
  return [...CAPABILITIES.free, ...fromPlan, ...fromAddons].includes(capability);
}
```

`resolvePlan` and the registry live in `playbook/addon-design.md`; a plan key that resolves
to no `CAPABILITIES` entry must fail startup there, not silently strip a paying user.

## Webhook handler

```ts
// Order is load-bearing: verify, then claim, then act. Changing it creates a forgery or
// double-processing hole.
export async function handleWebhook(req: Request): Promise<Response> {
  const raw = await rawBody(req);                       // raw bytes; a parsed body breaks the HMAC
  let event: BillingEvent;
  try {
    event = await provider.parseWebhook(raw, req.headers.get(SIG_HEADER) ?? '');
  } catch {
    return new Response('bad signature', { status: 400 });  // 400, not 500: do not invite retries
  }

  // Atomic claim. Re-claims only an unprocessed event whose lease has expired, so a failed
  // apply is retryable while two simultaneous deliveries collapse into one apply.
  // oneOrNone, never `one`: every common Postgres client rejects on zero rows, which is
  // exactly the duplicate/in-flight case the `if (!claim)` branch below is written for.
  const claim = await db.oneOrNone(`
    INSERT INTO billing_events (provider_event_id, kind, payload, claimed_at, attempts)
    VALUES ($1, $2, $3, now(), 1)
    ON CONFLICT (provider_event_id) DO UPDATE
      SET claimed_at = now(), attempts = billing_events.attempts + 1, error = NULL
      WHERE billing_events.processed_at IS NULL
        AND (billing_events.claimed_at IS NULL OR billing_events.claimed_at < now() - interval '5 minutes')
    RETURNING attempts;
  `, [event.providerEventId, event.kind, event]);

  // No row: already processed, or a fresh lease is held elsewhere. A 2xx ends the
  // provider's retry schedule, so this acknowledgement can drop the event on its own — the
  // reconciler, not the provider, is what guarantees an unapplied event is replayed.
  if (!claim) return new Response('duplicate or in flight', { status: 200 });

  try {
    // One transaction, processed_at included. Committing the apply and then losing the
    // connection before the marker lands leaves a done event re-runnable, and a real
    // duplicate then applies twice.
    await db.transaction(async tx => {
      await applyEvent(event, tx);
      await tx.update('billing_events', { processed_at: new Date() }, { provider_event_id: event.providerEventId });
    });
  } catch (err) {
    // processed_at stays NULL, so the expired lease lets the next delivery re-claim.
    await db.update('billing_events', { error: String(err) }, { provider_event_id: event.providerEventId });
    if (claim.attempts >= 5) {
      // Dead-letter: more 500s would get the endpoint disabled. The reconciler owns it now.
      alert('billing_event_dead_letter', { providerEventId: event.providerEventId, error: String(err) });
      return new Response('dead-lettered', { status: 200 });
    }
    return new Response('retry', { status: 500 });
  }
  return new Response('ok', { status: 200 });
}
```

The runnable version of this handler lives at `template/billing-core/`, and its tests are the
matrix below.

Required properties:

- Raw-body signature verification before any parsing.
- The lease claim on `provider_event_id` as the idempotency key. `processed_at IS NULL` is
  the only thing that makes an event re-runnable; the 5-minute lease is what keeps a failed
  apply retryable without letting two concurrent deliveries both apply it.
- Mutations inside one transaction; partial application is worse than none.
- 400 for forgery, 200 for duplicates, in-flight events, unknown kinds and dead letters,
  500 only for retryable errors below `attempts >= 5`.
- `processed_at` set inside the apply transaction. A separate statement after the commit is
  a window in which a successfully-applied event stays re-runnable.
- `payment.failed` and `refund.issued` idempotent: grace as `laterOf(existing, occurredAt +
  GRACE)` and the dunning email and refund record both unique on `provider_event_id`.
  `applyEvent` can legitimately run twice for one event and must not emit twice.
- Any event with `processed_at IS NULL` and an expired lease is the reconciler's to replay,
  whatever its attempt count. Paid events that never applied are the one billing failure
  that cannot be recovered from logs, and a 2xx to a retry inside the lease means the
  provider will not deliver it again.
- The route is exempt from CSRF and from body-parsing middleware. Framework defaults that
  parse JSON will silently break HMAC verification; this is the single most common cause of
  "webhooks work locally, fail in production".

## Reconciler

Webhooks get lost. Run a daily job that pulls each active subscription from the provider
and repairs drift, logging every correction. This is the safety net that catches the bug
nobody is awake to notice. The `billing` gate in `playbook/acceptance-gates.md` fails
without it: it is the only thing that flips a row after the period ends and the only thing
that replays an event that never applied.

The same sweep owns two writes the webhook path deliberately does not make: it flips
`status` to `'canceled'` once `cancel_at <= now()`, and it re-applies **every** event left
with `processed_at IS NULL` whose lease has expired — not only the ones that reached five
attempts. A provider that received a 200 for a retry landing inside the lease stops
retrying, so a row stuck at one attempt is dropped forever if the sweep only owns dead
letters. The attempt count decides alert severity, never whether the event is replayed.

The sweep takes the same lease a delivery would before re-applying. Without it the sweep and
a late redelivery both apply, which sends two dunning emails and records two refunds.

The ledger's `payload` is `JSONB`, so it hands timestamps back as strings. Revive them
before re-applying: comparing a string to a `Date` makes every liveness check false, and
the event is then marked processed while the customer has no access.

Revoke by `status` alone. Clearing `plan_key` to `'free'` loses what the customer bought, so
a card that finally succeeds brings them back on the free plan; `can()` and `quotaFor()`
already gate on liveness, which is what makes the plan row safe to keep.

## Test vs live mode

Resolved without asking, in this order:

1. `go_live: true` **and** live keys validate → live mode. Smoke test uses a real $0.50
   authorization-and-void, never a real subscription charge.
2. `go_live: true` but only test keys → **test mode**, `BLOCKER` logged. Do not ask.
3. `go_live: false` → test mode. Full E2E with the provider's test cards.

Deployment is real in every case; only the money is simulated. Flipping to live must be a
documented env change in `RUNBOOK.md`, with no code change.

Test cards to exercise (Stripe numbers; map to equivalents for other providers):

| Card | Scenario |
|---|---|
| `4242424242424242` | Success |
| `4000000000000341` | Attaches but charge fails → tests `payment.failed` + grace |
| `4000000000000002` | Declined at checkout |
| `4000002500003155` | 3DS required → tests the authentication redirect |

## Lifecycle requirements

- **Grace window:** on `payment.failed`, set `status='past_due'` and `grace_until = now() + 3 days`.
  Access continues; a dunning email goes out. Revoke only after the provider's final
  retry fails. Never cut a paying customer off on a single transient decline.
- **Cancellation:** `cancelAtPeriodEnd`. On `subscription.canceled` set
  `cancel_at = event.effectiveAt` and leave `status='active'`; the reconciler writes
  `status='canceled'` once `cancel_at` passes. Access runs to `current_period_end`. Writing
  the status on receipt is the bug this exists to prevent — it revokes a paid period. No
  retroactive revocation, no prorated clawback, no confirmation dialog that hides the
  cancel button. Self-service and immediate to initiate.
- **Account deletion:** `DELETE /api/account` is the one exception, and the only caller of
  `cancelImmediately`. It cancels now, sets `current_period_end = now()` and
  `status='canceled'`, then deletes or anonymises. Erasure is incompatible with serving a
  paid period, so the money is settled by the refund policy in `RUNBOOK.md`, not by the
  entitlement. Every other cancellation path is `cancelAtPeriodEnd` — two immediate-cancel
  paths means one of them drifts. Matrix row 17 tests it: delete-rows-then-`cancelAtPeriodEnd`
  leaves the provider billing a subscription with no entitlement left to reconcile against.
- **Resubscription:** a returning user reuses their customer record and recovers their data.
- **Upgrades:** prorated by the provider. Entitlement changes on the `subscription.updated`
  webhook, not optimistically in the UI.
- **Refunds:** a documented policy in `RUNBOOK.md` and a handled `refund.issued` event.
- **Tax:** Stripe → enable Stripe Tax. Merchant-of-record providers handle it; say so in
  `HANDOFF.md` so the operator knows which obligation is theirs.
- **Receipts:** provider-generated. Do not hand-roll invoices.

## Required test matrix

Gate `billing` in `playbook/acceptance-gates.md` fails unless all seventeen pass. Row 13 is
a live E2E and is proven by the `stranger-path` gate instead.

| # | Test | Asserts |
|---|---|---|
| 1 | Checkout → `subscription.activated` | Entitlement active, capability granted |
| 2 | Same event delivered twice | One state change; the second returns 200 duplicate |
| 3 | Tampered signature | 400, no write to `billing_events` |
| 4 | Events applied out of order (renewal before activation) | Final state correct |
| 5 | `payment.failed` | `past_due`, grace set, access retained, dunning email queued |
| 6 | Grace expiry | Access revoked exactly once |
| 7 | Cancel | Access retained to period end, revoked after |
| 8 | Resubscribe | Prior data intact, entitlement restored |
| 9 | Add-on purchase | Only the add-on's capabilities appear |
| 10 | Unknown event kind | 200, recorded, no crash |
| 11 | Quota exceeded | Graceful denial, no unbounded cost, counter accurate |
| 12 | Reconciler vs drifted row | Drift corrected and logged |
| 13 | Live E2E on the deployed URL | Signup → subscribe → value → cancel |
| 14 | Apply fails, provider retries | Event re-processed after the lease expires; exactly one final state change |
| 15 | Two deliveries of one event arrive concurrently | One apply; the loser returns 200 |
| 16 | Annual plan subscriber | Same capabilities and quotas as monthly base |
| 17 | `DELETE /api/account` | Subscription cancelled immediately, period ended now, no orphaned entitlement |

Tests 2, 3, 11, 14, 15, and cancel-then-revoke (test 7) are the ones that matter most and the
ones most often skipped: they cover double-grant, forgery, runaway cost, dropped paid events,
and revoking a period the user already paid for — the failures that do real damage with
nobody watching.
