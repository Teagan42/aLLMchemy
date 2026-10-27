# aLLMchemy : Autonomous Micro-SaaS Factory

A handoff package. One human fills one questionnaire. An agent then devises, designs a
product, builds it, deploys it to a public URL, wires it to the billing provider (test mode
by default, live with `go_live: true`), tests it against that URL, and hands back a running
business. The agent never asks a question.

What "running" means depends on the credentials supplied: three outcome tiers, L, T and D,
defined in the table further down and in `playbook/00-kickoff.md`. Tier T — a public URL
with billing in test mode — is the default and a success.

Runs on **Claude Code** or **Codex**. The content is platform-neutral; each harness gets a
thin adapter.

## The one human step

1. Copy `intake.example.yaml` to `intake.yaml`. Edit or don't — **every field has a
   default, and a blank form is a valid submission.** See `QUESTIONNAIRE.md`.
2. Put provider credentials in `.env.intake` (template in `QUESTIONNAIRE.md`).
   Credentials never go in `intake.yaml` and never go in chat.
3. Launch:

```sh
./bin/run-factory.sh    # recommended: gateway + harness tiers, resumes on failover
./bin/run-claude.sh     # Claude Code only
./bin/run-codex.sh      # Codex only
```

`run-factory.sh` is the default because it survives a dead model: it brings up the fallback
gateway, runs the harness through it, and advances to the next tier — ending at a local model
— if the current one stops answering. The single-harness launchers remain valid and are the
right choice when you are watching the run.

All of them default to full autonomy, because an approval prompt is a human interaction by
another name and will hang an unattended run. Override with `CLAUDE_FLAGS` or `CODEX_FLAGS`.

Spend is therefore bounded by policy rather than by prompts: the run may create free-tier
resources freely, must fit any fixed monthly price under `monthly_infra_budget_usd`, logs
every created resource to `PROVISIONED.md`, and ships a `teardown.sh` that destroys all of
them. Rules in `playbook/autonomy-contract.md`.

## Layout

Content lives once, under `playbook/`. Everything under `.claude/` and `codex/` is a
pointer or a setting — nothing to keep in sync.

```
AGENTS.md                   Root instructions. Codex reads this automatically
CLAUDE.md                   Points at AGENTS.md, adds Claude Code specifics
QUESTIONNAIRE.md            The form, field semantics, credential template
intake.schema.json          Schema with defaults (blank form is valid)
intake.example.yaml         Copy to intake.yaml

playbook/                   PLATFORM-NEUTRAL. The authoritative content
  00-kickoff.md             Phase sequence, gates, execution modes
  autonomy-contract.md      Decision ladder, blockers, secrets, budget
  product-selection.md      Hard gates, scorecard, unit economics, archetypes
  subscription-billing.md   Provider port, entitlements, webhooks, test matrix
  deploy-pipeline.md        Preflight, fallback tiers, release, rollback
  acceptance-gates.md       Nine gates as executable checks
  addon-design.md           Stretch goal: entitlements, add-ons, annual plan
  roles/*.md                The seven role briefs

template/                   RUNNABLE SCAFFOLD. Copied into the generated repo, then extended
  README.md                 What to copy, what to extend, what not to rewrite
  verify.sh                 The gate runner implementing the documented contract
  gates/*.sh                The nine acceptance gates, one script each
  preflight.sh              Credential probe emitting OK / FAIL / ABSENT per provider
  secret-scan.sh            Working tree plus full history; exit 0 clean, 1 on a hit
  teardown.sh               Destroys every PROVISIONED.md row; --dry-run enumerates them
  billing-core/             Zero-dependency entitlement and webhook reference, `node --test`

bin/                        SHARED TOOLING
  question-patterns.txt     The interrogative patterns, edited here only
  detect-question.sh        stdin -> exit 0 if it interrogates the user
  test-detect-question.sh   Regression suite; run after editing patterns
  validate-intake.mjs       intake.yaml vs intake.schema.json; Phase 0's first step
  run-claude.sh             Launcher
  run-codex.sh              Launcher + question-retry loop
  run-factory.sh            Supervisor: gateway up, then harness tiers, resuming on failure
  test-failover.sh          Induces each failure class and asserts the chain holds

gateway/                    MODEL FAILOVER. Ephemeral LiteLLM proxy; nothing installed globally
  README.md                 The chain, the env, what is deliberately not failed over
  providers.conf            Provider registry; FACTORY_MODEL_CHAIN orders it
  up.sh                     Starts the proxy via uvx and waits for it to answer
  down.sh                   Stops it
  env.sh                    Exports the harness vars that point at the proxy
  probe.sh                  One request per tier; proves the chain before a run starts

.claude/                    CLAUDE CODE ADAPTER
  settings.json             Permission denials, hook wiring, tool allowlist
  hooks/no-questions.sh     Stop + SubagentStop hook; transport only, calls detect-question.sh
  hooks/on-api-failure.sh   StopFailure hook; writes the typed error class as a breadcrumb
  skills/*/SKILL.md         Six pointers to playbook docs
  agents/*.md               Seven pointers to playbook/roles

codex/config.toml           CODEX ADAPTER. Optional; merge into ~/.codex/config.toml
```

## Why it cannot ask questions

The operator is gone, so a question is a permanent hang rather than a delay. Three
independent layers, because instructions alone are not enforcement:

| Layer | Claude Code | Codex |
|---|---|---|
| Policy | `playbook/autonomy-contract.md` decision ladder | same |
| Permission | `AskUserQuestion` and `ExitPlanMode` denied in `settings.json` | `approval_policy = "never"` / CLI flags |
| Runtime | `Stop` and `SubagentStop` hooks block an interrogative final message | wrapper re-prompts on an interrogative turn |

