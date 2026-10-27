# Autonomy Contract

No human is available for the duration of this run. The operator submitted one
questionnaire and left. Nothing will answer you.

This changes what "I need to know X" means. Normally it means stop and ask. Here, stopping
produces nothing — not a delay, a permanent hang. So every unknown must be converted into
a choice, and the choice must be recorded well enough that a human can audit or reverse it
later. That record is the substitute for the conversation you cannot have.

## The decision ladder

Apply in order. Stop at the first rung that yields an answer.

**1. The intake.** `intake.yaml` plus schema defaults from `intake.schema.json`. An absent
or empty file is valid; every field has a default.

**2. The documented default.** The playbook document that owns the domain has a default table:
`playbook/product-selection.md` for product shape, `playbook/subscription-billing.md` for billing semantics,
`playbook/deploy-pipeline.md` for infrastructure, `playbook/acceptance-gates.md` for thresholds, `playbook/addon-design.md` for
pricing structure. These are pre-made decisions. Use them without deliberation.

**3. The cheapest reversible option.** When no default covers it, pick the choice that is
cheapest to undo. Prefer: a config flag over a schema change; a feature flag over a
deletion; a managed free tier over a committed plan; a widely-used library over a bespoke
implementation; the smaller scope over the larger. Reversibility beats optimality, because
a human can revise a reversible choice after the run but cannot un-ship an irreversible one.

**4. Decide and record.** Choose the option a competent engineer would defend in review,
append a row to `DECISIONS.md`, and continue. This rung always terminates. There is no
fifth rung and no path that leads back to the user.

## What is not a question

Three situations feel like they need a human. None do.

**Ambiguity** — two reasonable readings of the scope. Resolve with the ladder. Pick the
narrower reading, note the wider one in `DECISIONS.md` as a follow-up.

**Missing capability** — a credential is absent or invalid. `playbook/deploy-pipeline.md` and
`QUESTIONNAIRE.md` both carry fallback tables for every provider class. Take the fallback,
log a `BLOCKER`, keep going.

**Hard external obstacle** — a provider demands manual account verification, a domain is
not delegated, a 10DLC registration takes three days. You cannot fix these and neither can
a question right now. Log a `BLOCKER` with the exact remediation, build everything that
does not depend on it, and ship the rest. With `escalation: ship-degraded` (the default)
this is the expected path, not a failure.

## Model availability

A dead model request is the same class of failure as a question. Not a delay — the run stops
and nothing arrives to restart it. This has already been fatal: an unattended run lost nine
parallel agents at once to an expired AWS SSO token, every one of them failing with "Could
not load AWS credentials", and it shipped nothing. A document that converts every unknown
into a recorded choice cannot leave its own model as a single point of failure.

So model unavailability gets its own ladder, parallel to the decision ladder, and it
terminates the same way.

**1. The harness's own retries.** Claude Code already retries ten times with exponential
backoff — 429, 529, 5xx, dropped or stalled streams, expired cloud credentials
(`CLAUDE_CODE_MAX_RETRIES`, ceiling 15). Nothing to do. Let it finish before concluding
anything is wrong.

**2. The gateway's per-request fallback.** `gateway/providers.conf` plus `model_chain` define an ordered model
chain ending at a local Ollama model. Any failure class — auth, quota, network, 5xx,
timeout, malformed, unknown — is re-issued against the next model inside the same request,
so the caller sees one slow success rather than an error. `gateway/README.md` documents the
chain; `gateway/probe.sh` proves it answers before the run starts.

**3. The supervisor's per-run tier advance.** When a whole chain is gone, or the harness
process itself dies, `bin/run-factory.sh` advances to the next harness tier and **resumes**
the run — `--continue` or `-r <session-id>`, never a fresh start. A restart re-spends budget
on work already on disk and re-opens decisions `DECISIONS.md` has already settled, which is
the failure mode the budget ladder exists to prevent.

**4. Tiers exhausted.** A `BLOCKER` in `HANDOFF.md` with exact remediation, plus every
unblocked part of the scope delivered anyway. Identical to any other external obstacle.

Rung 4 always terminates. No rung leads back to the user, and no rung is "wait for the model
to come back".

The local tier is not a reduced scope. It continues the full build: product selection,
billing, deploy, gates, handoff. It is slower and its product is materially weaker, and that
is the point — it exists so a run finishes and hands off instead of dying mid-phase. Record
the degradation; do not pre-empt it by narrowing what the local tier may attempt.

A `model_chain` naming no local provider truncates the ladder: tiers stop there and
the run blocks instead of degrading. The operator chose a blocker over a weak product, which
is a legitimate trade and the only supported way to opt out.

### The one exception

**A policy or safety refusal is never re-routed to another model.** Re-rolling a refusal on a
different model until one complies is laundering, not failover. It stops the run: record it
and report it like any other blocker.

This is why `content_policy_fallbacks` is never rendered into the gateway config. LiteLLM keeps
that error class on a separate key from the general `fallbacks` list precisely so the broad
retry does not sweep refusals along with timeouts. Setting it would make the carve-out
unenforceable from inside the run.

### Recording a failover

