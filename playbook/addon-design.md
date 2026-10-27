# Add-on Design

The stretch goal is an optional second service or relevant add-on. The thing that makes it
cheap or expensive is a decision made in Phase 3, before any add-on exists: if access
checks are scattered `if (user.isPaid)` branches, every add-on is a refactor; if access
runs through one capability registry, an add-on is a row in a table.

So build the entitlements machinery **even when `addons_enabled` is false.** It costs almost
nothing up front and it is the difference between a later add-on taking an hour and taking a
rewrite. Only the catalog entries are conditional.

## Capability registry

One file. Plans and add-ons both grant capabilities; nothing else does.

```ts
// Sole source of what each plan and add-on unlocks. New add-on = new entry, no new branches.
// Entries are incremental grants; can() always unions free in, so never repeat free here.
export const CAPABILITIES = {
  free:         ['watch:1',  'notify:email', 'history:7d'],
  base:         ['watch:10', 'notify:email', 'history:90d', 'export:csv'],

  'addon.sms':      ['notify:sms'],
  'addon.unlimited':['watch:unlimited'],
  'addon.archive':  ['history:unlimited', 'export:json'],
} as const satisfies Record<string, readonly Capability[]>;

// Billing-interval variants are the same product. Without an alias, every annual
// subscriber hits CAPABILITIES[key] ?? [] and gets nothing.
export const PLAN_ALIASES = { base_annual: 'base' } as const;

// Own-property lookup only. A drifted catalog or a provider payload with planKey
// 'constructor' otherwise resolves to Object's constructor and throws inside can().
const entry = <T>(table: Record<string, T>, key: string): T | undefined =>
  Object.prototype.hasOwnProperty.call(table, key) ? table[key] : undefined;

export const resolvePlan = (k: string): string => entry(PLAN_ALIASES, k) ?? k;   // used by can() too

// Every quota key lives here, including one per metered add-on: a cogs_note cap with no
// metric to count against is unenforceable.
export const METRICS = ['watches', 'notifications', 'sms'] as const;

export const QUOTAS = {
  free: { watches: 1,  notifications: 30, sms: 0 },
  base: { watches: 10, notifications: 300, sms: 0 },
  'addon.sms':       { sms: 150 },        // the cogs_note cap below, in code
  'addon.unlimited': { watches: 1000 },   // a real ceiling; "unlimited" must still have a number
} as const;

// Max-wins per metric over free, then plan, then add-ons. A sparse add-on entry must raise
// one limit without erasing the others — an undefined quota is an unbounded bill. Spreading
// the plan row over the free row instead would let a plan *lower* a free limit.
//
// Liveness-gated like can(): the plan row survives revocation so a dunning recovery can
// restore it, so a dead row must not keep spending at the paid ceiling.
export function quotaFor(e: Entitlement, now = new Date()): Record<string, number> {
  const acc: Record<string, number> = { ...QUOTAS.free };
  if (!isLive(e, now)) return acc;
  const raise = (table: Record<string, number>) => {
    for (const [m, limit] of Object.entries(table)) acc[m] = Math.max(acc[m] ?? 0, limit);
  };
  raise(entry(QUOTAS, resolvePlan(e.planKey)) ?? {});
  for (const k of e.addonKeys) raise(entry(QUOTAS, k) ?? {});
  return acc;
}
```

The runnable version of this registry lives at `template/billing-core/`, and its tests are the
billing matrix in `playbook/subscription-billing.md`. Port it per
`template/billing-core/README.md` rather than retyping this snippet, and keep the tests —
they are the specification.

Four invariants are checked at startup and in tests, because every one of these failures is
silent:

- Every plan and add-on key in the pricing ladder resolves through `resolvePlan` to a
  `CAPABILITIES` entry, and every plan key also to a `QUOTAS` entry. A missing key does not
  throw at runtime — it quietly returns an empty capability list to someone who paid.
- `quotaFor()` returns a finite number for every `METRICS` entry, for every plan × add-on
  combination. "Unlimited" in marketing copy still needs a numeric ceiling in code: an
  actually-unbounded tier is an unbounded bill, which is the hole the `cost` gate in
  `playbook/acceptance-gates.md` exists to close.
- Plans and add-ons share no key. `CAPABILITIES` and `QUOTAS` are one flat namespace, so a
  collision hands a free-plan row the paid plan's capabilities through its `addonKeys`.
- Every add-on with a `cogs_note` cap has a matching `QUOTAS` entry for the metric that cap
  names. An unenforced quota is not a cost control: `addon.sms` priced at $3 against a
  "cap 150 msg/user/mo = $1.19 worst case" note is a $2.37 bill if nothing counts messages.

## Upsell axes that work at a $5 base

Ranked by how well they hold up when the base plan is already cheap.

