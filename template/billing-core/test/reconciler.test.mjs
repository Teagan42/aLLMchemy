// Matrix row 12. The sweep is the safety net for the webhook nobody saw fail, so an
// uncorrected drift and an unlogged correction are both failures.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { can } from '../entitlements.mjs';
import { reconcile } from '../reconciler.mjs';
import { LEASE_MS } from '../webhook.mjs';
import { activated, deliver, paymentFailed, plusDays, setup } from '../fixtures.mjs';

test('matrix 12 — a drifted row is corrected and logged', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));

  // A missed subscription.updated: the provider sold an add-on the app never heard about.
  const truth = {
    planKey: 'base_annual',
    addonKeys: ['addon.sms'],
    status: 'active',
    currentPeriodEnd: plusDays(ctx.store.now(), 365),
  };
  ctx.provider.snapshots.set(ctx.subscriptionId, truth);

  const logged = [];
  const corrections = await reconcile({ store: ctx.store, provider: ctx.provider, log: (c) => logged.push(c) });

  assert.equal(corrections.length, 1);
  assert.deepEqual(logged, corrections, 'every correction must be logged, not just returned');
  assert.equal(corrections[0].kind, 'drift');

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.planKey, 'base_annual');
  assert.deepEqual(e.addonKeys, ['addon.sms']);
  assert.equal(e.currentPeriodEnd.getTime(), truth.currentPeriodEnd.getTime());
  assert.equal(can(e, 'notify:sms', ctx.store.now()), true);

  assert.deepEqual(await reconcile({ store: ctx.store, provider: ctx.provider }), []);
});

test('a provider outage leaves entitlements untouched', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const before = await ctx.store.getEntitlement(ctx.userId);

  // No snapshot registered: getSubscription throws, as it would during an outage.
  assert.deepEqual(await reconcile({ store: ctx.store, provider: ctx.provider }), []);
  assert.deepEqual(await ctx.store.getEntitlement(ctx.userId), before);
});

test('a dead-lettered event is replayed by the sweep, not silently lost', async () => {
  const ctx = setup();
  ctx.store.failNextWrites(5);

  for (let i = 1; i <= 5; i += 1) {
    await deliver(ctx, activated(ctx));
    ctx.store.advance(LEASE_MS + 1000);
  }
  assert.equal(ctx.alerts.length, 1);
  assert.equal(ctx.store.changes.length, 0, 'the paid event never applied');

  const corrections = await reconcile({ store: ctx.store });

  assert.deepEqual(corrections.map((c) => c.kind), ['dead-letter-replay']);
  assert.equal(ctx.store.rawEvent('evt_activated').processedAt instanceof Date, true);
  assert.equal(ctx.store.changes.length, 1);
  assert.equal(can(await ctx.store.getEntitlement(ctx.userId), 'export:csv', ctx.store.now()), true);
});

test('a dead letter that still fails is reported as stuck rather than marked done', async () => {
  const ctx = setup();
  ctx.store.failNextWrites(99);

  for (let i = 1; i <= 5; i += 1) {
    await deliver(ctx, activated(ctx));
    ctx.store.advance(LEASE_MS + 1000);
  }
  const corrections = await reconcile({ store: ctx.store });

  assert.deepEqual(corrections.map((c) => c.kind), ['dead-letter-stuck']);
  assert.equal(ctx.store.rawEvent('evt_activated').processedAt, null);
});

test('the sweep does not compare a row against the provider in the pass that rewrote it', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const e = await ctx.store.getEntitlement(ctx.userId);
  await ctx.store.updateEntitlement(ctx.userId, { cancelAt: e.currentPeriodEnd });
  ctx.store.changes.length = 0;

  ctx.store.setNow(new Date(e.currentPeriodEnd.getTime() + 1000));
  ctx.provider.snapshots.set(ctx.subscriptionId, { status: 'active', planKey: 'base' });

  const corrections = await reconcile({ store: ctx.store, provider: ctx.provider });

  assert.deepEqual(corrections.map((c) => c.kind), ['date-flip']);
  assert.equal(ctx.store.changes.length, 1);
  assert.equal((await ctx.store.getEntitlement(ctx.userId)).status, 'inactive');
});

test('an event stuck below the dead-letter threshold is replayed, not dropped', async () => {
  const ctx = setup();
  ctx.store.failNextWrites(1);

  // One failed apply, then the provider's retry lands inside the lease and reads the 200.
  assert.deepEqual(await deliver(ctx, activated(ctx)), { status: 500, body: 'retry' });
  ctx.store.advance(60 * 1000);
  assert.deepEqual(await deliver(ctx, activated(ctx)), { status: 200, body: 'duplicate or in flight' });
  assert.equal(ctx.store.rawEvent('evt_activated').attempts, 1, 'below DEAD_LETTER_AT');
  assert.equal(ctx.alerts.length, 0, 'nothing alerted: this is the silent drop');

  ctx.store.advance(LEASE_MS + 1000);
  const corrections = await reconcile({ store: ctx.store });

  assert.deepEqual(corrections.map((c) => c.kind), ['event-replay']);
  assert.equal(can(await ctx.store.getEntitlement(ctx.userId), 'export:csv', ctx.store.now()), true);
  assert.deepEqual(await reconcile({ store: ctx.store }), []);
});

test('a replayed payload survives a JSONB round trip with its dates intact', async () => {
  const ctx = setup();
  ctx.store.failNextWrites(5);
  for (let i = 1; i <= 5; i += 1) {
    await deliver(ctx, activated(ctx));
    ctx.store.advance(LEASE_MS + 1000);
  }

  // What `payload JSONB` hands back: every timestamp is a string. The in-memory store keeps
  // the live object, so without this the port instructions are never actually verified.
  const row = ctx.store.rawEvent('evt_activated');
  row.payload = JSON.parse(JSON.stringify(row.payload));

  const corrections = await reconcile({ store: ctx.store });

  assert.deepEqual(corrections.map((c) => c.kind), ['dead-letter-replay']);
  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.ok(e.currentPeriodEnd instanceof Date, 'a string period end makes every date check false');
  assert.equal(can(e, 'export:csv', ctx.store.now()), true,
    'marking a rescued paid event done while access is denied is the silent success');
});

test('the sweep takes the lease, so a concurrent redelivery cannot double-apply', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  ctx.store.failNextWrites(5);
  for (let i = 1; i <= 5; i += 1) {
    await deliver(ctx, paymentFailed(ctx));
    ctx.store.advance(LEASE_MS + 1000);
  }
  ctx.store.outbox.length = 0;

  const [corrections, redelivery] = await Promise.all([
    reconcile({ store: ctx.store }),
    deliver(ctx, paymentFailed(ctx)),
  ]);

  assert.equal(corrections.length + (redelivery.body === 'ok' ? 1 : 0), 1, 'exactly one applied');
  assert.deepEqual(ctx.store.outbox.map((m) => m.kind), ['dunning']);
});
