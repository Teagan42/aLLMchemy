// Capability registry and the sole access check. Mirrors playbook/addon-design.md.
// Plans and add-ons grant capabilities; nothing else does.

/**
 * @typedef {'active'|'past_due'|'canceled'|'inactive'} EntitlementStatus
 *
 * @typedef {Object} Entitlement
 * @property {string} userId
 * @property {string} planKey
 * @property {string[]} addonKeys
 * @property {EntitlementStatus} status
 * @property {Date|null} currentPeriodEnd
 * @property {Date|null} cancelAt      set on cancel; status flips only once it passes
 * @property {Date|null} graceUntil    access survives payment failure until here
 * @property {string|null} provider
 * @property {string|null} customerId
 * @property {string|null} subscriptionId
 */

// Entries are incremental grants; can() always unions free in.
export const CAPABILITIES = {
  free: ['watch:1', 'notify:email', 'history:7d'],
  base: ['watch:10', 'notify:email', 'history:90d', 'export:csv'],

  'addon.sms': ['notify:sms'],
  'addon.unlimited': ['watch:unlimited'],
  'addon.archive': ['history:unlimited', 'export:json'],
};

// Billing-interval variants are the same product. Without an alias every annual
// subscriber hits CAPABILITIES[key] ?? [] and gets nothing.
export const PLAN_ALIASES = { base_annual: 'base' };

export const METRICS = ['watches', 'notifications', 'sms'];

export const QUOTAS = {
  free: { watches: 1, notifications: 30, sms: 0 },
  base: { watches: 10, notifications: 300, sms: 0 },
  'addon.sms': { sms: 150 },              // the cogs_note cap in addon-design.md, in code
  'addon.unlimited': { watches: 1000 },   // a real ceiling; "unlimited" still needs a number
};

// The pricing ladder's keys. assertCatalogInvariants() is run against this at startup.
// `metered` names the add-ons with real marginal cost: each one must cap its own metric,
// or the cogs_note is a promise with no enforcement behind it.
export const CATALOG = {
  plans: ['free', 'base', 'base_annual'],
  addons: ['addon.sms', 'addon.unlimited', 'addon.archive'],
  metered: ['addon.sms'],
};

export const GRACE_MS = 3 * 24 * 60 * 60 * 1000;

// Own-property lookup only. `constructor` and `toString` must not resolve as catalog keys.
const entry = (table, key) =>
  (typeof key === 'string' && Object.prototype.hasOwnProperty.call(table, key)) ? table[key] : undefined;

export const resolvePlan = (k) => entry(PLAN_ALIASES, k) ?? k;

export function emptyEntitlement(userId) {
  return {
    userId,
    planKey: 'free',
    addonKeys: [],
    status: 'inactive',
    currentPeriodEnd: null,
    cancelAt: null,
    graceUntil: null,
    provider: null,
    customerId: null,
    subscriptionId: null,
  };
}

// Liveness comes from dates, never from status alone: a canceled subscription is
// still paid for until current_period_end.
export function isLive(e, now = new Date()) {
  return (e.status === 'active' && (e.currentPeriodEnd == null || e.currentPeriodEnd > now))
    || (e.status === 'past_due' && e.graceUntil != null && e.graceUntil > now)
    || (e.status === 'canceled' && e.currentPeriodEnd != null && e.currentPeriodEnd > now);
}

// Sole access check. One chokepoint means one place to audit and one place to test.
export function can(e, capability, now = new Date()) {
  if (!isLive(e, now)) return CAPABILITIES.free.includes(capability);
  const fromPlan = entry(CAPABILITIES, resolvePlan(e.planKey)) ?? [];
  const fromAddons = (e.addonKeys ?? []).flatMap((k) => entry(CAPABILITIES, k) ?? []);
  // free is the floor, not an alternative.
  return [...CAPABILITIES.free, ...fromPlan, ...fromAddons].includes(capability);
}

// Max-wins per metric over free, then plan, then add-ons. A sparse add-on entry must
// raise one limit without erasing the others — an undefined quota is an unbounded bill.
//
// Liveness-gated like can(): the plan row survives revocation so a dunning recovery can
// restore it, so a dead row must not keep spending at the paid ceiling.
export function quotaFor(e, now = new Date()) {
  const acc = { ...QUOTAS.free };
  if (!isLive(e, now)) return acc;
  const raise = (table) => {
    for (const m of Object.keys(table)) acc[m] = Math.max(acc[m] ?? 0, table[m]);
  };
  raise(entry(QUOTAS, resolvePlan(e.planKey)) ?? {});
  for (const k of e.addonKeys ?? []) raise(entry(QUOTAS, k) ?? {});
  return acc;
}

