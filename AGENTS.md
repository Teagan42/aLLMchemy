# AGENTS.md

Root instructions for this repository. Read before anything else. Codex loads this file
automatically; Claude Code loads it via `CLAUDE.md`.

## Rules that hold in both jobs

These three sit above the mode router because they are not run-mode policy. They bind a
developing agent exactly as hard.

### Gate naming

Two sets of gates exist and the numbers collided, so:

- `G1`–`G8` are the product-selection hard gates in `playbook/product-selection.md`.
- The nine acceptance gates in `playbook/acceptance-gates.md` are named, never numbered:
  `build`, `core`, `recurrence`, `billing`, `security`, `legal`, `operations`, `cost`,
  `stranger-path`. Those names are also the `./verify.sh --gate` tokens.

"Gate 8" previously resolved to both the `cost` gate and G8 instant-cancellability. Write
the name. `dev/test.sh`'s `gates` suite fails on a numeric gate name.

### Secrets

- Never print a secret value. Log `NAME: present` or `NAME: absent`.
- Never write a secret into the repo. `.gitignore` covers `.env*` with a `!.env.example`
  exception in the **first** commit, not a later one. `template/secret-scan.sh` is the only
  sanctioned leak check: it covers history as well as the working tree and exits 0 when
  clean. A bare `grep … && exit 1` is inverted — it fails clean repos.

### Never weaken a test or a gate

No `.skip`, no loosened assertion, no deleted case, no `@ts-ignore` added to clear a
typecheck. If a check fails because the code is wrong, fix the code.

## Which job are you doing

Two jobs share this repo, and a wrong guess is expensive in both directions: an agent that
guesses wrong either invents a micro-SaaS during a development session or tries to interview
an absent operator during a run.

**Developing this package** — changing the playbook, scripts, gates, template, or docs. Read
`DEVELOPING.md`. Everything from "What this repository is" down is run-mode instruction and
does not apply to you; the three sections above do.

**Running the factory** — building a product for an operator. Continue below.

The test, not a judgement call: you are running the factory only if your opening instruction
came from `bin/run-claude.sh`, `bin/run-codex.sh` or `bin/run-factory.sh` and told you to
execute the run. That is the whole test. An absent `intake.yaml` does **not** mean you are
developing — a zero-config submission is legal and every field then takes its schema default
(`bin/validate-intake.mjs`, `playbook/00-kickoff.md`). Nothing started by hand is a run.

Those three launchers provision real infrastructure and spend real money, under
`bypassPermissions` with the no-questions hook armed. There is no dry-run flag. Never start
one to try something out — `DEVELOPING.md` says what to use instead.

## What this repository is

A handoff package, not an application. One human fills one questionnaire. An agent then
invents a $5/month subscription product, builds it, deploys it to a public URL, wires it to
the billing provider (test mode by default, live only with `go_live: true`), tests it
against that URL, and hands back a running business — with no further human contact.

How much of that is reachable depends on the credentials supplied. Three outcome tiers — L,
T and D — are defined in `playbook/00-kickoff.md`; **Tier T, a public URL with billing in
test mode, is the default and a success.** Read that section before treating anything short
of a live launch as a shortfall.

## The hard constraint

**No human is available.** The operator submitted `intake.yaml` and left. Nobody will
answer you. A question is not a delay, it is a permanent hang.

Read `playbook/autonomy-contract.md` before your first substantive action and apply its
decision ladder to every ambiguity for the rest of the run:

1. The `intake.yaml` answer (absent or empty is valid; every field has a schema default)
2. The documented default in the playbook document that owns the domain
3. The cheapest reversible option
4. Decide, append a row to `DECISIONS.md`, and continue

Rung 4 always terminates. There is no rung that leads back to the user.

An external blocker — an invalid credential, a provider demanding manual account
verification — is also not a question. It is a `BLOCKER` entry in `HANDOFF.md` plus every
unblocked part of the scope delivered anyway.

Reporting is not asking. Close with statements: what exists, what was assumed, what is
blocked, what a human should do next.

## Playbook

Platform-neutral. These are the authoritative documents; harness-specific files under
`.claude/` are thin pointers to them.

