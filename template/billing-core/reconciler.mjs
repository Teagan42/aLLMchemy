// Daily sweep. Webhooks get lost, so this is the safety net that catches the bug nobody
// is awake to notice. It is a required gate, not an optimisation.
//
// Owns the two writes the webhook path deliberately does not make: flipping status once
// cancel_at passes, and re-applying events left with processed_at IS NULL.

import { applyEvent, reviveEvent, DEAD_LETTER_AT, LEASE_MS } from './webhook.mjs';

const DRIFT_FIELDS = ['planKey', 'status', 'currentPeriodEnd'];

/**
 * @param {Object} p
 * @param {Object} p.store
 * @param {Object} [p.provider]  omit to skip drift repair (no provider to compare against)
 * @param {(c: object) => void} [p.log]
 * @param {(k: string, d: object) => void} [p.alert]
 * @returns {Promise<object[]>} one correction per write made; empty on a clean second run
 */
export async function reconcile({ store, provider = null, log = () => {}, alert = () => {} }) {
  const now = store.now();
  const corrections = [];
  const note = (c) => { corrections.push(c); log(c); };

  for (const e of await store.listEntitlements()) {
    const patch = {};

    // The cancel the webhook handler deliberately left pending. 'inactive' is terminal, so
    // excluding it is what keeps the sweep idempotent instead of flipping the row back.
    if (e.cancelAt != null && e.cancelAt <= now
        && e.status !== 'canceled' && e.status !== 'inactive') {
      patch.status = 'canceled';
    }

    const status = patch.status ?? e.status;

    // Paid period served. Revoked exactly once: 'inactive' never re-enters either branch.
    //
    // Status only. Wiping planKey loses what the customer bought, and a dunning recovery
    // then restores them on the free plan — can() and quotaFor() already gate on liveness.
    if (status === 'canceled' && e.currentPeriodEnd != null && e.currentPeriodEnd <= now) {
      patch.status = 'inactive';
    }

    // Grace expired after the provider's final retry failed.
    if (status === 'past_due' && e.graceUntil != null && e.graceUntil <= now) {
      Object.assign(patch, { status: 'inactive', graceUntil: null });
    }

    if (Object.keys(patch).length > 0) {
      await store.updateEntitlement(e.userId, patch);
      note({ kind: 'date-flip', userId: e.userId, from: pick(e, Object.keys(patch)), to: patch });
      continue;   // Do not compare a row against the provider in the same pass that rewrote it.
    }

    if (provider && e.subscriptionId) {
      const drift = await driftFor(provider, e);
      if (drift) {
        await store.updateEntitlement(e.userId, drift);
        note({ kind: 'drift', userId: e.userId, from: pick(e, Object.keys(drift)), to: drift });
      }
    }
  }

  // Every unfinished event is the sweep's problem, not only the ones that reached five
  // attempts. A provider that read a 200 for an in-flight retry stops retrying, so a row
  // stuck at one attempt is dropped forever if only dead letters are replayed.
  const dead = new Set((await store.listDeadLetters(DEAD_LETTER_AT)).map((r) => r.providerEventId));

  for (const row of await store.listUnprocessed(LEASE_MS)) {
    // Take the same lease a delivery would. Without it the sweep and a late redelivery
    // both apply, which doubles a dunning email and a refund record.
    const claim = await store.claimEvent({
      providerEventId: row.providerEventId, kind: row.kind, payload: row.payload,
    });
    if (!claim) continue;

    const isDead = dead.has(row.providerEventId);
    if (isDead) alert('billing_event_dead_letter_replay', { providerEventId: row.providerEventId, attempts: claim.attempts });

    try {
      const event = reviveEvent(row.payload);
      await store.transaction(async () => {
        await applyEvent(store, event, store.now());
        await store.markProcessed(row.providerEventId, store.now());
      });
      note({
        kind: isDead ? 'dead-letter-replay' : 'event-replay',
        providerEventId: row.providerEventId,
        attempts: claim.attempts,
      });
    } catch (err) {
      await store.markError(row.providerEventId, String(err));
      note({
        kind: isDead ? 'dead-letter-stuck' : 'event-stuck',
        providerEventId: row.providerEventId,
        error: String(err),
      });
    }
  }

  return corrections;
}

// The provider is the source of truth for what was actually billed.
async function driftFor(provider, e) {
  let snapshot;
  try {
    snapshot = await provider.getSubscription(e.subscriptionId);
  } catch {
    return null;   // Provider outage must not rewrite entitlements.
  }
  const drift = {};
  for (const f of DRIFT_FIELDS) {
    if (snapshot[f] === undefined) continue;
    if (!same(e[f], snapshot[f])) drift[f] = snapshot[f];
  }
  if (snapshot.addonKeys !== undefined
      && [...e.addonKeys].sort().join(',') !== [...snapshot.addonKeys].sort().join(',')) {
    drift.addonKeys = [...snapshot.addonKeys];
  }
  return Object.keys(drift).length > 0 ? drift : null;
}

const same = (a, b) =>
  (a instanceof Date && b instanceof Date) ? a.getTime() === b.getTime() : a === b;

const pick = (obj, keys) => keys.reduce((acc, k) => (Object.assign(acc, { [k]: obj[k] })), {});
