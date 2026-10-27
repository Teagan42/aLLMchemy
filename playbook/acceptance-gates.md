# Acceptance Gates

Nobody is going to click through the product before launch. So "done" cannot mean an agent
believes it works — it has to mean a command exited zero. Every gate below is a script,
every threshold is a number, and `./verify.sh` runs all of them.

**A subagent reporting success does not pass a gate.** Only `verify.sh` does. This is the
load-bearing rule of the whole package: self-reported completion is where unattended runs
quietly ship broken products.

## Naming convention

The gates here are named, never numbered: `build`, `core`, `recurrence`, `billing`,
`security`, `legal`, `operations`, `cost`, `stranger-path`. Numbers are reserved for the
`G1`–`G8` product-selection gates in `playbook/product-selection.md`. "Gate 8" used to
resolve to both the `cost` gate and G8 instant-cancellability, and an agent that followed
the wrong one did the wrong work.

## verify.sh contract

```sh
./verify.sh                       # all gates, exit 0 only if all pass
./verify.sh --gate billing        # one gate
./verify.sh --list                # gate names
```

The nine `--gate` tokens, in run order: `build`, `core`, `recurrence`, `billing`,
`security`, `legal`, `operations`, `cost`, `stranger-path`.

Writes `artifacts/verify-<timestamp>.txt` with per-gate PASS/FAIL/SKIP, the command run,
and full output for failures. Prints a summary table last.

A `SKIP` must name the `BLOCKER` that caused it; an unexplained skip counts as a failure.
There are exactly two ways to declare one, and inventing a third is how "no test was
written" starts reading the same as "the test passed":

- Set `GATE_SKIP_<NAME>` (uppercase, hyphens as underscores — `GATE_SKIP_STRANGER_PATH`) to
  the blocker text. The gate is then not run at all.
- Have the gate print a line beginning `SKIP: ` at **column zero** and exit `77`. Column
  zero is the test, so the indented output of `gates/_lib.sh`'s `say` can never trip it by
  accident — which is also why a BLOCKER must never go out through `say`.

Exit `77` with no reason is a FAIL. So is a missing gate script. `verify.sh` exits 0 only
when every gate PASSed: a SKIP is not a pass, and the distinction lives in the report rather
than the exit code. Route a FAIL to its owning agent with the failing command and full
output; route a SKIP to `HANDOFF.md` as a `BLOCKER` with remediation steps.

This contract is already implemented. Copy all five of `template/verify.sh`,
`template/gates/`, `template/secret-scan.sh`, `template/preflight.sh` and
`template/teardown.sh` into the generated repo — `gates/security.sh` resolves the scanner as
a sibling of `gates/`, so the shorter list makes the `security` gate unable to pass at all.
`template/README.md` is the authoritative copy list and environment table. Extend the gate
bodies with product-specific assertions; the runner, the artifact format, and the exit-code
semantics are not reinvented per run, because a hand-rolled runner is where the "exit 0 only
if all pass" rule gets broken by accident.

## Tiers

The achievable tier is set by credentials and `go_live`, defined once in
`playbook/00-kickoff.md`: **Tier L** (live launch), **Tier T** (test-mode launch, the
default and a success), **Tier D** (degraded local artifact, never done). `HANDOFF.md`
states the achieved tier in its first line.

Every gate runs in all three tiers. What differs is which assertions can be proven, and an
assertion that cannot be proven is a declared SKIP with a named BLOCKER — never a weakened
check and never a pass.

| Gate | L | T | D |
|---|---|---|---|
| `build` | PASS | PASS | PASS |
| `core` | PASS | PASS | PASS |
| `recurrence` | PASS | PASS | SKIP — no deployed job endpoint to trigger |
| `billing` | PASS, live card | PASS, test card `4242…` | PASS, test card `4242…` |
| `security` | PASS | PASS | PASS |
| `legal` | PASS | PASS | PASS |
| `operations` | PASS | PASS | SKIP — `/healthz` and rollback are local-only |
| `cost` | PASS | PASS | PASS |
| `stranger-path` | PASS, public URL, live card | PASS, public URL, test card | SKIP — local container only |

