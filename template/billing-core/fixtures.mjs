// Shared test setup. Lives outside test/ because `node --test` treats every file in a
// directory named test/ as a test file.

import { createMemoryStore, createTestProvider } from './store-memory.mjs';
import { handleWebhook } from './webhook.mjs';

export const DAY_MS = 24 * 60 * 60 * 1000;
export const plusDays = (d, n) => new Date(d.getTime() + n * DAY_MS);

export function setup({ userId = 'u1', customerId = 'cus_1', subscriptionId = 'sub_1', now } = {}) {
  const store = createMemoryStore(now ? { now } : {});
  const provider = createTestProvider();
  store.linkCustomer(customerId, userId);
  return { store, provider, userId, customerId, subscriptionId, alerts: [] };
}

// Raw bytes in, so the signature check runs before any parsing.
export function deliver(ctx, event, signature = 'good') {
  return handleWebhook({
    store: ctx.store,
    provider: ctx.provider,
    raw: Buffer.from(JSON.stringify(event), 'utf8'),
    signature,
    alert: (kind, detail) => ctx.alerts.push({ kind, detail }),
  });
}

export const activated = (ctx, over = {}) => ({
  kind: 'subscription.activated',
  providerEventId: 'evt_activated',
  customerId: ctx.customerId,
  subscriptionId: ctx.subscriptionId,
  planKey: 'base',
  addonKeys: [],
  currentPeriodEnd: plusDays(ctx.store.now(), 30),
  ...over,
});

export const renewed = (ctx, over = {}) => ({
  kind: 'subscription.renewed',
  providerEventId: 'evt_renewed',
  subscriptionId: ctx.subscriptionId,
  currentPeriodEnd: plusDays(ctx.store.now(), 60),
  ...over,
});

export const updated = (ctx, over = {}) => ({
  kind: 'subscription.updated',
  providerEventId: 'evt_updated',
  subscriptionId: ctx.subscriptionId,
  planKey: 'base',
  addonKeys: [],
  currentPeriodEnd: plusDays(ctx.store.now(), 30),
  ...over,
});

export const canceled = (ctx, over = {}) => ({
  kind: 'subscription.canceled',
  providerEventId: 'evt_canceled',
  subscriptionId: ctx.subscriptionId,
  effectiveAt: plusDays(ctx.store.now(), 30),
  ...over,
});

export const paymentFailed = (ctx, over = {}) => ({
  kind: 'payment.failed',
  providerEventId: 'evt_payment_failed',
  subscriptionId: ctx.subscriptionId,
  // Stripe's `created`. Grace is anchored here so a replay recomputes the same window.
  occurredAt: ctx.store.now(),
  attemptCount: 1,
  nextAttemptAt: plusDays(ctx.store.now(), 1),
  ...over,
});