export const periodKey = (now) =>
  `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;

// An unknown metric denies rather than defaulting open: an unbounded quota is an unbounded bill.
export function checkQuota(e, metric, used, cost = 1, now = new Date()) {
  const limit = quotaFor(e, now)[metric] ?? 0;
  return { metric, used, limit, allowed: used + cost <= limit };
}

// Called before the expensive work. A denial must not increment, or a rejected request
// still inflates the counter.
export async function consumeQuota(store, userId, metric, cost = 1) {
  const now = store.now();
  const period = periodKey(now);
  const e = await store.getEntitlement(userId);
  const used = await store.getUsage(userId, period, metric);
  const verdict = { ...checkQuota(e, metric, used, cost, now), period };
  if (!verdict.allowed) return verdict;
  await store.incrementUsage(userId, period, metric, cost);
  return { ...verdict, used: used + cost };
}

// Both invariants fail silently in production: a missing key returns an empty capability
// list to someone who paid, and a missing quota bills without a ceiling.
export function assertCatalogInvariants(catalog = CATALOG) {
  const problems = [];

  for (const k of catalog.plans) {
    if (!entry(CAPABILITIES, resolvePlan(k))) problems.push(`plan ${k} resolves to no CAPABILITIES entry`);
    if (!entry(QUOTAS, resolvePlan(k))) problems.push(`plan ${k} resolves to no QUOTAS entry`);
  }
  for (const k of catalog.addons) {
    if (!entry(CAPABILITIES, k)) problems.push(`add-on ${k} has no CAPABILITIES entry`);
  }

  // One flat namespace serves plans and add-ons, so a collision silently grants a plan's
  // capabilities and quotas to anyone holding the add-on key.
  for (const k of catalog.addons) {
    if (catalog.plans.includes(k)) problems.push(`${k} is both a plan and an add-on key`);
  }

  // An add-on priced against real marginal cost needs the cap in code, not only in prose.
  for (const k of catalog.metered ?? []) {
    const q = entry(QUOTAS, k);
    if (!q || Object.keys(q).length === 0) {
      problems.push(`metered add-on ${k} has no QUOTAS entry, so its cogs_note cap is unenforced`);
    }
  }

  for (const table of ['free', ...catalog.plans, ...catalog.addons]) {
    const q = entry(QUOTAS, resolvePlan(table)) ?? {};
    for (const m of Object.keys(q)) {
      if (!Number.isFinite(q[m]) || q[m] < 0) problems.push(`QUOTAS.${table}.${m} is not a finite non-negative number`);
    }
  }
  for (const combo of planAddonCombinations(catalog)) {
    const q = quotaFor(combo);
    for (const m of METRICS) {
      if (!Number.isFinite(q[m])) {
        problems.push(`quotaFor(${combo.planKey} + [${combo.addonKeys}]) leaves ${m} unbounded`);
      }
    }
  }

  if (problems.length) throw new Error(`catalog invariants violated:\n  ${problems.join('\n  ')}`);
  return true;
}

// Full power set, so a sparse add-on entry that erases a sibling limit is caught. Degrades
// to singletons past 12 add-ons rather than enumerating 4096+ combinations at startup.
export function planAddonCombinations(catalog = CATALOG) {
  const { plans, addons } = catalog;
  const subsets = addons.length <= 12
    ? powerSet(addons)
    : [[], ...addons.map((a) => [a]), addons.slice()];
  const out = [];
  // Live rows: quotaFor is liveness-gated, so an inactive combination would only ever
  // prove the free ceiling and the sparse-add-on check would pass vacuously.
  for (const planKey of plans) {
    for (const addonKeys of subsets) {
      out.push({ ...emptyEntitlement('invariant'), planKey, addonKeys, status: 'active' });
    }
  }
  return out;
}

function powerSet(items) {
  return items.reduce((acc, item) => acc.concat(acc.map((s) => s.concat([item]))), [[]]);
}
