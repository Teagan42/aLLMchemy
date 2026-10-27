# billing-core

A runnable reference implementation of the billing semantics in
`playbook/subscription-billing.md` and `playbook/addon-design.md`. Plain Node ESM, JSDoc
types, zero dependencies, tested with the built-in runner.

```sh
cd template/billing-core && node --test
node --test template/billing-core/test/*.test.mjs     # from the repo root
```

The glob is deliberate. `node --test <directory>` only works from Node 23 onward; earlier
versions resolve the path as a module and fail with `MODULE_NOT_FOUND`. The gate script
`template/gates/billing.sh` uses the glob for the same reason.

## Why plain .mjs and not TypeScript

The factory repo must have no install step. An agent that has to run `pnpm install` before
it can check a semantic is an agent that will skip the check. So the reference is `.mjs`
with JSDoc types, while `playbook/subscription-billing.md` keeps TypeScript because that is
the *generated product's* target, not this directory's.

**Do not add a `package.json` here.** It would add an install step to the one thing in the
package that is supposed to run everywhere with no setup.

## Modules

| File | Holds |
|---|---|
| `entitlements.mjs` | `CAPABILITIES`, `QUOTAS`, `METRICS`, `PLAN_ALIASES`, `resolvePlan`, `can`, `quotaFor`, `consumeQuota`, `assertCatalogInvariants` |
| `webhook.mjs` | `claimEvent`, `handleWebhook`, `applyEvent`, `cancelImmediately`, `reviveEvent`, the 5-minute lease, the dead-letter threshold |
| `store-memory.mjs` | the store port, with the conflict and lease behaviour of the documented SQL, plus an injected clock |
| `reconciler.mjs` | the daily sweep: date-driven status flips, provider drift repair, replay of every unprocessed event |
| `fixtures.mjs` | test setup and event builders. Outside `test/` because `node --test` treats every file in a `test/` directory as a test file |

## One deliberate difference from the playbook's code blocks

It lifts an I/O concern out so the semantics are testable without a database. Port it back
when you port the code.

1. **`can(entitlement, capability, now)` is pure.** The playbook's `can(userId, capability)`
   reads the entitlement itself. The read belongs to the product's ORM; the decision does
   not, and a pure decision is the one that can be exhaustively tested.

Everything else matches `playbook/subscription-billing.md` and `playbook/addon-design.md`
exactly. A divergence is a finding, not a note: documenting a known doc bug here instead of
fixing it there is how an implementer ports the wrong semantics.

## What the tests cover

One file per concern. Every row of the 17-row matrix in
`playbook/subscription-billing.md` except row 13, which is a live E2E against the deployed
URL and belongs to the `stranger-path` gate.

| File | Matrix rows |
|---|---|
| `test/webhook.test.mjs` | 1, 2, 3, 4, 10, 14, 15 |
| `test/lifecycle.test.mjs` | 5, 6, 7, 8, 9, 17 |
| `test/quota.test.mjs` | 11 |
| `test/reconciler.test.mjs` | 12 |
| `test/entitlements.test.mjs` | 16, plus all four catalog invariants |

The invariant tests assert that every catalog key resolves, that `quotaFor` returns a finite
number for every `METRICS` entry across every plan × add-on combination, that plans and
add-ons share no key, that every metered add-on caps its own metric, and that `can()` grants
free capabilities to paying users. Every one of these fails silently in production: a missing
key hands an empty capability list to someone who paid, a missing quota bills without a
ceiling, and a colliding key hands a free-plan row the paid plan.

## Porting it into the product

Keep the semantics and the tests; replace the store.

1. Translate `entitlements.mjs` to the product's language. It has no I/O, so this is
   mechanical.
2. Implement the `store-memory.mjs` port against the real ORM. The claim must stay a single
   atomic statement — the SQL in `playbook/subscription-billing.md` is that statement.
   Splitting it into a SELECT and an UPDATE reintroduces the double-apply this exists to
   prevent.

   Four port obligations the in-memory store satisfies invisibly, so a real one has to be
   written for them deliberately:
   - `listUnprocessed(leaseMs)` returns every row with `processed_at IS NULL` whose lease has
     expired, whatever its attempt count. `listDeadLetters` only decides alert severity.
   - `processed_at` is written inside the apply transaction, and a rollback unwinds it.
   - `queueEmail` and `record` are unique on `provider_event_id`. `applyEvent` can
     legitimately run twice for one event and must not emit twice.
   - `payload` read back from `JSONB` has string timestamps. `reviveEvent` in `webhook.mjs`
     restores them; comparing a string to a `Date` makes every liveness check silently false.
3. Port `webhook.mjs` unchanged in order: verify, claim, act.
4. Port the test files. They are the specification; the implementation is not.
5. Call `assertCatalogInvariants()` at startup, not only in tests. A plan key that resolves
   to nothing must fail the boot, not strip a paying user at request time.
