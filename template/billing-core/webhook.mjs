// Webhook ingest. Mirrors playbook/subscription-billing.md.
// Order is load-bearing: verify, then claim, then act. Changing it creates a forgery or
// double-processing hole.

import { GRACE_MS } from './entitlements.mjs';

// Lease length from the documented SQL: claimed_at < now() - interval '5 minutes'.
export const LEASE_MS = 5 * 60 * 1000;

// A sixth failure would get the endpoint disabled, so the reconciler takes over instead.
export const DEAD_LETTER_AT = 5;

/**
 * @typedef {Object} ClaimResult
 * @property {number} attempts
 */

// Atomic claim. Re-claims only an unprocessed event whose lease has expired, so a failed
// apply is retryable while two simultaneous deliveries collapse into one apply.
export async function claimEvent(store, event) {
  return store.claimEvent({
    providerEventId: event.providerEventId,
    kind: event.kind,
    payload: event,
  });
}

/**
 * @param {Object} p
 * @param {Object} p.store      store port (see store-memory.mjs)
 * @param {Object} p.provider   must expose parseWebhook(raw, signature)
 * @param {*} p.raw             raw bytes; a parsed body breaks the HMAC
 * @param {string} p.signature
 * @param {(k: string, d: object) => void} [p.alert]
 * @returns {Promise<{status: number, body: string}>}
 */
export async function handleWebhook({ store, provider, raw, signature, alert = () => {} }) {
  let event;
  try {
    event = await provider.parseWebhook(raw, signature);
  } catch {
    return { status: 400, body: 'bad signature' };   // 400, not 500: do not invite retries
  }

  const claim = await claimEvent(store, event);
  // No row: already processed, or a fresh lease is held elsewhere. The provider's later
  // retry finds the lease expired, so acknowledging here cannot drop the event.
  if (!claim) return { status: 200, body: 'duplicate or in flight' };

  try {
    // One transaction, processed_at included. Committing the apply and then losing the
    // connection before the marker lands leaves a done event re-runnable.
    await store.transaction(async () => {
      await applyEvent(store, event, store.now());
      await store.markProcessed(event.providerEventId, store.now());
    });
  } catch (err) {
    // processed_at stays NULL, so the expired lease lets the next delivery re-claim.
    await store.markError(event.providerEventId, String(err));
    if (claim.attempts >= DEAD_LETTER_AT) {
      alert('billing_event_dead_letter', { providerEventId: event.providerEventId, error: String(err) });
      return { status: 200, body: 'dead-lettered' };
    }
    return { status: 500, body: 'retry' };
  }
  return { status: 200, body: 'ok' };
}

// Monotonic, because events arrive out of order and a stale renewal must not shorten a period.
const laterOf = (a, b) => {
  if (a == null) return b ?? null;
  if (b == null) return a;
  return a > b ? a : b;
};

// 'inactive' is the reconciler's terminal state: the paid period was served and access was
// revoked. Only subscription.activated leaves it, so a late or replayed updated/renewed
// cannot hand paid access back to a revoked subscriber.
const revoked = (e) => e.status === 'inactive';

// A period must never outlive the cancellation the provider confirmed.
const notPast = (date, cap) => (cap != null && date != null && date > cap ? cap : date);

