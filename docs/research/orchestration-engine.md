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

TBD

## Per-candidate assessment

TBD

## Cost of the custom option

TBD

## Recommendation

TBD

## What we lose

TBD