Both runtime layers call the same `bin/detect-question.sh` against the same
`bin/question-patterns.txt`, so the rule cannot drift between harnesses.

An unresolved ambiguity is not a question. It is a row in `DECISIONS.md` and a chosen
default. A hard external blocker is not a question either. It is a `BLOCKER` entry in
`HANDOFF.md` plus the remaining scope delivered anyway.

### Runtime layer limits

It is a heuristic over the final message, tuned in two directions. It strips fenced code,
quoted spans, and markdown table rows before matching, because legitimate reports quote
example questions and print the `DECISIONS.md` "question that went unasked" column —
matching those would block correct closing messages. It also releases after three
consecutive blocks per session, per hook event, per agent, so a pattern bug cannot deadlock
the run it protects — and a clean stop re-arms the budget, so one false positive cannot
disarm the guard for the rest of the run.

Consequence: it catches the common phrasings, not every possible one. It is the third layer
precisely because it is the weakest; the policy and permission layers do the real work. Run
`./bin/test-detect-question.sh` after editing any pattern.

## Why it survives a dead model

Same idea as above, applied to the other way an unattended run hangs. A question hangs
because nobody answers; a failed model request hangs because nothing retries. This one has
already happened: an expired AWS SSO token took out nine parallel agents mid-run, all with
"Could not load AWS credentials", and the run produced nothing. Three layers again:

| Layer | What it does | Where |
|---|---|---|
| Policy | Model unavailability is a ladder, not a stop: retry, fail over, advance tier, then `BLOCKER` | `playbook/autonomy-contract.md`, "Model availability" |
| Gateway | Per-request ordered fallback down the model chain, ending at a local model. Covers auth, quota, network, 5xx, timeout, malformed, unknown | `gateway/providers.conf`, `gateway/up.sh` |
| Supervisor | Per-run tier advance when a whole chain or the harness itself dies; resumes the session rather than restarting it | `bin/run-factory.sh` |

The gateway is required because a harness cannot do this alone. Claude Code retries ten times
with backoff and has a `fallbackModel` chain, but that chain is same-provider only — it cannot
reach a local model. An expired credential or a dead provider exhausts it.

**One failure class is deliberately never failed over: a policy or safety refusal.**
Re-rolling a refusal on a different model until one complies is laundering, not failover, so
LiteLLM's `content_policy_fallbacks` is left unset and a refusal stops the run.

### What the local tier actually costs you

It is honest degradation, not a free safety net. Local inference runs at 25–27 tokens/second
against hundreds on a hosted frontier model, and it is sequential only — parallel agents
thrash Ollama's single KV cache slot and erase the prefix caching that makes it practical at
all, so Phases 4 and 5 stop overlapping. The product that comes out is materially weaker:
simpler code, thinner tests, less careful copy.

It exists so a run finishes and hands off instead of dying in Phase 3 with an empty repo. A
handed-off Tier T product you can read, judge and re-run is worth more than nothing. The
achieved model tier is on `HANDOFF.md`'s first line precisely so the operator can re-run the
build on a cloud model afterwards — with `DECISIONS.md` and `PRODUCT-SPEC.md` already
written. Set `model_chain: cloud` to refuse the trade and take a blocker instead.

## Harness differences that matter

**Codex has no subagents.** `playbook/00-kickoff.md` carries an execution-mode section: a
delegating harness dispatches each role as a subagent and runs Phases 4 and 5 concurrently;
a single-context harness adopts each role in sequence. The phase sequence and gates are
identical either way — only dispatch changes. Emulating subagents with background shell
processes is explicitly ruled out.

**Codex flag names move between versions.** `bin/run-codex.sh` takes `CODEX_BIN` and
`CODEX_FLAGS` overrides and probes for `exec resume` before using it. If a flag is
rejected, check `codex exec --help`; don't edit the script.

**Claude Code skills auto-load by description; Codex has none.** So every cross-reference in
the playbook is a literal path (`playbook/deploy-pipeline.md`, not `deploy-pipeline`), which
both harnesses can follow without a discovery mechanism.

## What "done" means

Credentials decide which of three outcomes is reachable, so success is defined per tier in
`playbook/00-kickoff.md` and `HANDOFF.md` states the achieved tier in its first line, with
the model tier that produced it beside it.

| Tier | Outcome | Requires |
|---|---|---|
| **L** — live launch | Public URL, provider LIVE mode, real cards accepted | `go_live: true`, live keys that validate, hosting credentials |
| **T** — test-mode launch | Public URL, provider test mode, test cards complete the flow. The default, and a success | Hosting credentials |
| **D** — degraded artifact | Docker artifact verified against a local container. **Not done** — always a `BLOCKER` | Nothing |

## Artifacts the run produces

In the generated product repo: `CAPABILITIES.md` (what preflight proved is actually usable —
Phase 1's only output and the contract every later phase reads), `PRODUCT-SPEC.md` (the
invented product, scorecard, rejected candidates, unit economics), `DECISIONS.md` (every
assumption made in place of a question, with the rule that chose it), `PROVISIONED.md`
(every resource created, its fixed monthly price, its usage-risk ceiling, and its teardown
command), `HANDOFF.md` (achieved tier on the first line, live URL, credentials, cost model,
blockers), `RUNBOOK.md`, `verify.sh`, and `teardown.sh` (destroys everything the run
created, in one command).

## Scope boundary

The package does not pick the product. The rubric does, deterministically, from the
operator's `product_direction` hint or from nothing. `playbook/product-selection.md` shows
what can clear the gates — watchers, digests, expiry trackers — and why marketplaces,
social apps, and bare LLM wrappers cannot.