| Axis | Example | Why it works |
|---|---|---|
| **Volume** | 10 watches → unlimited | Scales with the user's own success; nobody feels cheated |
| **Channel** | add SMS or push to email | Genuinely costs more to serve, so the charge is legible |
| **Retention depth** | 90 days → full history | Grows more valuable the longer they stay, which is also the retention story |
| **Cadence** | daily → hourly checks | Maps to real compute cost |
| **Seats** | share with a household | Expands the account rather than splitting it |
| **Export and integration** | API access, webhooks, calendar feed | Serves the minority who want it, invisible to everyone else |

### Axes that cannibalise

Do not gate these behind an add-on:

- **The core promise.** If the base plan cannot do the thing the landing page advertises,
  the base plan is a trial and the $5 price is a lie.
- **Basic reliability.** Faster alerts, better uptime, or accurate data as a paid tier
  implies the base plan is deliberately degraded.
- **Data export.** Gating the user's own data behind payment breaks selection gate **G8**
  (instant cancellability) in `playbook/product-selection.md` and, in the EU,
  data-portability obligations.
- **Security.** 2FA is never an upsell.
- **Support.** Implies unpaid users get none, which at this price means human labor the
  product cannot afford anyway.

## Pricing ladder

```yaml
plans:
  - key: base
    name: "<Product>"
    price_usd: 5                 # from intake.price_usd
    interval: month
    capabilities: [watch:10, notify:email, history:90d, export:csv]

  - key: base_annual
    name: "<Product>, annual"
    price_usd: 50                # 10x monthly: two months free, a legible discount
    interval: year
    # Listed, not inherited: the catalog is read by code that has no notion of "same as".
    capabilities: [watch:10, notify:email, history:90d, export:csv]
    aliases_to: base             # must match PLAN_ALIASES; checked by the startup invariant
    # Annual is the highest-leverage add-on: it cuts churn and payment fees at once.
    # 2.9% + $0.30 on $5 is 9% of revenue; on $50 once a year it is 3.5%.

addons:
  - key: addon.sms
    name: "Text alerts"
    price_usd: 3
    interval: month
    requires: [base]
    enabled_when: capability.sms_configured   # never sellable without a working transport
    capabilities: [notify:sms]
    cogs_note: "~$0.0079/msg US; cap 150 msg/user/mo = $1.19 worst case"

  - key: addon.unlimited
    name: "Unlimited watches"
    price_usd: 4
    interval: month
    requires: [base]
    capabilities: [watch:unlimited]
```

Rules:

- Every add-on `requires: [base]`. Add-ons are not standalone products; a bare add-on
  subscriber has no coherent experience.
- Every add-on with real marginal cost carries a `cogs_note` with a capped worst case. The
  cap is enforced in code as a `QUOTAS` entry, per the `cost` gate. An uncapped SMS add-on
  at $3 is a liability, not a product.
- An add-on whose dependency is missing from `CAPABILITIES.md` is built and tested against
  a mock, then hidden from the pricing page by `enabled_when`. Do not sell what cannot be
  delivered, and do not ask whether to sell it — hide it and log a `BLOCKER`.
- Catalog sync is idempotent by lookup key, so re-deploying does not create duplicate
  prices at the provider.

## The second service

A second *service* is a larger stretch than an add-on: a distinct product sharing the
account, billing, and entitlements. Only pursue it with budget remaining after the
`stranger-path` gate in `playbook/acceptance-gates.md` is green — never before, since a
half-built second product plus an unverified first product is strictly worse than one
verified product.

When it fits, the good version is adjacent: it reuses the same data the user already gave
you. A watcher's natural second service is a periodic digest of everything it watched; an
expiry tracker's is a shareable summary for a spouse or an accountant. Same inputs, new
output, no new integration — and the pricing is a bundle, not a second checkout.

## Minimum viable stretch

With `addons_enabled: true`, the stretch goal is met when all of these hold:

1. The capability registry exists and `can()` is the only access check in the codebase.
2. A base plan and an annual plan exist at the provider and are purchasable, and the annual
   plan resolves to base's capabilities and quotas — proven by test 16 in the billing matrix.
3. At least one add-on exists, is purchasable, and grants exactly its own capabilities and
   nothing else — proven by test 9 in the billing matrix.
4. The pricing page renders the ladder and hides add-ons whose `enabled_when` is false.
5. Upgrade, downgrade, and add-on removal each adjust entitlements through the
   `subscription.updated` webhook, not optimistically in the UI.
6. An add-on with marginal cost has an enforced, tested quota.
7. Both registry invariants are checked at startup and covered by tests: every catalog key
   resolves to a `CAPABILITIES` entry, and `quotaFor()` is finite for every `METRICS` entry
   across every plan × add-on combination.

With `addons_enabled: false`: items 1, 6, and 7 still apply. The schema ships; the catalog
does not. `HANDOFF.md` then states exactly what adding an add-on later requires — one catalog
entry, one capability row, one provider sync.
