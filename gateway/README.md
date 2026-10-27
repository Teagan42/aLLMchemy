# Model Failover Gateway

Layer 1 of the failover design: per-request. One Anthropic-Messages endpoint on
`127.0.0.1:4000`. Every request walks an ordered chain — cloud, then a local model, then a
second local model — and the harness is never told which tier answered.

A dead model request is the same class of problem as a question: nobody is available to
retry it, so the run hangs forever. This package's entire premise is that no human is
available, and a run has already died this way — an AWS SSO token expired mid-flight and
nine parallel agents all failed with "Could not load AWS credentials" at once.

Claude Code already retries ten times with exponential backoff, and its `fallbackModel`
setting is an ordered chain. Neither helps here: `fallbackModel` is **same-provider only**,
so it cannot reach a local model, and retrying an expired credential ten times just spends
ten times the wall clock. The chain has to live below the harness. That is this gateway.

Layer 2, the per-run supervisor that restarts a whole run on the local tier, lives
elsewhere and calls `gateway/probe.sh` to decide whether the local tier is usable.

## Use

```sh
./gateway/up.sh                      # start, idempotent, health-gated
. gateway/env.sh                     # point Claude Code at it
./gateway/probe.sh                   # which tier answers right now
./gateway/probe.sh --tool-call       # the local tier can still drive an agent loop
./gateway/probe.sh --induce-failure  # tier 1 dead; a local tier must still answer
./gateway/down.sh                    # stop, verify the port is released
```

`up.sh` is idempotent: it probes `/v1/models` for this config's own model names and reuses
a gateway that is already serving rather than starting a second one. Two proxies on one
port present as flaky inference, which is expensive to diagnose and easy to prevent.

## The chain

| Tier | Model group | Backend |
|---|---|---|
| 1 | `factory-primary` | Cloud. `$FACTORY_PRIMARY_MODEL`, Bedrock or direct Anthropic |
| 2 | `local-oss` | `gpt-oss:20b` on Ollama at `localhost:11434` |
| 3 | `local-qwen` | `qwen3:8b`, for when the first model is evicted from VRAM |
| — | `"*"` | `gpt-oss:20b`. Required: Claude Code's haiku-class calls 400 without it |

No credential is written into `gateway/litellm.yaml`. `FACTORY_PRIMARY_MODEL` carries its
own provider prefix, so credentials resolve from that provider's ambient environment
(`AWS_PROFILE`/`AWS_REGION`, or `ANTHROPIC_API_KEY`) and the file stays committable.

## Why passthrough, not translation

Two shapes reach Ollama from LiteLLM, and the choice has consequences.

**Passthrough — `model: anthropic/<name>`, chosen here.** Ollama has served the Anthropic
Messages API natively at `POST /v1/messages` since v0.14.0, so LiteLLM forwards rather than
translates. One less hop; `cache_read_input_tokens` survives to the client; and it dodges
two LiteLLM translation defects — a null `thinking.signature`, and an empty
`{"type":"text","text":""}` block emitted alongside `tool_use`.

**Translation — `model: ollama_chat/<name>`.** LiteLLM converts Anthropic shape to Ollama's
own chat API. Its one advantage: `num_ctx: 32768` in `litellm_params` propagates.

**The tradeoff that matters.** On the passthrough path `num_ctx` is *silently ignored*.
Context is governed server-side by `OLLAMA_CONTEXT_LENGTH` alone. Adding `num_ctx` to
`gateway/litellm.yaml` looks like it works and does nothing, so `up.sh` measures the
effective context instead of trusting the config.

## Failure classes covered

`router_settings.fallbacks` was tested against seven induced failures and failed over on
every one: `401`, `403`, `429`, `500`, `503`, connection-refused, and timeout. Auth, quota,
network, 5xx, timeout, malformed and unknown all route down the chain.