export async function applyEvent(store, event, now) {
  switch (event.kind) {
    case 'subscription.activated': {
      // Checkout wrote the customer link; an unresolvable customer is retryable, not fatal.
      const userId = await store.resolveUserId(event);
      const parked = await store.takeParkedPeriodEnd(event.subscriptionId);
      await store.putEntitlement({
        userId,
        planKey: event.planKey,
        addonKeys: event.addonKeys ?? [],
        status: 'active',
        currentPeriodEnd: laterOf(event.currentPeriodEnd, parked),
        cancelAt: null,
        graceUntil: null,
        provider: event.provider ?? store.providerName,
        customerId: event.customerId,
        subscriptionId: event.subscriptionId,
      });
      return;
    }

    case 'subscription.renewed': {
      const e = await store.findBySubscription(event.subscriptionId);
      // Renewal before activation: park the period end rather than drop it.
      if (!e) {
        await store.parkPeriodEnd(event.subscriptionId, event.currentPeriodEnd);
        return;
      }
      // A renewal rolls a live period forward. It is not a resubscribe.
      if (revoked(e)) return;
      await store.updateEntitlement(e.userId, {
        status: e.status === 'canceled' ? 'canceled' : 'active',
        currentPeriodEnd: notPast(laterOf(e.currentPeriodEnd, event.currentPeriodEnd), e.cancelAt),
        graceUntil: null,
      });
      return;
    }

    case 'subscription.resumed': {
      const e = await mustFind(store, event);
      if (revoked(e)) return;
      await store.updateEntitlement(e.userId, { status: 'active', cancelAt: null });
      return;
    }

    case 'subscription.updated': {
      const e = await mustFind(store, event);
      if (revoked(e)) return;
      // A snapshot event. An absent cancelAt means the provider reports no cancellation,
      // which is how a resume arrives; keeping the old date revokes a paid-through user.
      const cancelAt = event.cancelAt ?? null;
      const live = cancelAt == null || cancelAt > now;
      await store.updateEntitlement(e.userId, {
        planKey: event.planKey,
        addonKeys: event.addonKeys ?? [],
        cancelAt,
        // Live means the cancellation has not landed yet; the reconciler flips it when it does.
        status: live ? 'active' : e.status,
        currentPeriodEnd: notPast(laterOf(e.currentPeriodEnd, event.currentPeriodEnd), cancelAt),
      });
      return;
    }

    case 'subscription.canceled': {
      const e = await mustFind(store, event);
      // Status stays put; the reconciler flips it once cancel_at passes. Writing it here
      // revokes a period the user already paid for.
      await store.updateEntitlement(e.userId, { cancelAt: event.effectiveAt });
      return;
    }

    case 'payment.failed': {
      const e = await mustFind(store, event);
      // Never cut a paying customer off on a single transient decline. Grace is anchored to
      // the event's own timestamp, so a replay recomputes the window instead of sliding it.
      const anchor = event.occurredAt ?? now;
      await store.updateEntitlement(e.userId, {
        status: 'past_due',
        graceUntil: laterOf(e.graceUntil, new Date(anchor.getTime() + GRACE_MS)),
      });
      await store.queueEmail({
        kind: 'dunning',
        providerEventId: event.providerEventId,
        userId: e.userId,
        attemptCount: event.attemptCount,
      });
      return;
    }

    case 'refund.issued': {
      // Entitlement unchanged: money is settled by the refund policy in RUNBOOK.md.
      await store.record('refund.issued', event, event.providerEventId);
      return;
    }

    case 'unknown':
    default:
      // Recorded by the claim and acknowledged. A 500 here makes the provider retry forever.
      return;
  }
}

// `DELETE /api/account` is the only caller, and it must call the provider's
// cancelImmediately in the same transaction. Erasure cannot coexist with a served paid
// period: deleting the rows first leaves the provider billing a subscription with no
// entitlement left for the reconciler to compare against.
export async function cancelImmediately(store, userId, now) {
  await store.updateEntitlement(userId, {
    status: 'canceled',
    currentPeriodEnd: now,
    cancelAt: now,
    graceUntil: null,
  });
}

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

// The ledger's `payload JSONB` hands timestamps back as strings. Compare one to a Date and
// every liveness check silently fails, so a replay revives them before applying.
// Idempotent: live Date objects are not strings and pass through untouched.
export function reviveEvent(payload) {
  if (payload == null || typeof payload !== 'object' || payload instanceof Date) return payload;
  const out = Array.isArray(payload) ? [] : {};
  for (const k of Object.keys(payload)) {
    const v = payload[k];
    out[k] = (typeof v === 'string' && ISO.test(v)) ? new Date(v) : reviveEvent(v);
  }
  return out;
}

async function mustFind(store, event) {
  const e = await store.findBySubscription(event.subscriptionId);
  if (!e) throw new Error(`no entitlement for subscription ${event.subscriptionId}`);
  return e;
}
