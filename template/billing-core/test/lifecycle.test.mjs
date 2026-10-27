// Matrix rows 5, 6, 7, 8, 9. Row 7 is the one that revokes a period the user already
// paid for when it is written on receipt instead of by the reconciler.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { GRACE_MS, can, isLive, quotaFor } from '../entitlements.mjs';
import { reconcile } from '../reconciler.mjs';
import { applyEvent, cancelImmediately } from '../webhook.mjs';
import { DAY_MS, activated, canceled, deliver, paymentFailed, plusDays, renewed, setup, updated } from '../fixtures.mjs';

test('matrix 5 — payment.failed keeps access, sets grace, queues dunning', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const at = ctx.store.now();

  assert.deepEqual(await deliver(ctx, paymentFailed(ctx)), { status: 200, body: 'ok' });

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.status, 'past_due');
  assert.equal(e.graceUntil.getTime(), at.getTime() + GRACE_MS);
  assert.equal(can(e, 'export:csv', ctx.store.now()), true, 'a transient decline must not cut access');
  assert.deepEqual(ctx.store.outbox.map((m) => m.kind), ['dunning']);
});

test('matrix 6 — grace expiry revokes access exactly once', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  await deliver(ctx, paymentFailed(ctx));

  ctx.store.advance(GRACE_MS + 1000);
  assert.equal(isLive(await ctx.store.getEntitlement(ctx.userId), ctx.store.now()), false);

  const first = await reconcile({ store: ctx.store });
  const second = await reconcile({ store: ctx.store });

  assert.equal(first.length, 1);
  assert.equal(second.length, 0, 'the sweep must be idempotent');
  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.status, 'inactive');
  // The plan row survives revocation. Wiping it to 'free' loses what the customer bought,
  // and the dunning recovery below then restores them on the wrong plan.
  assert.equal(e.planKey, 'base');
  assert.equal(can(e, 'export:csv', ctx.store.now()), false);
  assert.equal(can(e, 'watch:1', ctx.store.now()), true);
  assert.deepEqual(quotaFor(e, ctx.store.now()), { watches: 1, notifications: 30, sms: 0 });
});

test('a card that succeeds after grace expiry comes back on the plan it paid for', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  await deliver(ctx, paymentFailed(ctx));
  ctx.store.advance(GRACE_MS + 1000);
  await reconcile({ store: ctx.store });
  assert.equal((await ctx.store.getEntitlement(ctx.userId)).status, 'inactive');

  // Stripe retries a failed invoice for far longer than the grace window, so this is the
  // ordinary dunning-recovery path. A renewal is a period roll, not a resubscribe: the
  // provider sends subscription.activated for that, and only that restores access.
  await deliver(ctx, renewed(ctx));
  const stillRevoked = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(stillRevoked.status, 'inactive');
  assert.equal(stillRevoked.planKey, 'base');

  await deliver(ctx, activated(ctx, { providerEventId: 'evt_dunning_recovered' }));
  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.status, 'active');
  assert.equal(e.planKey, 'base', 'a recovered subscriber must not land on the free plan');
  assert.equal(can(e, 'export:csv', ctx.store.now()), true);
  assert.equal(quotaFor(e, ctx.store.now()).notifications, 300);
});

test('a resume clears the pending cancel instead of leaving it to revoke a paid period', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const periodEnd = (await ctx.store.getEntitlement(ctx.userId)).currentPeriodEnd;
  await deliver(ctx, canceled(ctx, { effectiveAt: periodEnd }));

  // The user resumes before the period ends; the provider sends a fresh snapshot.
  await deliver(ctx, updated(ctx, {
    providerEventId: 'evt_resumed', currentPeriodEnd: plusDays(periodEnd, 30),
  }));

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.cancelAt, null, 'a stale cancel_at revokes a resumed subscriber');
  assert.equal(e.status, 'active');

  ctx.store.setNow(new Date(periodEnd.getTime() + DAY_MS));
  assert.deepEqual(await reconcile({ store: ctx.store }), [], 'nothing to correct: the user resumed');
  assert.equal(can(await ctx.store.getEntitlement(ctx.userId), 'export:csv', ctx.store.now()), true);
});

