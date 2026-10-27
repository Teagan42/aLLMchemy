# Orchestration: build a durable-execution core, or adopt an engine?

Resolves [#2](https://github.com/Teagan42/aLLMchemy/issues/2). Feeds
[#5](https://github.com/Teagan42/aLLMchemy/issues/5) (language) and
[#6](https://github.com/Teagan42/aLLMchemy/issues/6).

**Recommendation: build a small custom core; spike DBOS Transact over SQLite first to try to falsify that.**
Jump to [Recommendation](#recommendation), [What we lose](#what-we-lose),
[Per-language availability](#per-language-availability).

## Confidence markers

Same scheme as [`harness-integration.md`](harness-integration.md).

- **verified** — observed directly: a run on this machine, the shipped artifact, or first-party source read.
- **documented** — stated in first-party documentation; not exercised here.
- **unverified** — documentation silent, ambiguous, or contradicted by observation. An unverified row is not a
  finding; it is a gap.

Nothing below is inferred to fill a gap.

## The question

Does an existing workflow or durable-execution engine supply crash-safe resume, retry policy, timers and
cancellation for materially less code than aLLMchemy would write, given a workload of tens of coarse,
hours-long, non-replayable agent invocations on one operator's machine?

## Requirements as filters

Firm as of this ticket. Not open questions.

| # | Filter | Source |
|---|---|---|
| F1 | No daemon or server the operator must provision. One config document, walk away. | map constraint 5 |
| F2 | Graph dynamically extensible at runtime; repair inserts steps into a running workflow. Fixed-topology DAG engines are disqualified. | map constraint 23 |
| F3 | Steps are **not replayable**. One step is a coding-agent invocation: minutes to hours, dozens of files written, many external API calls. | map constraints 13, 14 |
| F4 | Resume is driven by per-step completion predicates, not by replay. The journal corroborates; it is not the sole authority. | map constraint 9 |
| F5 | Tens of coarse steps per run. Runs last hours to days and survive process restarts. | ticket |
| F6 | Per-run self-contained state — journal, artifacts, evidence in the run's own workspace — plus a thin global registry. | map constraint 20 |
| F7 | Versioned event envelopes; a run started on one build may resume on a later one. Unrecognised event refuses resume. | map constraint 24 |
| F8 | Concurrency decided by the engine at runtime from the active model tier, not fixed in the graph. | ticket |
| F9 | Available in the candidate language set: Python and Go lead; Rust and TypeScript admissible. | map constraint 4 |

F3 is the sharpest filter. Ask of every candidate: what does its programming model demand of a long,
non-deterministic, side-effecting step?

## Candidate set

| Candidate | Shape | Languages | Fate |
|---|---|---|---|
| **DBOS Transact** | library, embedded, SQLite or Postgres | Python, Go, TS, Java | **survives all filters** |
| **Temporal** | client + server (dev server exists) | Go, Python, TS, Java, .NET, Ruby, PHP | pruned on F1 |
| **Restate** | client + `restate-server` + inbound HTTP registration | TS, Python, Go, Java/Kotlin, Rust | pruned on F1 (hard) |
| **go-workflows** (`cschleiden/go-workflows`) | library, embedded, SQLite | Go only | survives F1; weak on F9, maturity |
| **Durable Task Framework for Go** (`dapr/durabletask-go`) | library, embedded, SQLite | Go (Python/Java via sidecar) | survives F1; see assessment |
| **Resonate** | library + optional server | Python, TS | immature; see assessment |
| **LangGraph** (checkpointers) | library, embedded SQLite | Python, TS | prior art, not an engine candidate |
| Airflow, Dagster, Prefect, Flyte, Argo, Windmill, n8n, Kestra | server + (mostly) DAG | — | pruned on F1 and F2 |
| Inngest, Hatchet, Trigger.dev, Cloudflare Workflows, Golem, Azure Durable Functions | hosted or sidecar service | — | pruned on F1 |
| Celery, RQ, Sidekiq, APScheduler, Asynq, River, Oban | task queues, not durable execution | — | pruned: no workflow-level resume |
| Dapr Workflow | sidecar process | polyglot | pruned on F1 (sidecar is a daemon) |

### What each filter pruned

- **F1 (no daemon)** is the single most destructive filter. It removes every server-backed engine in one pass:
  Airflow, Dagster, Prefect's server mode, Flyte, Argo, Windmill, n8n, Kestra, Hatchet, Inngest, Trigger.dev,
  Dapr, Restate, and Temporal. "Supply one config document and walk away" cannot survive `docker compose up` as
  step zero.
- **F2 (dynamic extension)** removes the DAG-declaration engines independently of F1 — Airflow, Argo, Flyte and
  Kestra want the topology before the run starts. It does *not* prune any code-as-workflow engine: when the
  workflow is a function, inserting a step is just calling one more function.
- **F3 (non-replayable steps)** does not prune anything outright, but it demotes the value of every
  replay-based engine. See the discussion below — it is the reason this ticket's answer is not simply "adopt
  DBOS and move on".
- **Task queues** fail a requirement so basic it is easy to skip: Celery, RQ, Asynq, River and friends give
  durable *tasks*, not durable *workflows*. Nothing resumes a half-finished multi-step run; that logic would be
  ours anyway.

## The F3 problem, stated precisely

Every engine in the surviving set uses the same mechanism: **the workflow function is replayed, and completed
steps return checkpointed results instead of re-executing.** The consequence nobody advertises is what happens
to the step that was *in flight* when the process died.

- Temporal: "The Temporal Server doesn't detect failures when a Worker loses communication with the Server or
  crashes. Therefore, the Temporal Server relies on the Start-To-Close Timeout to force Activity retries." The
  retry is a fresh Activity Task Execution from the top of the function. Heartbeat payloads are the only
  resume mechanism and are explicitly best-effort — progress survives "provided that the Worker itself did not
  crash before delivering it to the Temporal Service."
  (<https://docs.temporal.io/encyclopedia/detecting-activity-failures>)
- DBOS: steps are "tried _at least once_ but are never re-executed after they complete," and a step "should be
  **idempotent**, meaning it should be safe to retry them multiple times."
  (<https://docs.dbos.dev/architecture>, <https://docs.dbos.dev/python/tutorials/workflow-tutorial>)
- go-workflows: activities "will be executed only once and the result is persisted" — the once-ness is of the
  *recorded result*, not of the side effects of a crashed attempt.
  (<https://github.com/cschleiden/go-workflows>)

**So: no engine in the set resumes a crashed step. Every one of them re-runs it from the top and tells us to
make it idempotent.** For aLLMchemy that re-run is a fresh coding-agent invocation costing minutes to hours
and real money, over a workspace the dead attempt already half-mutated.

This is the central finding, and it cuts both ways:

1. **Against adoption.** The work F3 creates — deciding whether a step already happened, and making the
   re-entry safe — is not work any candidate does for us. Map constraint 9 (completion predicates) exists
   precisely because this problem is ours regardless. No engine's replay log substitutes for it.
2. **For adoption.** F3 therefore does not *disqualify* anything. It just means the predicate layer is a
   constant cost across all options, and the comparison reduces to everything *else* an engine supplies:
   journal, recovery scan, retry policy, durable timers, cancellation, queues, concurrency limits, status
   query. Those are real and we would otherwise write them.

The matching design pattern, in any of these engines, is: a thin **step wrapper** that evaluates the
completion predicate before doing work and returns early if it is already satisfied. That wrapper makes the
engine's at-least-once step semantics safe without asking the engine for anything it cannot give.

### F2 and replay are reconcilable — via a driver loop

A dynamically extensible graph looks incompatible with replay-determinism, but is not. Express the run as a
driver loop whose next move is itself a checkpointed step:

```
for {
    next := step(PlanNextStep)   // reads journal + gate outcomes; result is checkpointed
    if next == nil { break }
    step(Execute, next)          // predicate-guarded; may be a repair step inserted this iteration
}
```

Control flow is then a pure function of recorded step results, so replay is deterministic even though the
topology was not known when the run started. DBOS states the requirement in exactly this form: a workflow
"should invoke the same steps with the same inputs in the same order (**given the same return values from
those steps**)." (<https://docs.dbos.dev/python/tutorials/workflow-tutorial>)

**Unverified:** that DBOS's step-identity scheme tolerates this loop over an arbitrary number of iterations
with heterogeneous step functions. Not exercised here. It is the single highest-value thing to prototype
before committing to adoption.

## Per-candidate assessment

### DBOS Transact — the serious contender

Library, in-process, no orchestration server: "There's no separate orchestration server and no infrastructure
required besides Postgres." (<https://docs.dbos.dev/architecture>) And — the finding that changes this
ticket — **Postgres is not actually required.**

**SQLite is a first-class system database in both leading languages.**

| | Evidence | Confidence |
|---|---|---|
| Python | `system_database_url` accepts `sqlite:///[path]`. SQLite is the *default*: "If no connection string is provided, DBOS uses a SQLite database" named `sqlite:///[application_name].sqlite`. (<https://docs.dbos.dev/python/reference/configuration>) | documented |
| Go | `dbos.Config` doc comment: "Accepts Postgres URLs ... and sqlite URLs (`sqlite:/path/to.db`, `sqlite:relative.db`, or `sqlite::memory:`)", plus a `SQLiteSystemDB *sql.DB` field for a caller-supplied handle; opt-in via `import _ ".../dbos/driver/sqlite"`. `go.mod` carries `modernc.org/sqlite v1.54.0` as a direct dependency. | verified (source read) |

`modernc.org/sqlite` is the pure-Go, cgo-free driver, so the Go path stays **one static binary with an
embedded SQLite journal and no daemon**. That is precisely the artifact the custom prior was reaching for.

Versions seen: `dbos` 3.3.0 on PyPI (`>=3.10`, with an `aiosqlite` extra); `dbos-transact-golang` at
`2026-10-24`, 862 stars.

**Against the filters:**

| Filter | Verdict |
|---|---|
| F1 no daemon | **Pass.** Library in our process; SQLite file. |
| F2 dynamic extension | **Pass**, via the driver loop. The workflow is ordinary code, so step insertion is a function call. Needs the prototype named above. |
| F3 non-replayable steps | **Neutral.** Predicate wrapper required, as with every candidate. DBOS at least states the contract plainly rather than hiding it. |
| F4 predicate-driven resume | **Tolerates it.** DBOS's checkpoint and our predicate can both run; the predicate wrapper inside the step is the seam. DBOS does not fight it, but neither does it know about it. |
| F5 tens of coarse steps, hours-to-days | **Comfortable.** Benchmarks cited at ">40K workflows or steps per second" — four orders of magnitude of headroom. Durable timeouts are persisted and "permitting very long values." |
| F6 per-run self-contained state | **Partial fail.** DBOS's system database is per *application*, not per *run*. Per-run isolation means one SQLite file per run, i.e. one DBOS context per run — unexercised, and it fights the global-registry split. See "what we lose". |
| F7 versioned envelopes, cross-build resume | **Conflict, mitigable.** DBOS "only recovers workflows whose version matches the current application version," and version is "automatically computed from a hash of workflow source code." (<https://docs.dbos.dev/python/tutorials/upgrading-workflows>) Verified in Go source: `ReenqueueForRecovery(ctx, executorIDs, ctx.applicationVersion, ...)`. **Default behaviour is the opposite of F7**: a run started on build N is silently not recovered by build N+1. Mitigation is to pin `ApplicationVersion` (Go honours `DBOS__APPVERSION`; `EnablePatching` pins it to the literal `PATCHING_ENABLED`) and use `DBOS.patch()` for divergent code paths. That moves envelope compatibility back to us — which F7 wanted anyway — but it means we are *overriding* the engine's safety default, not using it. |
| F8 runtime-decided concurrency | **Likely pass, unverified.** DBOS queues carry concurrency limits; whether a limit can be changed for a live queue mid-run was not established. |
| F9 language availability | **Pass, and it is the only candidate that passes in both leading languages.** |

**What DBOS actually supplies that we would otherwise write:** step checkpointing, a recovery scan on startup
("DBOS scans for incomplete (PENDING) workflows"), configurable step retries, durable `sleep` that survives
restarts ("saves the wakeup time in the database"), durable start-to-completion timeouts that cancel a
workflow "and all its children" and preempt "at the beginning of its next step", workflow IDs as idempotency
keys with a reuse policy, queues with flow control, a debouncer, scheduled workflows, and programmatic
listing/cancel/resume/fork.

**Costs and irritants:**

- SQLite has no `LISTEN/NOTIFY`, so DBOS falls back to polling: `use_listen_notify` is "Ignored in SQLite,
  which always uses polling", default interval 1.0s. Irrelevant at our step granularity.
- Docs say "Postgres is recommended for production." We would be running the configuration its authors call
  second-best. For a single-operator local tool with tens of steps per run, that is an acceptable trade — but
  it is a real statement to put in an ADR.
- Enterprise/entitlement machinery exists in the Go tree (`enterprise.go`, `entitlements.go`). **Unverified:**
  which features, if any, are gated. Licence on the Go repo is MIT.
- A DBOS workflow that throws an uncaught exception is *not* recovered — "such exceptions are assumed to be
  nonrecoverable." Our repair cycle must therefore never surface as an exception escaping the workflow
  function.

### Temporal — pruned on F1, and its core value is irrelevant to us anyway

There is a genuine embedded-ish mode: `temporal server start-dev` runs a full server locally and, with
`--db-filename`, persists to SQLite (`--sqlite-pragma` tunes it). Without that flag, "Workflow Executions
don't survive the server process ending."

It is disqualified regardless, on two independent grounds:

1. **First-party documentation tells us not to ship it.** The dev server prints "WARNING: The development
   server is not intended for production use," because "It skips certain HTTP security checks to make local
   use simpler," and points readers at the production deployment docs.
   (<https://docs.temporal.io/cli/server>) Building an operator-facing product on a mode its vendor labels
   non-production is a support burden we would own forever.
2. **It is still a server.** A process to supervise, ports 7233/8233 to bind, a lifecycle to manage against
   concurrent runs on one machine. F1 is violated even if the warning did not exist.

And the thing we would be paying that cost for does not help us. Temporal's value is deterministic replay of
workflow code, with Activities as the non-deterministic escape hatch — "Activities execute outside the replay
path and are automatically retried."
(<https://docs.temporal.io/workflow-definition>) But our step *is* the Activity, and Temporal's Activity model
is actively hostile to a multi-hour agent invocation:

- An Activity must declare `StartToClose` or `ScheduleToClose`; "set neither and the Temporal Service rejects
  the Activity." So we must predict a worst-case duration for an open-ended coding-agent run.
- A multi-hour `StartToClose` means crash detection takes hours, so Temporal recommends "a relatively short
  Heartbeat Timeout and a frequent Heartbeat" — meaning the engine must thread a heartbeat into a subprocess
  whose progress it only sees as a token stream.
- "Activities that don't Heartbeat can't receive a Cancellation." Cancellation, one of the three primitives we
  are shopping for, is gated on implementing heartbeats correctly.
- Crash mid-Activity re-runs it from the top. Heartbeat checkpoint payloads are best-effort and are throttled
  (default 30s/60s intervals), so the last in-memory heartbeat may never have been sent.

Verdict: Temporal is the right tool for a fleet of short deterministic activities behind an operated control
plane. For one operator, tens of hours-long agent steps, and no daemon, we would pay its entire operational
cost to receive a programming model that fights the workload.

### Restate — the hardest fail on F1

Restate is attractive on paper: "a single self-contained binary. No external dependencies needed."
(<https://docs.restate.dev/develop/local_dev>) But it fails F1 more severely than Temporal, because of
**control inversion**: Restate is not a library we call, it is a server that calls us. Services must be
registered — `restate deployments register localhost:9080` — and the server reaches our code "over HTTP at an
address like `localhost:9080`, not loaded in-process." There is no embedded or library-only mode documented.

So standing up aLLMchemy would mean: start `restate-server` (or `restate up`), expose an HTTP endpoint from
the engine, register the deployment, and keep the server's own state store alive alongside the per-run
workspaces. That is three daemon-shaped obligations where F6 asked for a file in a directory. It also
re-opens the trust-boundary work settled in #7: an inbound HTTP listener is a new attack surface on the
operator's machine.

Secondary note: the server "collects anonymized telemetry about versions and uptime" unless `DO_NOT_TRACK=1`
is set. For a local-first single-operator tool, shipping a dependency that phones home by default is a
decision we would have to make on the operator's behalf.

`restate-sdk` 1.1.0 is on PyPI and there is a Go SDK, so F9 is satisfied. F1 is not, and F1 is firm.

### go-workflows — the credible Go-only library

`cschleiden/go-workflows`, 531 stars, last pushed 2026-08-11. Explicitly "Embedded durable workflows for
Golang similar to DTFx/Cadence/Temporal". Backends: in-memory ("for testing"), SQLite, MySQL, Postgres,
Redis; the SQLite backend is one call — `sqlite.NewSqliteBackend("simple.sqlite")`. Worker and client can live
in one process: "We can start workflows from the same process the worker runs in -- or they can be separate."
Programming model is Temporal's, minus the server: deterministic workflow code plus activities that "can have
side-effects and don't have to be deterministic."

Determinism constraint is stricter and more Go-specific than DBOS's: workflows "must not use any of Go's
non-deterministic features (`select`, iteration over a `map`, etc.)". That is a real authoring hazard — map
iteration is the kind of thing a maintainer adds without thinking.

**Pruned, but on judgement rather than a filter.** It passes F1, F2 and F9-for-Go. Against DBOS it loses on:
one maintainer and a one-order-of-magnitude smaller user base; no Python path, so adopting it would *decide*
issue #5 rather than inform it; and the README does not document timers, retries, cancellation, signals or
sub-workflows — they likely exist (the project cites DTFx/Temporal as inspirations) but that is an inference,
**unverified**. Keep it as the fallback if the Go language decision lands and DBOS Go's SQLite path disappoints
in prototype.

### Durable Task Framework for Go — pruned on project posture

`dapr/durabletask-go`, the engine behind Dapr Workflow, has an embeddable SQLite backend and the DTFx
programming model. Two problems: it is now maintained as **Dapr's** engine, so its roadmap serves a
sidecar-based distributed runtime whose needs are the opposite of ours; and the Go repo itself shows 17 stars
under the `dapr` org, i.e. the community is around Dapr, not around library-mode use. The Python and Java
SDKs talk gRPC to a sidecar, so F1 fails outside Go. **Unverified:** whether the library-mode SQLite backend
is covered by any stability guarantee.

### Resonate — too early

`resonatehq/resonate`, 689 stars, actively developed. The "distributed async await" model (durable promises)
is a genuinely different and appealing shape. Python SDK `resonate-sdk` 0.8.1 requires `>=3.12` and is
pre-1.0; no Go SDK was found. **Unverified:** whether its local mode is durable without the Resonate server.
Pre-1.0 with no Go story cannot carry a foundational decision that also feeds the language choice. Revisit
later.

### LangGraph and the DAG/agent-framework tier

Not an engine candidate — it is an agent framework whose orchestration is incidental — but it is the closest
prior art, and the next section treats it as such.

## Prior art: durable agent orchestration

Someone has hit our non-determinism problem. Several people have. What they built tells us two useful things.

**The industry answer is "put the agent call in a durable step", and it is near-unanimous.** Temporal's Python
SDK ships first-party contrib integrations for `openai_agents`, `langgraph`, `google_adk_agents`, `deepagents`,
`strands` and `google_genai` (verified: directory listing of `temporalio/contrib` in `temporalio/sdk-python`).
The OpenAI Agents integration has since graduated to its own package, `temporalio-openai-agents`. That is a
lot of first-party investment in exactly our architecture, and it is a strong signal that coarse-step durable
execution over agent invocations is the right *shape*.

**But every one of them confirms the F3 limitation in its own words, and none solves it.**

Temporal's own AI-integration README is the clearest statement of the problem we have found anywhere:

> "Activity code faces no restrictions on I/O or external interactions, but if it fails part-way through it
> restarts from the beginning."
>
> — <https://github.com/temporalio/ai-integrations/tree/main/python/openai_agents#readme>

And its division of labour:

> "In this integration, model invocations are automatically routed through Temporal activities, while the logic
> that coordinates them lives in the workflow."

**The granularity gap is the point.** Temporal's agent integration makes the *model call* the activity — a
request lasting seconds, genuinely safe to retry from the top. aLLMchemy's step is a whole bounded harness
session lasting minutes to hours, which is not. All this prior art lives one or two orders of magnitude below
our step size, so it does not transfer. Nobody in this set has solved "resume a three-hour agent session that
already wrote forty files".

**LangGraph** is the closest to our persistence model and is worth reading as a design, not a dependency. It
checkpoints at super-step boundaries and additionally persists per-node writes, which buys partial recovery
within a parallel super-step:

> "When a graph node fails mid-execution at a given super-step, LangGraph stores pending checkpoint writes from
> any other nodes that completed successfully at that super-step. When you resume graph execution from that
> super-step you don't re-run the successful nodes."

But for the node that actually failed, the answer is the same as everyone else's:

> "Nodes after the checkpoint re-execute, including any LLM calls, API requests, or interrupts — which are
> always re-triggered during replay."

Its three durability modes are a genuinely good piece of API design worth copying the *vocabulary* of —
`"exit"` (no mid-execution recovery), `"async"` ("a small risk that LangGraph does not write checkpoints if
the process crashes"), `"sync"` ("persists changes synchronously before the next step starts"). aLLMchemy
needs only `sync`, at tens of steps per run, so the knob is not even needed — but naming the trade-off
explicitly is better than leaving it implicit.
(<https://docs.langchain.com/oss/python/langgraph/checkpointers.md>)

Two reasons LangGraph is not a candidate: its own docs class the SQLite path as `SqliteSaver`, "Local
file-based storage for development", with Postgres or the hosted Agent Server as the production answer; and
adopting it would import an entire agent framework to get a checkpointer, when aLLMchemy's agents are external
harness subprocesses (map constraint 14) that LangGraph has no role in driving.

**Conclusion from prior art.** The architecture is validated and the hard part is confirmed unsolved. Nobody
ships predicate-driven resume. That primitive is ours to build under every option on the table.

## Cost of the custom option

Estimates are for one engineer, including tests, to a standard worth trusting with a multi-day run. LOC is
production code; test code runs 1.5-2x that for the resume layer specifically, because the only way to trust
it is crash injection at every write point.

### 1. Crash-safe resume — the expensive one

| Part | LOC | Notes |
|---|---|---|
| Versioned event envelope, codec, forward migration, refuse-on-unknown (F7) | 300-500 | Map constraint 24 names this; no candidate supplies it in the form we want |
| SQLite journal store: append, WAL, fsync discipline, single-writer discipline, torn-write detection | 400-600 | Where naive implementations rot |
| Projection from events to run state (`DECISIONS.md`, `PROVISIONED.md`, `CAPABILITIES.md` per constraint 12) | 300-500 | Needed whether or not an engine is adopted — these are our projections, not an engine's |
| Recovery: registry scan, journal load, predicate re-evaluation, reconcile | 250-400 | The predicate half is ours under every option |
| **Subtotal** | **1250-2000** | **3-5 weeks** |

Failure mode if done badly is silent: a run resumes into an inconsistent state weeks later. This is the part
of the estimate most likely to be optimistic, and the part an engine most plausibly replaces.

### 2. Retry and backoff policy — much cheaper than it looks here

| Part | LOC | Notes |
|---|---|---|
| Per-step retry policy: attempt caps, classified-failure dispositions, backoff, jitter | 200-400 | |
| **Subtotal** | **200-400** | **3-5 days** |

**This is not a reason to adopt an engine, because #11 already gave the retry ladder away.** The gateway owns
protocol translation, failure classification and "the whole retry ladder", with no cooldowns ever. Model-layer
retry is therefore already built elsewhere by decision. What remains at the step layer is a thin attempt cap
plus the three-repair-cycle liveness guard (constraint 19). An engine's retry policy would sit in the wrong
place and partly duplicate the gateway.

### 3. Timers and cancellation — split sharply in two

| Part | LOC | Notes |
|---|---|---|
| Durable timers: persisted wake times, deadline enforcement surviving restart | 200-300 | **An engine does supply this.** DBOS: `Sleep` is a "Durable sleep that survives workflow recovery" (verified in Go source) |
| Cooperative cancellation at step boundaries | 150-250 | **An engine supplies this too.** DBOS preempts "at the beginning of its next step" |
| **Process-group and container teardown, orphan reaping after engine crash** | **250-400** | **No engine supplies this, at all** |
| **Subtotal** | **600-950** | **2-3 weeks** |

The third row is the one that matters and it is worth being blunt about. Cancelling an aLLMchemy step means
killing a containerised harness subprocess and reaping what it left behind. DBOS cancelling "at the beginning
of its next step" and Temporal requiring heartbeats before an Activity "can receive a Cancellation" both
describe cooperative cancellation of *in-process* work. Neither kills a container. And per #22, Codex "handles
SIGTERM and exits 0", so a cancelled run reports success unless the engine reads the event stream — meaning
even the signal path is ours to get right. Shopping for cancellation from a workflow engine buys the easy half.

### Totals

| | Production LOC | Calendar |
|---|---|---|
| Custom, all three areas | **2050-3350** | **6-9 weeks** |
| Of which an engine plausibly replaces | ~900-1500 | ~3-4 weeks |
| Of which no engine replaces | ~1150-1850 | ~3-5 weeks |

**So the honest answer to "does a library supply this for materially less code" is: it supplies a little under
half, and not the half that is hardest to get right for *our* workload.** The predicate layer, the versioned
envelopes, the projections and the process-level teardown stay ours under every option.

Two caveats against the estimate's optimism, both real:

- LOC is a poor proxy for the *risk* in resume correctness. 1500 lines of crash-safe journal is not 1500 lines
  of CRUD. A mature engine's value is the bugs already found in it, which no LOC comparison captures.
- "6-9 weeks" assumes the design is right first time. It will not be. Budget a revision.

## Recommendation

**Build a small custom event-sourced core over embedded SQLite. Do not adopt a workflow engine. Gate the
decision behind a time-boxed falsification spike on DBOS Transact, and reverse if the spike succeeds.**

Written to become an ADR:

### Context

aLLMchemy must run tens of coarse, hours-long, non-replayable coding-agent steps on one operator's machine,
with no daemon, a runtime-extensible graph, and predicate-driven resume (filters F1-F9 above). Candidates were
Temporal, Restate, DBOS Transact, go-workflows, `dapr/durabletask-go`, Resonate, plus the DAG and task-queue
tiers.

### Decision

Build the core. Specifically, commit to these primitives and no more:

1. **Versioned event envelope** with a codec and forward migration; an unrecognised event refuses resume
   rather than skipping it (constraint 24).
2. **Append-only journal** per run, one SQLite file inside the run's workspace, WAL mode, single writer,
   explicit fsync at step boundaries. Durability is `sync`-equivalent in LangGraph's vocabulary; no other mode
   is offered.
3. **Thin global registry** for listing and resuming runs — run id, workspace path, status, engine build.
   Nothing authoritative lives here (constraint 20).
4. **Completion-predicate evaluation** as the resume authority, with the journal corroborating (constraint 9).
   A step is skipped only when its predicate is satisfied; a journal entry alone is not sufficient.
5. **Driver loop** whose next move is a journalled planning decision, making the graph runtime-extensible by
   construction and repair a journalled step insertion (constraint 23).
6. **Step attempt policy**: attempt cap, backoff with jitter, and the three-repair-cycle liveness guard. Model
   retry stays in the gateway (#11).
7. **Durable timers**: persisted wake times and deadlines that survive restart.
8. **Cancellation** in two layers — a cooperative step-boundary check, and process-group plus container
   teardown with orphan reaping across engine restarts.
9. **Projections** from the journal to `DECISIONS.md`, `PROVISIONED.md` and `CAPABILITIES.md`
   (constraint 12).
10. **Runtime concurrency control**: a step-admission gate reading the active model tier, not a fixed graph
    property (F8).

Nothing else. No generic DAG language, no distributed worker protocol, no signals or queries beyond what the
inspection surface needs, no multi-tenant anything.

### Rationale

- **F1 removes almost everything.** Temporal and Restate both need a process the operator provisions. Temporal
  does have a SQLite-backed dev server, but ships it stamped "not intended for production use"; Restate needs a
  server plus an inbound HTTP registration and has no library mode at all.
- **F3 means no engine's core value reaches us.** Every surviving candidate re-runs a crashed step from the
  top and tells us to make it idempotent. The deciding evidence is Temporal's own words about its agent
  integration: an activity "restarts from the beginning". The predicate layer is unavoidable, and once it
  exists, engine step-memoization is not just redundant — it is **wrong in the exact case constraint 9 exists
  to handle**: a step whose checkpoint survives but whose evidence does not would be skipped, when it must be
  re-run. Keeping the predicate authoritative means bypassing the memoizer, and an engine with its memoizer
  bypassed is a journal with a dependency attached.
- **Retry was already given away.** #11 put the retry ladder in the gateway. The retry policy an engine
  supplies would sit at the wrong layer.
- **Cancellation is a process problem, not a workflow problem.** No candidate kills a container.
- **The surviving custom scope is small and bounded** — ten primitives, roughly 2000-3400 lines, 6-9 weeks —
  and every one of them is required under the adoption path too, minus the journal store.
- **It leaves #5 free.** All ten primitives are equally writable in Python, Go, Rust or TypeScript, so
  orchestration does not constrain the language choice. Adopting go-workflows would have decided #5 by
  accident.

### Alternative, and the spike that would select it

**DBOS Transact over SQLite is a genuinely credible alternative and the recommendation should not be read as
dismissing it.** It is a library, not a server; SQLite is a first-class system database in *both* leading
languages (Python's default; Go verified from source, with the cgo-free `modernc.org/sqlite` driver preserving
the single-static-binary story); it supplies the journal, a startup recovery scan, durable `Sleep`, durable
start-to-completion timeouts, idempotency keys, queues with flow control, and `ForkWorkflow` / `ResumeWorkflow`
/ `CancelWorkflow` / `ListWorkflows` management primitives. SQLite support landed in Go at v0.16.0
(2026-06-01), stabilised by v1.0.0 (2026-07-31), and the library is at v1.7.0 (2026-10-15) — past 1.0 and
actively developed, not a weekend experiment.

Before writing the journal store, spend **3-5 days** trying to falsify this recommendation. Three questions,
each of which flips the decision if it comes back clean:

1. **Does the driver loop survive replay?** A DBOS workflow running `plan_next_step` -> `execute` over 30+
   iterations with heterogeneous step functions, killed and restarted mid-step. Does step identity hold, or
   does it raise `DBOSStepNondeterminismError` / `DBOSUnexpectedStepError`? *(Currently unverified and the
   single highest-value unknown in this document.)*
2. **Can predicate authority be preserved?** Resume by evaluating predicates first and then
   `ForkWorkflow`-ing to the first unsatisfied step. Does that compose, or does it mean we are running our own
   resume anyway?
3. **Can per-run isolation work?** One DBOS context and one SQLite file per run workspace, several runs
   concurrently, each recovering independently (F6).

If all three come back clean, adopt DBOS and delete primitives 2, 7 and the cooperative half of 8 from the
list above — a real saving of roughly 900-1500 lines. **Reversing to DBOS later is cheap; reversing away from
it is not**, which is the asymmetry that puts the spike before the journal store rather than after it.

Rejected alternatives, briefly: **Temporal** (F1, plus a non-production dev server and an Activity model that
demands worst-case duration estimates and heartbeat plumbing for an open-ended agent run); **Restate** (F1 by
control inversion — a server that calls us over HTTP, no library mode, telemetry on by default);
**go-workflows** (passes F1 and F2, but one maintainer, undocumented timer/retry/cancellation surface, and
Go-only, so adopting it decides #5 by side effect — retain as the Go fallback); **durabletask-go** (roadmap now
serves Dapr's sidecar model; F1 fails outside Go); **Resonate** (pre-1.0, Python `>=3.12`, no Go SDK);
**DAG engines** (F1 and F2); **task queues** (no workflow-level resume).

### Consequences

What would make us revisit: the spike above coming back clean; a second operator or a remote worker appearing
(which would reopen F1 and make Temporal's cost make sense); or the journal store exceeding its estimate by
more than half, which would be evidence the estimate was wrong rather than the decision.

## What we lose

Stated plainly, because the recommendation is the one that loses the most.

1. **Battle-testing.** DBOS's SQLite journal has had five months of other people's crashes. Ours will have
   none. No LOC comparison captures that, and it is the strongest single argument against this
   recommendation.
2. **An ecosystem.** No web UI, no `temporal workflow list`, no third-party observability integrations. The
   operator inspection surface (map, Not yet specified) becomes entirely ours, and it is the kind of work that
   gets deferred forever.
3. **Queues and flow control for free.** DBOS queues with concurrency limits map closely onto F8. We are
   writing an admission gate instead.
4. **A reviewed concurrency model.** `modernc.org/sqlite` plus DBOS's polling loop is a combination its authors
   have tested under load. Our single-writer discipline will be ours to prove.
5. **Debouncing, scheduled workflows, workflow fork, programmatic management.** DBOS ships all of these. We
   will want at least `fork` eventually — resuming a run from an earlier step is an obvious operator request —
   and we will write it ourselves.
6. **The reviewed-dependency argument.** "We wrote our own durable execution core" is a sentence that invites
   scepticism, and it should. The defence is the scope list, not the sentiment: ten named primitives, and the
   spike that tried to avoid writing them.

And what we lose by *not* going further: the distributed and remote-worker path is explicitly out of scope
(map, Out of scope), but a custom core makes that reversal more expensive than an engine would — the point at
which a second machine appears is the point at which this decision should be reconsidered rather than patched.

## Per-language availability

Feeds [#5](https://github.com/Teagan42/aLLMchemy/issues/5). The verdict is that **orchestration does not
constrain the language choice**, and specifically does not restore the Python advantage that #3 found had
evaporated.

| Language | Server-backed | Library-mode, daemon-free | Verdict |
|---|---|---|---|
| **Go** | Temporal, Restate | **DBOS Transact (SQLite, cgo-free)**, go-workflows (SQLite), durabletask-go (SQLite) | **Best-served.** Three daemon-free options, and the only language with a *choice* of them. Static single binary preserved in every case. |
| **Python** | Temporal, Restate | **DBOS Transact (SQLite is the default)**, Resonate (pre-1.0) | Well-served, by one mature option. Also the only language with first-party agent-framework prior art to read. |
| **TypeScript** | Temporal, Restate, Inngest, Trigger.dev | DBOS Transact | Adequate; nothing here argues for it. |
| **Rust** | Restate | none found | **Worst-served.** No library-mode durable execution located. **Unverified** — absence of evidence, searched but not exhaustively. |

Two notes that matter for #5:

- **Go is now at least as well-served as Python for orchestration, and arguably better.** The daemon-free
  option count is 3 to 2, and only Go's gets a single static binary with no runtime to install on the
  operator's machine. Combined with #3's finding that Python's SDK advantage does not survive contact with
  Codex, nothing in orchestration argues for Python.
- Because the recommendation is custom, this table is a tiebreaker rather than a constraint. Its real use is
  the *fallback* ranking: if the DBOS spike succeeds, Go and Python are both viable; if the spike succeeds and
  the language is Go, go-workflows is a second fallback that Python does not have.
