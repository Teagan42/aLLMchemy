// Matrix row 11. An unenforced quota is not a cost control, and a denial that still
// increments makes the counter lie about what was served.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { consumeQuota, periodKey, quotaFor } from '../entitlements.mjs';
import { activated, deliver, setup, updated } from '../fixtures.mjs';

const exhaust = async (ctx, metric, limit) => {
  for (let i = 0; i < limit; i += 1) {
    const r = await consumeQuota(ctx.store, ctx.userId, metric);
    assert.equal(r.allowed, true, `call ${i + 1} of ${limit}`);
  }
};

test('matrix 11 — quota exceeded denies gracefully and leaves the counter accurate', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const limit = quotaFor(await ctx.store.getEntitlement(ctx.userId), ctx.store.now()).notifications;

  await exhaust(ctx, 'notifications', limit);

  const denied = await consumeQuota(ctx.store, ctx.userId, 'notifications');
  assert.deepEqual(denied, {
    metric: 'notifications', used: limit, limit, allowed: false, period: '2026-01',
  });

  // A denial that increments turns one rejected request into an inflated bill.
  assert.equal(await ctx.store.getUsage(ctx.userId, '2026-01', 'notifications'), limit);
});

test('a free user is capped far below a paying one', async () => {
  const ctx = setup();
  assert.equal(quotaFor(await ctx.store.getEntitlement(ctx.userId), ctx.store.now()).notifications, 30);

  await exhaust(ctx, 'notifications', 30);
  assert.equal((await consumeQuota(ctx.store, ctx.userId, 'notifications')).allowed, false);
});

test('an add-on raises the ceiling for the metric it buys and no other', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  await deliver(ctx, updated(ctx, { addonKeys: ['addon.unlimited'] }));

  const q = quotaFor(await ctx.store.getEntitlement(ctx.userId), ctx.store.now());
  assert.equal(q.watches, 1000);
  assert.equal(q.notifications, 300);
});

test('a cost greater than the remaining allowance is denied whole, not partially served', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  await exhaust(ctx, 'watches', 9);

  const denied = await consumeQuota(ctx.store, ctx.userId, 'watches', 5);
  assert.equal(denied.allowed, false);
  assert.equal(await ctx.store.getUsage(ctx.userId, '2026-01', 'watches'), 9);
});

test('counters are per calendar month, so a new period starts clean', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  await exhaust(ctx, 'notifications', 300);
  assert.equal((await consumeQuota(ctx.store, ctx.userId, 'notifications')).allowed, false);

  ctx.store.setNow(new Date('2026-02-01T00:00:00Z'));
  assert.equal(periodKey(ctx.store.now()), '2026-02');
  assert.equal((await consumeQuota(ctx.store, ctx.userId, 'notifications')).allowed, true);
  assert.equal(await ctx.store.getUsage(ctx.userId, '2026-01', 'notifications'), 300);
});