Tier D therefore cannot reach "9 of 9 passed", and `verify.sh` exits non-zero in it. That is
the point: `playbook/00-kickoff.md` calls Tier D never done, so a green run in it would make
the exit code lie.

## The nine gates

### build  (`--gate build`)
```sh
pnpm install --frozen-lockfile && pnpm typecheck && pnpm lint && pnpm build
```
Zero type errors, zero lint errors, production build succeeds. No `@ts-ignore` or
`eslint-disable` added to pass this gate — grep the diff for new ones and fail if present.

### core  (`--gate core`)
Unit and integration tests for the thing the user pays for.
- ≥ 80% line coverage on `src/core/**` and `src/billing/**`
- 100% of webhook handlers covered
- Every external dependency has a test for its failure mode (timeout, 500, malformed
  response, rate limit). A product whose value depends on an upstream feed must not crash
  when that feed is down; it must degrade and say so.

### recurrence  (`--gate recurrence`)
The subscription justification. Prove the scheduled job works:
- Unit test: the job produces correct output from fixture data.
- Idempotency test: running twice for the same period produces one delivery, not two.
- Integration test: triggering the deployed job endpoint writes a run record and output.
- Deployed assertion: `/healthz` reports `last_cron_success` within one expected interval,
  checked by `operations` against `$APP_URL`. With no public URL there is no deployed job
  endpoint, so in Tier D these last two are a declared SKIP and the unit and idempotency
  tests still run.

A product that passes every other gate and fails this one is a one-time purchase with a
recurring charge attached. Treat the failure as critical.

### billing  (`--gate billing`)
All seventeen tests from `playbook/subscription-billing.md`'s matrix; row 13 (live E2E) is
delegated to `stranger-path`. Non-negotiable subset: rows 2 (duplicate delivery, one state
change), 3 (tampered signature, 400), 11 (quota exceeded, graceful denial), 14 (apply fails,
provider retries), 15 (two concurrent deliveries) and 7 (cancel then revoke at period end).

The daily reconciler is part of this gate. It is the only thing that flips a row after the
period ends and the only thing that replays an event that never applied, so the gate asserts
the job is registered, that `/healthz` reports its last success, and that a drifted row is
corrected against the product store.

### security  (`--gate security`)
```sh
pnpm audit --audit-level=high        # zero high or critical
./secret-scan.sh                     # exit 0 clean, exit 1 on a hit
```

`template/secret-scan.sh` is the only sanctioned secret scan. Its contract:

- Scans the working tree **and every reachable commit** (`git grep` over `git rev-list
  --all`), because a secret already committed is a never-downgradable failure and a
  working-tree scan cannot see it.
- Scans gitignored files too (`git grep --untracked --no-exclude-standard`). Without
  `--no-exclude-standard` `git grep` honours `.gitignore`, so a live key in `.env` — the
  single most likely place for one, and the file
  `playbook/autonomy-contract.md` explicitly forbids writing secrets to — is invisible.
- Refuses a shallow clone. A truncated history makes every `git grep <rev>` fail, and
  reporting that as clean is worse than reporting a hit: a gate that cannot prove itself
  FAILs. Captures the history pass's stderr as a `scan-error` hit for the same reason.
- Matches key *shapes*, not prefixes, so prose like `sk_test_...` in this playbook is not a
  hit: `sk_live_[0-9A-Za-z]{16,}`, `sk_test_[0-9A-Za-z]{16,}`, `whsec_[0-9A-Za-z]{16,}`,
  `AKIA[0-9A-Z]{16}`, `-----BEGIN [A-Z ]*PRIVATE KEY-----`.
- Exits **0 when clean, 1 when a secret is found**, printing `file:line` and the matching
  rule — never the value.
- Tolerates a repo with no commits yet.