test('a late updated or renewed cannot resurrect a revoked subscriber', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const periodEnd = (await ctx.store.getEntitlement(ctx.userId)).currentPeriodEnd;
  await deliver(ctx, canceled(ctx, { effectiveAt: periodEnd }));
  ctx.store.setNow(new Date(periodEnd.getTime() + 1000));
  await reconcile({ store: ctx.store });
  assert.equal((await ctx.store.getEntitlement(ctx.userId)).status, 'inactive');

  for (const late of [
    updated(ctx, { providerEventId: 'evt_late_updated', currentPeriodEnd: plusDays(periodEnd, 30) }),
    renewed(ctx, { providerEventId: 'evt_late_renewed', currentPeriodEnd: plusDays(periodEnd, 30) }),
  ]) {
    await deliver(ctx, late);
    const e = await ctx.store.getEntitlement(ctx.userId);
    assert.equal(isLive(e, ctx.store.now()), false, `${late.kind} handed paid access back`);
    assert.equal(can(e, 'export:csv', ctx.store.now()), false);
  }
});

test('matrix 7 — the cancel sweep writes once and settles', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const periodEnd = (await ctx.store.getEntitlement(ctx.userId)).currentPeriodEnd;
  await deliver(ctx, canceled(ctx, { effectiveAt: periodEnd }));
  ctx.store.setNow(new Date(periodEnd.getTime() + 1000));
  ctx.store.changes.length = 0;

  assert.equal((await reconcile({ store: ctx.store })).length, 1);
  for (let i = 0; i < 3; i += 1) {
    assert.deepEqual(await reconcile({ store: ctx.store }), [], `sweep ${i + 2} must be a no-op`);
  }
  assert.equal(ctx.store.changes.length, 1, 'one revocation, one write');
  assert.equal((await ctx.store.getEntitlement(ctx.userId)).status, 'inactive');
});

test('payment.failed applied twice sends one dunning email and one grace window', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const event = paymentFailed(ctx);

  await applyEvent(ctx.store, event, ctx.store.now());
  const first = (await ctx.store.getEntitlement(ctx.userId)).graceUntil;
  ctx.store.advance(DAY_MS);
  await applyEvent(ctx.store, event, ctx.store.now());

  assert.equal((await ctx.store.getEntitlement(ctx.userId)).graceUntil.getTime(), first.getTime(),
    'a re-apply must not slide the grace window');
  assert.deepEqual(ctx.store.outbox.map((m) => m.kind), ['dunning']);
});

test('refund.issued applied twice records one row', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const event = { kind: 'refund.issued', providerEventId: 'evt_refund', subscriptionId: ctx.subscriptionId, amountCents: 500 };

  await applyEvent(ctx.store, event, ctx.store.now());
  await applyEvent(ctx.store, event, ctx.store.now());

  assert.deepEqual(ctx.store.records.map((r) => r.kind), ['refund.issued']);
});

test('matrix 7 — cancel keeps access to period end, then revokes', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const periodEnd = (await ctx.store.getEntitlement(ctx.userId)).currentPeriodEnd;

  assert.deepEqual(await deliver(ctx, canceled(ctx, { effectiveAt: periodEnd })), { status: 200, body: 'ok' });

  // Receipt must not write the status, or the paid period is revoked immediately.
  const pending = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(pending.status, 'active');
  assert.equal(pending.cancelAt.getTime(), periodEnd.getTime());
  assert.equal(can(pending, 'export:csv', ctx.store.now()), true);

  ctx.store.setNow(new Date(periodEnd.getTime() - DAY_MS));
  assert.equal(can(await ctx.store.getEntitlement(ctx.userId), 'export:csv', ctx.store.now()), true);

  ctx.store.setNow(new Date(periodEnd.getTime() + 1000));
  assert.equal(can(await ctx.store.getEntitlement(ctx.userId), 'export:csv', ctx.store.now()), false,
    'the date revokes access before the sweep runs');

  const corrections = await reconcile({ store: ctx.store });
  assert.equal(corrections.length, 1);
  assert.deepEqual(await reconcile({ store: ctx.store }), [], 'the sweep must be idempotent');
  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.status, 'inactive');
  assert.equal(can(e, 'watch:1', ctx.store.now()), true);
});

