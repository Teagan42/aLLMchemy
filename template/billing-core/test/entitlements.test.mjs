// Catalog invariants and the access check. Both failures here are silent in production:
// a missing key strips a paying user, a missing quota bills without a ceiling.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  CAPABILITIES, CATALOG, METRICS, PLAN_ALIASES, QUOTAS,
  assertCatalogInvariants, can, checkQuota, emptyEntitlement, isLive,
  planAddonCombinations, quotaFor, resolvePlan,
} from '../entitlements.mjs';

const paying = (over = {}) => ({
  ...emptyEntitlement('u1'),
  planKey: 'base',
  status: 'active',
  currentPeriodEnd: new Date('2026-02-01T00:00:00Z'),
  ...over,
});
const NOW = new Date('2026-01-10T00:00:00Z');

test('the shipped catalog satisfies every startup invariant', () => {
  assert.equal(assertCatalogInvariants(), true);
});

test('every catalog key resolves to a CAPABILITIES entry', () => {
  for (const k of CATALOG.plans) {
    assert.ok(CAPABILITIES[resolvePlan(k)], `plan ${k} resolves to nothing`);
    assert.ok(QUOTAS[resolvePlan(k)], `plan ${k} has no quota row`);
  }
  for (const k of CATALOG.addons) assert.ok(CAPABILITIES[k], `add-on ${k} resolves to nothing`);
});

test('quotaFor is finite for every metric across every plan x add-on combination', () => {
  const combos = planAddonCombinations();
  assert.ok(combos.length >= CATALOG.plans.length * 2 ** CATALOG.addons.length - 1);
  for (const combo of combos) {
    const q = quotaFor(combo);
    for (const m of METRICS) {
      assert.ok(Number.isFinite(q[m]), `${combo.planKey}+[${combo.addonKeys}] leaves ${m} unbounded`);
    }
  }
});

test('a plan key missing from CAPABILITIES fails the invariant instead of stripping the user', () => {
  assert.throws(
    () => assertCatalogInvariants({ plans: ['base', 'pro_annual'], addons: [] }),
    /pro_annual resolves to no CAPABILITIES entry/,
  );
});

test('an add-on with a non-finite quota fails the invariant', () => {
  const saved = QUOTAS['addon.sparse'];
  QUOTAS['addon.sparse'] = { watches: Number.POSITIVE_INFINITY };
  try {
    assert.throws(
      () => assertCatalogInvariants({ plans: ['base'], addons: ['addon.sparse'] }),
      /addon\.sparse/,
    );
  } finally {
    if (saved === undefined) delete QUOTAS['addon.sparse']; else QUOTAS['addon.sparse'] = saved;
  }
});

test('prototype keys do not resolve as plans', () => {
  assert.equal(resolvePlan('constructor'), 'constructor');
  assert.equal(can({ ...paying({ planKey: 'constructor' }) }, 'export:csv', NOW), false);
  assert.ok(Number.isFinite(quotaFor(paying({ planKey: 'toString' }), NOW).watches));
});

test('matrix 16 — an annual subscriber matches monthly base', () => {
  assert.equal(PLAN_ALIASES.base_annual, 'base');
  const monthly = paying({ planKey: 'base' });
  const annual = paying({ planKey: 'base_annual' });
  assert.deepEqual(quotaFor(annual, NOW), quotaFor(monthly, NOW));
  for (const cap of [...CAPABILITIES.free, ...CAPABILITIES.base]) {
    assert.equal(can(annual, cap, NOW), can(monthly, cap, NOW), cap);
  }
  assert.equal(can(annual, 'export:csv', NOW), true);
});

test('can() grants free capabilities to paying users', () => {
  const e = paying();
  for (const cap of CAPABILITIES.free) assert.equal(can(e, cap, NOW), true, cap);
  assert.equal(can(e, 'history:7d', NOW), true);   // not listed on base, still granted
});

test('an add-on grants exactly its own capabilities and nothing else', () => {
  const e = paying({ addonKeys: ['addon.sms'] });
  assert.equal(can(e, 'notify:sms', NOW), true);
  assert.equal(can(e, 'history:unlimited', NOW), false);
  assert.equal(can(e, 'export:json', NOW), false);
  assert.equal(quotaFor(e, NOW).watches, 10);
});

test('an unlimited add-on raises one metric and leaves the rest intact', () => {
  const q = quotaFor(paying({ addonKeys: ['addon.unlimited'] }), NOW);
  assert.equal(q.watches, 1000);
  assert.equal(q.notifications, 300);
});

test('liveness comes from dates, not status alone', () => {
  assert.equal(isLive(paying(), NOW), true);
  assert.equal(isLive(paying({ currentPeriodEnd: new Date('2026-01-01T00:00:00Z') }), NOW), false);
  assert.equal(isLive(paying({ status: 'canceled' }), NOW), true);
  assert.equal(isLive(paying({ status: 'past_due', graceUntil: null }), NOW), false);
  assert.equal(isLive(paying({ status: 'past_due', graceUntil: new Date('2026-01-20T00:00:00Z') }), NOW), true);
  assert.equal(isLive(emptyEntitlement('u1'), NOW), false);
});

test('a lapsed subscriber keeps free capabilities and loses paid ones', () => {
  const e = paying({ status: 'inactive', planKey: 'base' });
  assert.equal(can(e, 'watch:1', NOW), true);
  assert.equal(can(e, 'export:csv', NOW), false);
});

test('checkQuota denies an unknown metric rather than defaulting open', () => {
  assert.deepEqual(checkQuota(paying(), 'inference_tokens', 0), {
    metric: 'inference_tokens', used: 0, limit: 0, allowed: false,
  });
});

test('a key that is both a plan and an add-on fails the invariant', () => {
  // CAPABILITIES and QUOTAS are one flat namespace, so a collision hands a free-plan row
  // the paid plan's capabilities through its addonKeys.
  assert.throws(
    () => assertCatalogInvariants({ plans: ['free', 'base'], addons: ['base'] }),
    /base is both a plan and an add-on key/,
  );
});

test('a metered add-on with no quota row fails the invariant', () => {
  // addon-design.md: a cogs_note cap is enforced in code as a QUOTAS entry or it is a
  // promise with nothing behind it.
  assert.throws(
    () => assertCatalogInvariants({
      plans: ['base'], addons: ['addon.archive'], metered: ['addon.archive'],
    }),
    /metered add-on addon\.archive has no QUOTAS entry/,
  );
  assert.equal(assertCatalogInvariants(), true, 'the shipped catalog caps every metered add-on');
});

test('the SMS add-on caps its own metric rather than borrowing the notification ceiling', () => {
  const q = quotaFor(paying({ addonKeys: ['addon.sms'] }), NOW);
  assert.equal(q.sms, 150, 'the cogs_note cap in addon-design.md');
  assert.equal(quotaFor(paying(), NOW).sms, 0, 'base alone buys no SMS');
});

test('quotaFor is liveness-gated, so a revoked row cannot spend at the paid ceiling', () => {
  const lapsed = paying({ status: 'inactive' });
  assert.equal(can(lapsed, 'export:csv', NOW), false);
  assert.deepEqual(quotaFor(lapsed, NOW), QUOTAS.free);
});