Never write `grep -E '…' && exit 1` instead. `grep` exits 1 on a clean scan, so that form
inverts the gate: a clean repo fails and a dirty one is reported by whatever ran next.

Plus, each asserted by a test:
- Every mutating route requires authentication. Enumerate routes and assert a 401/403 for
  an anonymous request to each; a route added later without auth then fails the gate. The
  gate locates the file by convention and then greps it for the assertion: an empty or
  assertion-free test file is a FAIL, because presence is self-report.
- No horizontal privilege escalation: user A cannot read or modify user B's records.
  Test with two real users and a direct ID substitution.
- Rate limits on auth, signup, password reset, and any expensive endpoint.
- Security headers present: HSTS, `X-Content-Type-Options`, `Referrer-Policy`,
  `X-Frame-Options`, and a CSP without `unsafe-inline` in script-src.
- Passwords hashed with argon2id or bcrypt ≥ 12 rounds, or auth delegated entirely.
- Session cookies `HttpOnly`, `Secure`, `SameSite=Lax`.
- Parameterised queries only; no string-concatenated SQL anywhere.
- All user-supplied content escaped on output.
- Webhook route exempt from CSRF but signature-verified.

### legal  (`--gate legal`)
Legal documents and data rights.
- Reachable ToS, privacy policy, and refund/cancellation policy — linked from the footer
  and from checkout, not orphaned pages.
- Privacy policy enumerates actual subprocessors (host, database, billing, email, SMS,
  inference) and the real retention period per entity, matching `PRODUCT-SPEC.md`.
- `GET /api/account/export` returns the user's complete data as JSON.
- `DELETE /api/account` deletes or anonymises, cancels the subscription, and is tested to
  leave no orphaned rows.
- If `audience_region` is `eu` or `global`: consent banner gating non-essential cookies,
  lawful basis stated, no non-essential tracking before consent.
- Pricing page states the price, the interval, that it renews, and how to cancel.

### operations  (`--gate operations`)
- `/healthz` returns 200 with database check, `last_cron_success`, and build SHA. The gate
  parses `last_cron_success` and fails when it is older than `CRON_MAX_AGE_SECONDS`
  (default 48h) or null. The field merely existing proves nothing — any string satisfies a
  presence check, and `recurrence` delegates its whole deployed half here.
- `rollback.sh` tested against the previous deployment. In Tier D there is no previous
  deployment, so this and the `/healthz` assertions are a declared SKIP; the local ones
  below still run.
- Kill switch tested: set, maintenance page served, cron halted, billing webhooks still 200.
- Database backup verified to exist; restore command documented.
- `teardown.sh --dry-run` enumerates every row of `PROVISIONED.md`. Dry run only — a gate
  must never destroy the thing it is checking.
- `RUNBOOK.md` covers: deploy, roll back, flip to live billing, rotate a secret, restore a
  backup, respond to a stuck webhook, respond to a cost spike.

### cost  (`--gate cost`)
- `PRODUCT-SPEC.md` carries a parseable `per-user COGS: <amount>` line, and that amount is
  ≤ 20% of `price_usd`. Product-selection gate G4 is a unit-economics ceiling; without a
  figure this gate can read, the verdict is prose the agent wrote about its own work.
- The per-user cost model in `PRODUCT-SPEC.md` matches what the code can actually consume.
- A per-user quota is enforced in code, before the expensive call, with a test proving the
  denial path. An unenforced quota is not a cost control.
- Daily cost log line emits.
- `PROVISIONED.md` exists, has at least one row, its fixed monthly total is ≤
  `monthly_infra_budget_usd`, and every row carries a teardown command and a parseable `#`.
  A header with no rows and a row with a blank `#` are both FAILs: nothing was summed, and a
  resource nothing enumerates is a resource nothing can destroy. An asserted budget that is
  never summed against what was actually created is not a ceiling; see
  `playbook/autonomy-contract.md`.