test('matrix 8 — resubscribe restores the entitlement and leaves prior data intact', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  await ctx.store.incrementUsage(ctx.userId, '2026-01', 'watches', 7);

  const periodEnd = (await ctx.store.getEntitlement(ctx.userId)).currentPeriodEnd;
  await deliver(ctx, canceled(ctx, { effectiveAt: periodEnd }));
  ctx.store.setNow(new Date(periodEnd.getTime() + 1000));
  await reconcile({ store: ctx.store });
  assert.equal((await ctx.store.getEntitlement(ctx.userId)).status, 'inactive');

  await deliver(ctx, activated(ctx, { providerEventId: 'evt_activated_again' }));

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.status, 'active');
  assert.equal(e.planKey, 'base');
  assert.equal(e.cancelAt, null, 'a stale cancel_at would revoke the new period');
  assert.equal(e.customerId, ctx.customerId);
  assert.equal(await ctx.store.getUsage(ctx.userId, '2026-01', 'watches'), 7);
});

test('matrix 9 — an add-on purchase grants only its own capabilities', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  await deliver(ctx, updated(ctx, { addonKeys: ['addon.sms'] }));

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.deepEqual(e.addonKeys, ['addon.sms']);
  assert.equal(can(e, 'notify:sms', ctx.store.now()), true);
  assert.equal(can(e, 'export:json', ctx.store.now()), false);
  assert.equal(can(e, 'history:unlimited', ctx.store.now()), false);
});

test('add-on removal comes from the webhook, not optimistically', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx, { addonKeys: ['addon.sms'] }));
  await deliver(ctx, updated(ctx, { addonKeys: [] }));

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.deepEqual(e.addonKeys, []);
  assert.equal(can(e, 'notify:sms', ctx.store.now()), false);
});

test('an upgrade to the annual plan keeps base capabilities and extends the period', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const annualEnd = plusDays(ctx.store.now(), 365);
  await deliver(ctx, updated(ctx, { planKey: 'base_annual', currentPeriodEnd: annualEnd }));

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.planKey, 'base_annual');
  assert.equal(e.currentPeriodEnd.getTime(), annualEnd.getTime());
  assert.equal(can(e, 'export:csv', ctx.store.now()), true);
});

test('refund.issued is recorded without touching the entitlement', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const before = await ctx.store.getEntitlement(ctx.userId);

  const res = await deliver(ctx, {
    kind: 'refund.issued', providerEventId: 'evt_refund',
    subscriptionId: ctx.subscriptionId, amountCents: 500,
  });

  assert.deepEqual(res, { status: 200, body: 'ok' });
  assert.deepEqual(ctx.store.records.map((r) => r.kind), ['refund.issued']);
  assert.deepEqual(await ctx.store.getEntitlement(ctx.userId), before);
});

test('matrix 17 — account deletion cancels immediately and leaves no orphaned entitlement', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const now = ctx.store.now();

  await cancelImmediately(ctx.store, ctx.userId, now);

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.status, 'canceled');
  assert.equal(e.currentPeriodEnd.getTime(), now.getTime());
  assert.equal(isLive(e, now), false, 'erasure cannot coexist with a served paid period');
  assert.equal(can(e, 'export:csv', now), false);

  // The sweep settles the row rather than leaving a canceled subscription drifting.
  ctx.store.advance(1000);
  assert.equal((await reconcile({ store: ctx.store })).length, 1);
  assert.equal((await ctx.store.getEntitlement(ctx.userId)).status, 'inactive');
  assert.deepEqual(await reconcile({ store: ctx.store }), []);
});
