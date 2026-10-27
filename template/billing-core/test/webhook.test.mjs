// Ingest semantics: matrix rows 1, 2, 3, 4, 10, 14, 15 from
// playbook/subscription-billing.md. These are the rows that cover double-grant, forgery
// and dropped paid events.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { can, isLive } from '../entitlements.mjs';
import { LEASE_MS } from '../webhook.mjs';
import { activated, deliver, renewed, setup } from '../fixtures.mjs';

test('matrix 1 — checkout activates the entitlement and grants the capability', async () => {
  const ctx = setup();
  const res = await deliver(ctx, activated(ctx));
  assert.deepEqual(res, { status: 200, body: 'ok' });

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.status, 'active');
  assert.equal(e.planKey, 'base');
  assert.equal(e.subscriptionId, ctx.subscriptionId);
  assert.equal(can(e, 'export:csv', ctx.store.now()), true);
  assert.equal(ctx.store.rawEvent('evt_activated').processedAt instanceof Date, true);
});

test('matrix 2 — the same event delivered twice makes one state change', async () => {
  const ctx = setup();
  const first = await deliver(ctx, activated(ctx));
  const second = await deliver(ctx, activated(ctx));

  assert.deepEqual(first, { status: 200, body: 'ok' });
  assert.deepEqual(second, { status: 200, body: 'duplicate or in flight' });
  assert.equal(ctx.store.changes.length, 1);
  assert.equal(ctx.store.rawEvent('evt_activated').attempts, 1);
});

test('matrix 3 — a tampered signature is a 400 and writes no ledger row', async () => {
  const ctx = setup();
  const res = await deliver(ctx, activated(ctx), 'forged');

  assert.deepEqual(res, { status: 400, body: 'bad signature' });
  assert.equal(ctx.store.rawEvent('evt_activated'), undefined);
  assert.equal(ctx.store.changes.length, 0);
});

test('matrix 4 — renewal before activation still leaves the final state correct', async () => {
  const ctx = setup();
  const later = renewed(ctx);                                     // period end +60d
  const earlier = activated(ctx);                                 // period end +30d

  assert.deepEqual(await deliver(ctx, later), { status: 200, body: 'ok' });
  assert.deepEqual(await deliver(ctx, earlier), { status: 200, body: 'ok' });

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.status, 'active');
  assert.equal(e.currentPeriodEnd.getTime(), later.currentPeriodEnd.getTime());
});

test('a stale renewal never shortens a period already paid for', async () => {
  const ctx = setup();
  await deliver(ctx, activated(ctx));
  const stale = renewed(ctx, { currentPeriodEnd: new Date('2026-01-05T00:00:00Z') });
  await deliver(ctx, stale);

  const e = await ctx.store.getEntitlement(ctx.userId);
  assert.equal(e.currentPeriodEnd.getTime(), activated(ctx).currentPeriodEnd.getTime());
});

test('matrix 10 — an unknown event kind is a 200, recorded, no crash', async () => {
  const ctx = setup();
  const res = await deliver(ctx, { kind: 'unknown', providerEventId: 'evt_mystery' });

  assert.deepEqual(res, { status: 200, body: 'ok' });
  assert.equal(ctx.store.rawEvent('evt_mystery').kind, 'unknown');
  assert.equal(ctx.store.changes.length, 0);
});

test('an unmapped future event kind is acknowledged rather than retried forever', async () => {
  const ctx = setup();
  const res = await deliver(ctx, { kind: 'invoice.voided', providerEventId: 'evt_future' });
  assert.deepEqual(res, { status: 200, body: 'ok' });
});

test('matrix 14 — a failed apply is re-processed after the lease expires, once', async () => {
  const ctx = setup();
  ctx.store.failNextWrites(1);

  assert.deepEqual(await deliver(ctx, activated(ctx)), { status: 500, body: 'retry' });
  assert.equal(ctx.store.changes.length, 0, 'the transaction must roll back');
  assert.equal(ctx.store.rawEvent('evt_activated').processedAt, null);
  assert.match(ctx.store.rawEvent('evt_activated').error, /injected write failure/);

  // Inside the lease the provider's retry is a no-op, so nothing double-applies.
  assert.deepEqual(await deliver(ctx, activated(ctx)), { status: 200, body: 'duplicate or in flight' });

  ctx.store.advance(LEASE_MS + 1000);
  assert.deepEqual(await deliver(ctx, activated(ctx)), { status: 200, body: 'ok' });

  assert.equal(ctx.store.changes.length, 1, 'exactly one final state change');
  assert.equal(ctx.store.rawEvent('evt_activated').attempts, 2);
  assert.equal(isLive(await ctx.store.getEntitlement(ctx.userId), ctx.store.now()), true);
});

test('matrix 15 — two concurrent deliveries of one event produce one apply', async () => {
  const ctx = setup();
  const results = await Promise.all([deliver(ctx, activated(ctx)), deliver(ctx, activated(ctx))]);
  const bodies = results.map((r) => r.body).sort();

  assert.deepEqual(bodies, ['duplicate or in flight', 'ok']);
  assert.deepEqual(results.map((r) => r.status), [200, 200]);
  assert.equal(ctx.store.changes.length, 1);
});

test('the fifth failure dead-letters with a 200 and an alert instead of a sixth 500', async () => {
  const ctx = setup();
  ctx.store.failNextWrites(99);

  for (let i = 1; i <= 4; i += 1) {
    assert.deepEqual(await deliver(ctx, activated(ctx)), { status: 500, body: 'retry' }, `attempt ${i}`);
    ctx.store.advance(LEASE_MS + 1000);
  }
  assert.deepEqual(await deliver(ctx, activated(ctx)), { status: 200, body: 'dead-lettered' });

  assert.equal(ctx.store.rawEvent('evt_activated').attempts, 5);
  assert.equal(ctx.alerts.length, 1);
  assert.equal(ctx.alerts[0].kind, 'billing_event_dead_letter');
});

test('an unresolvable customer is retryable, not a silent success', async () => {
  // The checkout row that links customer to user never landed.
  const ctx = setup();
  const res = await deliver(ctx, activated(ctx, { customerId: 'cus_never_seen' }));

  assert.deepEqual(res, { status: 500, body: 'retry' });
  assert.equal(ctx.store.rawEvent('evt_activated').processedAt, null);
  assert.equal(ctx.store.changes.length, 0);
});