- Intake `monthly_infra_budget_usd` reaches the gate as `MONTHLY_INFRA_BUDGET_USD`, the same
  way `credentials_file` reaches `preflight.sh` as `CREDENTIALS_FILE`. Export it before
  running `verify.sh`. With neither the variable nor an `intake.yaml` value the gate FAILs
  rather than falling back to a default — a silent default passes a $20 resource against 25
  when the operator asked for 5.
- The **Usage risk** column is parsed, not merely present. Each cell must name a ceiling
  from a controlled vocabulary: `none`, `capped-at-tier`, `provider-cap:<amount>`, or
  `converts-to:<amount>`. Free prose is a FAIL, and the `converts-to:` amounts are summed
  into a second ceiling against the same budget. "Never enable usage-based autoscaling
  without a provider-side spend cap" is unenforceable if nothing reads the cell.
- Projected infrastructure cost at 1,000 users ≤ `monthly_infra_budget_usd`; if the free
  tiers would be exceeded, the next tier's price is named in `HANDOFF.md`.

### stranger-path  (`--gate stranger-path`)
The gate that subsumes the others. Playwright against the **deployed public URL** in Tier L
and Tier T, and against the local container in Tier D, in a clean browser profile, no
seeded state:

1. Load the landing page. Assert the headline conveys the product.
2. Sign up with a fresh address.
3. Reach first value within 60 seconds. Assert the actual output, not a spinner.
4. Subscribe — a real card in Tier L, test card `4242…` in Tier T and D. Assert the
   entitlement and the gated capability.
5. Trigger the recurring job. Assert the delivery.
6. Buy an add-on, if any. Assert only its capability appears.
7. Cancel via the portal. Assert access persists to period end, then is revoked.
8. Export data. Assert completeness.
9. Delete the account. Assert removal.
10. Confirm no console errors and no 5xx across the run.

Run against mobile viewport too — most of this audience arrives on a phone, and a landing
page that is unusable at 390px wide has failed regardless of its tests.

A local container is a Tier D target, and the gate declares it as a SKIP rather than
passing: `SKIP: stranger-path verified against local container only, no public URL (Tier D)`
at column zero, exit 77. Local is matched on the resolved **host**, not a URL prefix —
`localhost`, `127.*`, `0.0.0.0`, `::1`, `host.docker.internal`, `*.local`, any RFC1918
address, and any bare hostname with no dot. Keep the tier line at the top of `HANDOFF.md`
honest.

The gate also probes `$APP_URL` itself before delegating. The product command may not read
`APP_URL` at all, so without a reachability assertion the gate that is supposed to subsume
the others can certify a deployment that does not exist.

## Thresholds

| Metric | Threshold |
|---|---|
| Type errors / lint errors | 0 |
| High or critical dependency vulnerabilities | 0 |
| Coverage, `src/core/**` and `src/billing/**` | ≥ 80% lines |
| Webhook handler coverage | 100% |
| Secrets in the repo | 0 |
| Unauthenticated mutating routes | 0 |
| Landing page LCP, mobile | < 2.5s |
| Signup to first value | < 60s |
| Per-user COGS at 1,000 users | ≤ 20% of price |
| Fixed infra cost in `PROVISIONED.md` | ≤ `monthly_infra_budget_usd` |
| `stranger-path` steps passing | all |

## Failure handling

Route each failure to its owning agent with the failing command and full output attached —
not a paraphrase. Cap at **three repair cycles per gate**. After the third, record the gate
as a `BLOCKER` in `HANDOFF.md` with the exact failing command, and continue to the next
gate. Never attempt a fourth cycle on the same failure; that loop is how a run exhausts its
budget with nothing deployed.

Three failures that must never be downgraded to blockers, because shipping them does real
harm to real people: a secret committed to the repo, an unauthenticated mutating route, and
a billing double-charge. If one of those cannot be fixed, the kill switch goes on and the
product ships disabled with the blocker at the top of `HANDOFF.md`.