Every failover gets a `DECISIONS.md` row, in the same six-column format as the rest of the
table — a model tier change is an unasked question like any other:

```markdown
| 7 | 3 | Continue after the cloud chain stopped answering? | Failed over to local `gpt-oss:20b` via the gateway | Model ladder 2 — chain exhausted on `authentication_failed` | Medium: re-run Phase 3+ on a cloud model |
```

`HANDOFF.md` states the **achieved model tier** next to the achieved outcome tier on its
first line. A human reading the handoff must be able to tell that a 20B local model wrote
both the product and the tests that pronounced it working. "Tier T, all nine gates green" is
a different claim on a frontier model than on local inference, and the operator's first
decision after the run — ship it, or re-run the build on a cloud model — depends entirely on
which one it was. Hiding the tier makes that decision for them.

## Prohibited

- Calling `AskUserQuestion` or `ExitPlanMode`. Both are denied by permission policy.
- Ending any message — yours or a subagent's — with a question to the user.
- "Let me know if…", "please confirm…", "would you prefer…", "awaiting your input".
  A `Stop` hook — and a `SubagentStop` hook, so a role's closing message is screened the
  same way — rejects these and makes you rewrite, costing budget for nothing.
- Pausing work on scope B because scope A is blocked, when B does not depend on A.
- Re-opening a decision already recorded in `DECISIONS.md`. Churn is the main way an
  unattended run exhausts its budget without shipping. A recorded decision is settled;
  revise it only if execution proves it factually impossible, and then record the reversal
  with its cause.

Reporting is not asking. Your final message should be rich in statements: what exists, what
was assumed, what is blocked, what a human should do next. Phrase every one of those as an
indicative sentence.

## DECISIONS.md

Lives in the **product's** repository at `$FACTORY_PROJECT_DIR/DECISIONS.md`, not in the
package. The factory and the product it builds keep separate audit trails; the package's own
decisions are ADRs in its `docs/adr/`.

Append-only. One row per resolved unknown. Written as you go, not reconstructed at the end.

```markdown
# Decisions

| # | Phase | Question that went unasked | Choice | Ladder rung | Reversal cost |
|---|-------|---------------------------|--------|-------------|---------------|
| 1 | 1 | Which host, given `hosting: auto`? | Fly.io | 2 — only host with valid token and native cron | Low: Dockerfile is portable |
| 2 | 2 | SMS in the base plan? | No, paid add-on | 2 — COGS ceiling in product-selection | Low: entitlement flag |
| 3 | 3 | Retain raw scrape payloads? | 30 days then purge | 3 — cheapest reversible; satisfies `audience_region: eu` | Low: config constant |
```

The "ladder rung" column is the part a reviewer actually reads. It shows whether a choice
was policy or improvisation.

## HANDOFF.md

**The first line of `HANDOFF.md` is the achieved outcome tier** — `Tier L`, `Tier T` or
`Tier D`, with the one fact that set it. Nothing else goes above it. A handoff that does not
state its tier leaves the operator unable to tell a test-mode success from a live launch or
from a local artifact, and the tier is the only thing `verify.sh`'s exit code cannot carry.

```markdown
# Tier T — deployed to a public URL, billing wired in test mode (`go_live` not set). Model tier: cloud (no failover)
```

The model tier rides on that same line, per "Model availability" above. Name the model that
actually did the work when it was not the first choice.

Then the blockers, in this format:

```markdown
## BLOCKER 1 — SMS disabled in production

**Impact:** The SMS add-on is built and unit-tested against a mock transport but is
disabled by config. Email delivery is unaffected. Base plan is complete.

**Cause:** `TWILIO_ACCOUNT_SID` absent from the credentials file. US A2P 10DLC
registration also takes 2–5 business days and cannot be completed by an agent.

**Remediation:**
1. Create a Twilio account and buy a number.
2. Register a 10DLC campaign (2–5 business days).
3. Set `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` in the host's env.
4. Set `FEATURE_SMS=true`.
5. Run `./verify.sh --gate billing` — 7 tests currently skipped will run.

**Verification that the rest is unaffected:** `./verify.sh` passes 8 of 9 gates; see
`artifacts/verify-latest.txt`.
```

Every blocker gets impact, cause, numbered remediation, and proof of what still works.
A blocker without remediation steps is just a complaint.

## Secret hygiene

- Never print a secret value. Log `STRIPE_SECRET_KEY: present` / `: absent`.
- Never write secrets to any file inside the repo. Not `.env`, not a test fixture, not a
  comment. Commit `.env.example` with empty values.
- `.gitignore` must contain `.env*` with a `!.env.example` exception before the first
  commit, not after.
- Secrets reach production through the host's secret store via CLI, set from the
  credentials file, never through a committed file or a build argument.
- Generated admin credentials go in `HANDOFF.md` only, with a line telling the operator to
  rotate them on first login.
- A credential that expires mid-run is an availability problem, not a hygiene one. On Claude
  Code, the `awsAuthRefresh` setting runs a command — typically
  `aws sso login --profile <p>` — inside the retry budget when cloud credentials expire, so
  the request succeeds on a later attempt instead of killing the turn. That setting alone
  would have prevented the nine-agent failure that motivated the whole failover layer. It is
  user- and profile-specific, so it belongs in the operator's own `~/.claude/settings.json`,
  never in this package.
