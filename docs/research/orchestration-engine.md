# Orchestration: build a durable-execution core, or adopt an engine?

Resolves [#2](https://github.com/Teagan42/aLLMchemy/issues/2). Feeds
[#5](https://github.com/Teagan42/aLLMchemy/issues/5) (language) and
[#6](https://github.com/Teagan42/aLLMchemy/issues/6).

**Status: in progress.** Sections land incrementally; each commit is a checkpoint.

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
prior art and the next section treats it as such.

## Cost of the custom option

TBD

## Recommendation

TBD

## What we lose

TBD