`num_retries: 0`, `allowed_fails: 100` and `cooldown_time: 0` are deliberate. The defaults
retry the failing group and then cool it off for a minute. An unattended run cannot wait
out a cooldown, and a retry against an expired credential cannot succeed — it only spends
wall clock that the run needed for building.

### The one carve-out: policy refusals

`content_policy_fallbacks` is **unset, and must stay unset.** LiteLLM treats a content
policy block as its own error class with its own fallback list, which is precisely the
mechanism to leave empty. A safety or policy refusal is an answer, not an outage. Re-rolling
it on a second model until one complies is laundering, not failover. Everything else fails
over; this does not.

## Context window

Below roughly 32k tokens, Claude Code silently truncates and triggers spurious
auto-compaction: the model starts summarising its own context instead of working, and the
run reports success having built nothing. This is observed, not theoretical.

`up.sh` therefore refuses to start when the effective context is under 32768. It measures
the real value from `/api/ps` after warming the model, because that is the context a loaded
model actually received — model-level overrides included — rather than what a config file
claims. `gpt-oss:20b` accepts up to 131072.

Two remediations, and one trap between them. Headless:

```sh
pkill -f 'ollama serve'; OLLAMA_CONTEXT_LENGTH=65536 ollama serve &
```

macOS desktop app: Settings → Context length → 65536, then reopen the app. **The desktop
app passes its own stored value to `ollama serve` and overrides `launchctl setenv`**, so
setting the variable while the app is running changes nothing and the symptom is identical
to having not set it.

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` must stay strictly *below* the Ollama context, because
Claude Code budgets only its own window and the response tokens push the total past the
server limit. `gateway/env.sh` reserves 8192 for output and derives the rest from the value
`up.sh` measured.

## Performance, measured

| | |
|---|---|
| Generation | 25–27 tok/s |
| Prefill | ~350 tok/s |
| Prefix cache hit | 12.8k prompt re-sent: 45.5s → 0.32s TTFT, a 142x improvement |

The cache hit is reported as `cache_read_input_tokens` and survives the passthrough path.
It is the difference between a usable local tier and an unusable one.

### Run the local tier single-threaded

**Parallel agents thrash the single KV cache slot.** Ollama serves one cache slot
(`-np 1`); each agent's prompt evicts the last one, so every request pays a full re-prefill
and the 142x win disappears. Sequential agentic runs on the local tier are practical.
Parallel ones are not — which is also what killed the run that motivated this work, where
nine agents failed at once.

A delegating harness must drop to sequential role execution when it is running on the local
tier. The phase sequence in `playbook/00-kickoff.md` is identical either way; only dispatch
changes, exactly as it does for a single-context harness.

## Cosmetic, not broken

- stderr logs `[claude-code:unrecognized_model]`. Harmless.
- `total_cost_usd` is fabricated for local models. Do not feed it to the `cost` gate.
- `ANTHROPIC_BASE_URL` requires Anthropic Messages shape and disables Remote Control. Both
  are acceptable for an unattended run.

## Files

| File | |
|---|---|
| `gateway/litellm.yaml` | The chain. Credentials by `os.environ/*` only |
| `gateway/up.sh` | Preconditions, start, health gate, pidfile under `artifacts/` |
| `gateway/down.sh` | Stop by pidfile, confirm the port released |
| `gateway/env.sh` | Sourceable. Sets and unsets the harness variables |
| `gateway/probe.sh` | The gateway's own test. The supervisor calls it |

`up.sh` writes `artifacts/gateway-<port>.pid`, `artifacts/gateway-<port>.log` and
`artifacts/gateway-context`. The pidfile is port-scoped on purpose: a single shared name
lets a run on a second port overwrite the first one's pidfile, after which `down.sh`
orphans a live proxy. `artifacts/` is gitignored.

## Related

- `playbook/autonomy-contract.md` — why a hang is the failure mode to design against
- `playbook/00-kickoff.md` — execution modes; the local tier forces the single-threaded one