- Before the final commit, scan for leaks with `template/secret-scan.sh` — it covers the
  working tree and every reachable commit, and exits 0 only when clean. Its contract is in
  `playbook/acceptance-gates.md`, under the `security` gate. Never substitute
  `grep -E '…' && exit 1`: grep exits 1 on a clean scan, so that form fails clean repos and
  passes dirty ones.

## Provisioning spend

The launchers run without approval prompts, so nothing outside this section stands between
the run and the operator's credit card. `monthly_infra_budget_usd` (default 25) is only a
ceiling if something sums what was actually created against it. `PROVISIONED.md` is that
something.

Hard rules:

- Create free-tier or zero-commitment resources freely. Anything else needs a
  `DECISIONS.md` row before it is created.
- Never create a resource with a non-zero fixed monthly price unless that price plus the
  ledger's existing fixed total is ≤ `monthly_infra_budget_usd`.
- Never enable usage-based autoscaling without a provider-side spend cap. Unbounded usage
  on an unattended run has no upper limit at all. The ledger's **Usage risk** column is how
  this rule becomes checkable: the `cost` gate parses it against a controlled vocabulary and
  FAILs on free prose, so "no cap" cannot be written as a sentence and pass.
- Never create a resource whose trial converts to a paid plan unless the converted price
  also fits the budget. Record it as `converts-to:<amount>`; the gate sums those into a
  second ceiling. A $0.00 fixed price that becomes $20 in fourteen days is a $20 resource.
- Never buy a domain. Never raise a provider plan tier.
- Buy a phone number only when `comms_channel: email+sms`, and only when its price fits the
  ledger.

### PROVISIONED.md

Append-only, one row per created resource, written at creation time rather than recalled
afterwards.

```markdown
# Provisioned resources

| # | Provider | Resource | Fixed USD/mo | Usage risk | Teardown |
|---|----------|----------|--------------|------------|----------|
| 1 | Fly.io | app `digestly` (shared-1x, 256MB) | 0.00 | capped-at-tier (egress inside the free allowance) | `flyctl apps destroy digestly -y` |
| 2 | Neon | project `digestly-prod` free tier | 0.00 | capped-at-tier | `neonctl projects delete <id>` |
| 3 | Stripe | product + 2 prices | 0.00 | none | `stripe products update <id> --active=false` |
```

**Usage risk** is a controlled vocabulary, because `gates/cost.sh` parses it: `none`,
`capped-at-tier`, `provider-cap:<amount>` or `converts-to:<amount>`, each optionally
followed by a parenthetical. Prose there is a FAIL. Every row needs a `#`: a blank one used
to be skipped silently by both the gate and `teardown.sh`, which is how a provisioned
database ends up in neither the sum nor the teardown.

`teardown.sh` destroys every row in the ledger, in reverse order, and is the real answer to
"the agent provisioned things nobody approved": full autonomy is acceptable because it is
reversible by one command. A resource with no teardown command does not belong in the
ledger and must not be created.

The `cost` gate asserts the ledger exists, has at least one row, totals within budget
(including the `converts-to:` amounts), names a ceiling in every Usage risk cell, and has a
teardown command per row. The budget reaches it as `MONTHLY_INFRA_BUDGET_USD`; with neither
that nor an `intake.yaml` value it FAILs rather than guessing a default. The `operations` gate asserts `teardown.sh --dry-run` enumerates every row — dry
run only, never the real thing.

## Budget

Token and wall-clock budget, not money. Track consumption continuously. Phases are not
equally valuable: a deployed product with one working feature is worth more than an
immaculate repo that never shipped.

| Spent | Posture |
|---|---|
| 0–50% | Full scope: product, build, billing, surface, add-ons |
| 50–70% | Freeze new features. Finish billing, deploy, verify |
| 70–80% | Deploy and verify only. Drop add-ons; keep the entitlements table |
| 80–90% | Make the critical path green: signup → subscribe → value → cancel |
| 90–100% | Write `HANDOFF.md`, `RUNBOOK.md`, `DECISIONS.md`. Commit. Report |

Per-gate repair cap: three cycles. After the third failure, record the gate as a `BLOCKER`
with its exact failing command and output, then move to the next gate. Never loop a fourth
time on the same failure — that is where unattended runs die.

Per-phase wall-clock sanity: if a phase exceeds roughly a third of total budget, cut its
remaining scope to the minimum that passes its gate and advance.

## Subagent delegation

Every subagent prompt must contain:

1. "Load `playbook/autonomy-contract.md` first. No human is available; never ask a question."
2. The intake values it needs, inline — it cannot interview you either.
3. `CAPABILITIES.md` and `PRODUCT-SPEC.md` paths.
4. Its exact scope and the gate it must pass.
5. "Return file paths and verification command output, not a prose summary."

A subagent that returns "should I use X or Y?" has lost its context. Do not relay that
question upward. Apply the ladder yourself, re-dispatch with the answer inlined, and record
the decision.
