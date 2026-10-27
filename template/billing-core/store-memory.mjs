// In-memory store port. Reproduces the conflict and lease behaviour of the SQL in
// playbook/subscription-billing.md so the semantics are testable without a database.
// The clock is injected: tests advance it instead of sleeping for five minutes.

import { emptyEntitlement } from './entitlements.mjs';
import { LEASE_MS } from './webhook.mjs';

export function createMemoryStore({ now = new Date('2026-01-01T00:00:00Z'), providerName = 'stripe' } = {}) {
  let clock = new Date(now);
  let failWrites = 0;

  const entitlements = new Map();     // userId -> Entitlement
  const events = new Map();           // providerEventId -> billing_events row
  const usage = new Map();            // `${userId}|${period}|${metric}` -> count
  const customers = new Map();        // customerId -> userId
  const parked = new Map();           // subscriptionId -> Date
  const outbox = [];
  const records = [];
  const changes = [];                 // one entry per entitlement write; counts "state changes"

  const clone = (e) => (e == null ? null : { ...e, addonKeys: [...e.addonKeys] });

  const guardWrite = () => {
    if (failWrites > 0) {
      failWrites -= 1;
      throw new Error('injected write failure');
    }
  };

  const store = {
    providerName,

    // --- clock ------------------------------------------------------------------
    now: () => new Date(clock),
    setNow: (d) => { clock = new Date(d); },
    advance: (ms) => { clock = new Date(clock.getTime() + ms); },

    // --- test hooks -------------------------------------------------------------
    failNextWrites: (n) => { failWrites = n; },
    changes,
    outbox,
    records,
    rawEvent: (id) => events.get(id),
    rawUsage: () => new Map(usage),

    // --- idempotency ledger -----------------------------------------------------
    // Mirrors the INSERT ... ON CONFLICT DO UPDATE ... WHERE: a null return means
    // already processed, or a live lease is held elsewhere.
    async claimEvent({ providerEventId, kind, payload }) {
      const t = store.now();
      const row = events.get(providerEventId);
      if (!row) {
        events.set(providerEventId, {
          providerEventId, kind, payload,
          attempts: 1, claimedAt: t, processedAt: null, error: null, receivedAt: t,
        });
        return { attempts: 1 };
      }
      if (row.processedAt != null) return null;
      if (row.claimedAt != null && t.getTime() - row.claimedAt.getTime() <= LEASE_MS) return null;
      row.attempts += 1;
      row.claimedAt = t;
      row.error = null;
      return { attempts: row.attempts };
    },

    async markProcessed(providerEventId, at) {
      const row = events.get(providerEventId);
      if (row) { row.processedAt = at; row.error = null; }
    },

    async markError(providerEventId, error) {
      const row = events.get(providerEventId);
      if (row) row.error = error;
    },

    async listDeadLetters(minAttempts) {
      return [...events.values()]
        .filter((r) => r.processedAt == null && r.attempts >= minAttempts)
        .map((r) => ({ ...r }));
    },

    // processed_at IS NULL AND claimed_at < now() - lease. Attempt count is irrelevant:
    // an event stuck at one attempt is as unapplied as a dead letter.
    async listUnprocessed(leaseMs) {
      const t = store.now().getTime();
      return [...events.values()]
        .filter((r) => r.processedAt == null && (r.claimedAt == null || t - r.claimedAt.getTime() > leaseMs))
        .map((r) => ({ ...r }));
    },

    // --- entitlements -----------------------------------------------------------
    async getEntitlement(userId) {
      return clone(entitlements.get(userId)) ?? emptyEntitlement(userId);
    },

    async findBySubscription(subscriptionId) {
      for (const e of entitlements.values()) {
        if (e.subscriptionId === subscriptionId) return clone(e);
      }
      return null;
    },

    async listEntitlements() {
      return [...entitlements.values()].map(clone);
    },

    async putEntitlement(e) {
      guardWrite();
      entitlements.set(e.userId, { ...emptyEntitlement(e.userId), ...e, addonKeys: [...(e.addonKeys ?? [])] });
      changes.push({ userId: e.userId, at: store.now(), patch: { ...e } });
    },

    async updateEntitlement(userId, patch) {
      guardWrite();
      const current = entitlements.get(userId) ?? emptyEntitlement(userId);
      entitlements.set(userId, { ...current, ...patch, addonKeys: [...(patch.addonKeys ?? current.addonKeys)] });
      changes.push({ userId, at: store.now(), patch: { ...patch } });
    },

    // Checkout writes this link. applyEvent throws without it, which is retryable.
    linkCustomer(customerId, userId) { customers.set(customerId, userId); },

    async resolveUserId({ customerId, subscriptionId }) {
      const byCustomer = customers.get(customerId);
      if (byCustomer) return byCustomer;
      const existing = await store.findBySubscription(subscriptionId);
      if (existing) return existing.userId;
      throw new Error(`no user linked to customer ${customerId}`);
    },

    async parkPeriodEnd(subscriptionId, at) { parked.set(subscriptionId, at); },

    async takeParkedPeriodEnd(subscriptionId) {
      const at = parked.get(subscriptionId) ?? null;
      parked.delete(subscriptionId);
      return at;
    },

    // --- usage counters ---------------------------------------------------------
    async getUsage(userId, period, metric) {
      return usage.get(`${userId}|${period}|${metric}`) ?? 0;
    },

    async incrementUsage(userId, period, metric, by = 1) {
      const k = `${userId}|${period}|${metric}`;
      usage.set(k, (usage.get(k) ?? 0) + by);
    },

    // --- side effects -----------------------------------------------------------
    // Both are deduplicated on (kind, providerEventId), which the real schema must carry as
    // a unique index: applyEvent can run twice for one event and must not emit twice.
    async queueEmail(msg) {
      const k = `${msg.kind}|${msg.providerEventId ?? ''}`;
      if (msg.providerEventId != null && outbox.some((m) => `${m.kind}|${m.providerEventId}` === k)) return;
      outbox.push({ ...msg, at: store.now() });
    },

    async record(kind, payload, providerEventId = null) {
      if (providerEventId != null
          && records.some((r) => r.kind === kind && r.providerEventId === providerEventId)) return;
      records.push({ kind, payload, providerEventId, at: store.now() });
    },

    // --- transaction ------------------------------------------------------------
    // Snapshot and restore. A half-applied billing event is worse than none, so the
    // tests must be able to prove rollback rather than assume it.
    async transaction(fn) {
      const snapshot = {
        entitlements: new Map([...entitlements].map(([k, v]) => [k, clone(v)])),
        // processed_at is written inside the apply transaction, so a rollback must unwind it.
        events: new Map([...events].map(([k, v]) => [k, { ...v }])),
        usage: new Map(usage),
        parked: new Map(parked),
        changes: changes.length,
        outbox: outbox.length,
        records: records.length,
      };
      try {
        return await fn();
      } catch (err) {
        entitlements.clear();
        for (const [k, v] of snapshot.entitlements) entitlements.set(k, v);
        events.clear();
        for (const [k, v] of snapshot.events) events.set(k, v);
        usage.clear();
        for (const [k, v] of snapshot.usage) usage.set(k, v);
        parked.clear();
        for (const [k, v] of snapshot.parked) parked.set(k, v);
        changes.length = snapshot.changes;
        outbox.length = snapshot.outbox;
        records.length = snapshot.records;
        throw err;
      }
    },
  };

  return store;
}

// Signature-verifying stub. Rejects anything but the expected signature so the forgery
// test exercises the real ordering: verify before claim.
export function createTestProvider({ signature = 'good', snapshots = new Map() } = {}) {
  return {
    snapshots,
    async parseWebhook(raw, sig) {
      if (sig !== signature) throw new Error('signature mismatch');
      return JSON.parse(typeof raw === 'string' ? raw : raw.toString('utf8'), reviveDates);
    },
    async getSubscription(id) {
      const snap = snapshots.get(id);
      if (!snap) throw new Error(`no such subscription ${id}`);
      return { ...snap };
    },
  };
}

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
const reviveDates = (_k, v) => (typeof v === 'string' && ISO.test(v) ? new Date(v) : v);