| Document | Read it when |
|---|---|
| `playbook/00-kickoff.md` | First. The run's phase sequence and gates |
| `playbook/autonomy-contract.md` | Before the first action of every phase |
| `playbook/product-selection.md` | Phase 2, before generating candidates |
| `playbook/subscription-billing.md` | Phase 3 for the schema, Phase 4 for the logic |
| `playbook/deploy-pipeline.md` | Phase 1 for preflight, Phase 6 for release |
| `playbook/acceptance-gates.md` | Early, so the build targets the gates; Phase 7 to run them |
| `playbook/addon-design.md` | Phase 3 for the schema, Phase 4 for the catalog |
| `playbook/roles/*.md` | When performing that role |
| `template/README.md` | Phase 3 onward. Runnable scaffold: `verify.sh`, the nine gates, preflight, secret scan, teardown, billing core |
| `gateway/README.md` | When a model request fails, or to change the fallback chain |

## Execution modes

The phase sequence is identical on both harnesses. Only the dispatch differs.

**Delegating harness (Claude Code, or anything with subagents).** Each `playbook/roles/*.md`
is a subagent. Dispatch per phase; run Phase 4 and Phase 5 concurrently. Give every
subagent the intake values inline, the paths to `CAPABILITIES.md` and `PRODUCT-SPEC.md`,
its gate, and the instruction to read `playbook/autonomy-contract.md` first — a subagent
that cannot see the contract will try to ask a question and deadlock the run.

**Single-threaded harness (Codex `exec`, or any single-context runner).** There are no
subagents. Adopt each role yourself, in sequence, by reading its `playbook/roles/*.md` and
following it to its gate before moving on. Phases 4 and 5 become sequential rather than
concurrent; nothing else changes. Keep `DECISIONS.md` open as the running record, since you
have no subagent reports to reconstruct from.

Do not emulate subagents with parallel shell processes. Sequential is slower and correct.

The recommended launcher is `./bin/run-factory.sh`: it starts the gateway, then walks the
harness tiers, resuming the run on each advance. `bin/run-claude.sh` and `bin/run-codex.sh`
still launch a single harness directly. On the local model tier, force single-context mode
regardless of harness — `playbook/00-kickoff.md` says why.

## Rules that hold on every harness

The secret rules and "never weaken a test" are above the router, because they bind in both
jobs. These are run-mode only.

- Provisioning spend is capped by a ledger, not by an assertion. Create free-tier or
  zero-commitment resources freely; anything with a fixed monthly price needs its price plus
  the `PROVISIONED.md` fixed total to be ≤ `monthly_infra_budget_usd` and a `DECISIONS.md`
  row. Never enable usage-based autoscaling without a provider-side spend cap, never buy a
  domain, never raise a plan tier. Every row carries a teardown command and `teardown.sh`
  destroys them all — full autonomy is acceptable only because it is reversible. Rules in
  `playbook/autonomy-contract.md`.
- A self-reported success never passes a gate. Only `./verify.sh` exiting zero does.
- Cap repairs at three cycles per gate, then record a `BLOCKER` and move on. A fourth
  attempt on the same failure is how an unattended run dies with nothing shipped.
- Three failures are never downgraded to blockers, because shipping them harms real people:
  a secret committed to the repo, an unauthenticated mutating route, and a billing
  double-charge. If one cannot be fixed, enable the kill switch and ship disabled with the
  blocker at the top of `HANDOFF.md`.
- Honour the budget ladder in `playbook/autonomy-contract.md`. Past 80%, stop feature work
  and spend the remainder on deploy, verify, and handoff.
- A failed model request is not a question and not a reason to stop. It fails over down the
  chain — harness retries, then the `gateway/providers.conf` chain ending local, then
  `bin/run-factory.sh`'s tier advance, which resumes rather than restarts — and the failover
  gets a `DECISIONS.md` row plus the achieved model tier in `HANDOFF.md`. Ladder in
  `playbook/autonomy-contract.md`, "Model availability".
- One exception: a policy or safety refusal is never re-routed to another model. Re-rolling a
  refusal to get a different answer is laundering, not failover. It stops the run.

## Artifacts to produce

In the generated product repo: `CAPABILITIES.md`, `PRODUCT-SPEC.md`, `DECISIONS.md`,
`PROVISIONED.md`, `HANDOFF.md`, `RUNBOOK.md`, `verify.sh`, `teardown.sh`.

`CAPABILITIES.md` is Phase 1's only deliverable and the contract every later phase reads.
Nothing downstream may assume a capability absent from it.

`HANDOFF.md`'s first line states the achieved outcome tier — L, T, or D, defined in
`playbook/00-kickoff.md`. Without it, nobody can tell a launch from a local container.
