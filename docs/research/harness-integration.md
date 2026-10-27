# Harness integration: capability matrix

Resolves [#3](https://github.com/Teagan42/aLLMchemy/issues/3). **Facts, not design.** The design belongs to
[#5](https://github.com/Teagan42/aLLMchemy/issues/5) (language), [#7](https://github.com/Teagan42/aLLMchemy/issues/7)
(trust boundary) and [#11](https://github.com/Teagan42/aLLMchemy/issues/11) (model-routing policy).

Harnesses in scope: **Claude Code** and **Codex CLI**. OpenCode is out of scope (map, Out of scope).

## What the engine needs

Restated from map constraints 10, 13, 14 and 17, so every matrix row has a pass/fail target.

| # | Requirement | Constraint |
|---|---|---|
| R1 | Fresh bounded invocation per step with an engine-assembled brief; never a resumed vendor session | 14 |
| R2 | Agent holds no provider credentials; every privileged effect arrives as an engine-owned MCP tool call | 10 |
| R3 | Container, workspace-only filesystem, restricted egress | 10, 13 |
| R4 | Engine-controlled model endpoint; failure class classifiable by trusted code; a safety/policy refusal is a typed terminal class, never retried against another provider | 17 |
| R5 | Non-interactive, with no possibility of blocking on a human | — |

## Confidence markers

- **verified** — observed directly: a run on this machine, the shipped binary, or first-party source read.
- **documented** — stated in first-party documentation; not exercised here.
- **unverified** — documentation silent, ambiguous, or contradicted by observation.

**An `unverified` row is an unenforceable boundary.** Downstream tickets must either verify it or enforce the same
property at a process or network boundary. Nothing here was inferred to fill a gap; gaps are marked.

## Versions

| Artifact | Version | How established |
|---|---|---|
| `claude` native binary | **2.1.311** | `claude --version`; `~/.local/share/claude/versions/2.1.311` (Mach-O arm64, 276 MB) |
| `@anthropic-ai/claude-agent-sdk` (TS) | 0.3.311 | `npm view @anthropic-ai/claude-agent-sdk version` |
| `claude-agent-sdk` (Python) | 0.2.174, `requires_python >=3.10` | <https://pypi.org/pypi/claude-agent-sdk/json> |
| `@openai/codex-sdk` (TS) | 0.164.0 | `npm view @openai/codex-sdk version` |
| `codex` CLI | **not installed on this machine** | — |

Claude Code rows marked **verified** were exercised against binary 2.1.311 on 2026-10-27 and cross-read against
<https://code.claude.com/docs/en/cli-reference>. **No Codex row is verified by execution**; Codex rows rest on
first-party documentation and on `codex-rs` source.

---

# Claude Code

## 1. Invocation surface

| Fact | Confidence | Source |
|---|---|---|
| Three entry points: TypeScript SDK, Python SDK, and `claude -p/--print` with `--output-format json\|stream-json`. | documented | <https://code.claude.com/docs/en/cli-reference>, <https://code.claude.com/docs/en/headless> |
| `--output-format stream-json` emits newline-delimited JSON. `--input-format stream-json` accepts streaming input. `--include-partial-messages`, `--include-hook-events`, `--forward-subagent-text`, `--replay-user-messages` widen the stream and require `-p` + `stream-json`. | verified | `claude --help`; runs below |
| Exactly one `result` message per turn. | documented | result-schema text embedded in binary 2.1.311: "The CLI emits exactly one result message per turn, after that turn's assistant, user and st…" |
| `--output-format json` returns **either** a single `result` object **or** a JSON array of every message, depending on which other flags are set. With `--tools "" --permission-prompts none` it returned an array; adding `--restricted` returned a bare object. | verified (behaviour) / **unverified** (rule) | observed in both runs; no documented rule for which shape is produced |

**Do not parse `--output-format json` with a shape assumption.** Use `stream-json` and key on `type`, or normalise
object-or-array at the boundary.

### Observed `stream-json` message types

`system/init`, `system/thinking_tokens`, `system/api_retry`, `system/hook_response`, `assistant`, `user`, `result`
(**verified**). The schemas embedded in 2.1.311 additionally declare `system/model_refusal_fallback`,
`system/model_refusal_no_fallback`, `system/model_fallback`, `system/command_lifecycle` and `stream_event`
(**documented**).

`system/init` carries the authoritative per-invocation inventory: `tools`, `mcp_servers`, `model`, `permissionMode`,
`apiKeySource`, `slash_commands`, `skills`, `agents`, `plugins`, `cwd`, `additional_directories`, `memory_paths`,
`session_id`, `claude_code_version`, `capabilities`.

**Assert the trust boundary against `init`, never against the model's own account of its tools.** In the run below
`init.tools` was `[]` while the model confidently reported `Read, Write, Edit, Glob, Grep, PowerShell`. The model's
self-report is a prior, not an observation.

## 2. Python and Go

| Fact | Confidence | Source |
|---|---|---|
| Python SDK exists: `claude-agent-sdk`, 0.2.174, Python >= 3.10. | verified | <https://pypi.org/pypi/claude-agent-sdk/json>, <https://github.com/anthropics/claude-agent-sdk-python> |
| Both SDKs **spawn the `claude` CLI** and speak its stream-json protocol over stdio. The CLI is the protocol; the SDKs are not a separate transport. | documented | <https://code.claude.com/docs/en/agent-sdk/overview>; `--bare` help text names "the SDK host" as a stdio peer |
| **No first-party Go SDK.** `anthropics/anthropic-sdk-go` is the Claude *API* SDK (direct Messages API), not a harness driver. | verified | <https://github.com/anthropics/anthropic-sdk-go>; `gh api 'search/repositories?q=org:anthropics+language:go'` returns no agent SDK |

### What a Go host must do instead, and what it loses

Spawn `claude -p --input-format stream-json --output-format stream-json`, write JSON lines to stdin, read JSON lines
from stdout, and own the schema.

| SDK feature | Reachable from a CLI-only host? | Confidence |
|---|---|---|
| In-process MCP servers (TS `createSdkMcpServer`, Python `@tool`) | **No.** Equivalent: an out-of-process stdio or HTTP MCP server registered with `--mcp-config`. Functionally equivalent for the engine; costs a process or a port, and makes the tool boundary a real IPC boundary — arguably a *gain* under constraint 10. | documented |
| `canUseTool` permission callback | **Partly.** `--permission-prompt-tool <mcp tool>` routes prompts to an MCP tool the host serves, so a Go host can answer them over MCP rather than as a function call. `--permission-prompts none` denies everything instead. | documented |
| Hooks defined in host code | **No.** CLI hooks are shell commands declared in settings; `--settings` accepts inline JSON, so no shared file is needed, but the hook runs as a subprocess. | verified (`--settings` accepts inline JSON, `claude --help`) |
| `interrupt()` | **No typed equivalent.** Needs the control protocol over `--input-format stream-json`; the control-request wire format is not published. | **unverified** |
| `setModel` / mid-session model change | **No.** | **unverified** |
| Bidirectional streaming input, queued turns | **Yes**, via `--input-format stream-json`; the host frames the messages. | documented |
| Typed message structs | **No.** The Go host owns the schema and must tolerate additive drift: the binary's own error enums use `.catch(undefined)` and say "new values are added over time, so treat an unknown value as absent". | verified (schema text, 2.1.311) |

**Verdict for Claude Code: R1–R5 are all reachable from a CLI-only Go host. Nothing the engine needs is SDK-only.**
The cost is a hand-written stream-json codec tolerant of additive drift, an out-of-process MCP server, and no typed
`interrupt()`. Python buys typed messages, in-process MCP tools, a permission callback and `interrupt()`, at the price
of a Python runtime beside the engine. See the Codex section before reading this as a point for Python — Codex has no
Python SDK at all.

## 3. Non-interactive execution

| Fact | Confidence | Source |
|---|---|---|
| `-p/--print` is the non-interactive mode. The workspace-trust dialog is skipped under `-p`, or whenever stdout is not a TTY. | verified | `claude --help` |
| `--permission-prompts none`: "Pass `none` when nobody can answer, and Claude Code denies them instead." Requires v2.1.259+. | documented | <https://code.claude.com/docs/en/cli-reference> |
| A call that would have prompted is **auto-denied, recorded, and the turn completes cleanly**. Observed: `permission_denials: [{"tool_name":"mcp__engine__engine_ping","tool_use_id":"toolu_…","tool_input":{}}]`, `terminal_reason: "completed"`, `is_error: false`, exit 0. **No hang.** | verified | run with `--restricted --permission-prompts none` and no allowlist |
| `--permission-mode` choices in 2.1.311: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`. | verified | `claude --help` |
| `--restricted` **refuses `bypassPermissions`**. The two cannot be combined. | documented | <https://code.claude.com/docs/en/cli-reference> |
| `AskUserQuestion` and `ExitPlanMode` are deniable by name via `permissions.deny` (as the PoC does). Under `--tools ""` they are absent from the tool set, making the deny rule redundant. | verified | PoC `.claude/settings.json`; `init.tools == []` |
| Bounding: `--max-turns`, `--max-budget-usd`, `API_TIMEOUT_MS`. `--max-budget-usd` is checked against a **client-side cost estimate, not your bill**. | documented | <https://code.claude.com/docs/en/cli-reference>, <https://code.claude.com/docs/en/agent-sdk/cost-tracking> |

**The PoC's three anti-hang layers collapse to one flag.** `--permission-prompts none` is the native answer. The
`Stop`/`SubagentStop` no-questions hook and the question-pattern regex stop being load-bearing for *blocking*; a prose
question in a final message becomes a content concern, not a deadlock.

## 4. Per-invocation configuration

Everything the engine needs is a flag. No shared user-level file has to be written.

| Knob | Per-invocation flag | Confidence |
|---|---|---|
| Prompt | positional arg, or **stdin** under `-p` | verified |
| System prompt | `--system-prompt`, `--system-prompt-file`, `--append-system-prompt[-file]`, `--append-subagent-system-prompt[-file]` | documented |
| Built-in tool **availability** | `--tools` | verified |
| Tool **permission** lists | `--allowed-tools`, `--disallowed-tools` | verified |
| MCP servers | `--mcp-config <file-or-inline-json>` + `--strict-mcp-config` | verified |
| Working directory | process cwd; `--add-dir` for extra roots | verified |
| Model | `--model`; `--fallback-model` (leave unset — §9) | verified |
| Settings | `--settings <file-or-inline-json>` | verified |
| Settings **sources** | `--setting-sources user,project,local`; an omitted source is not loaded, `""` loads none | verified |
| Endpoint | `ANTHROPIC_BASE_URL` — **environment only, no flag** | verified |
| Session persistence | `--no-session-persistence`, `--session-id <uuid>`, `--fork-session` | documented |
| Config dir | `CLAUDE_CONFIG_DIR` — environment only | verified |
| Custom agents | `--agents <json-or-file>` | documented |
| Structured output | `--json-schema <schema>` (print mode only) | documented |

Two traps, both **verified**:

- `--mcp-config <configs...>` is **variadic** and swallows a positional prompt as another config path:
  `Error: Invalid MCP configuration: MCP config file not found: /private/tmp/ccprobe/Call the engine_ping tool…`.
  **Pass the prompt on stdin.**
- Under `-p`, "Settings files that fail validation are **silently ignored** (no error dialog is shown)"
  (`claude --help`). A malformed `--settings` payload **fails open**, not closed. The engine must validate its own
  settings JSON before handing it over.

`claude mcp add` mutates shared config and must not be used; `--mcp-config` + `--strict-mcp-config` is the
per-invocation path.

### How far each isolation flag actually goes

Measured `init` inventory per flag combination on this machine. Confidence: **verified**.

| Invocation | `tools` | hooks ran | plugins | skills | slash cmds | agents | memory paths |
|---|---|---|---|---|---|---|---|
| `--tools ""` | `[]` | **yes** (user `SessionStart`) | 11–12 | 71–73 | 103–110 | 18 | auto memory dir set |
| `--bare --tools ""` | `[]` | no | 11 | 16 | 44 | 5 | none |
| `--restricted --setting-sources "" --tools ""` | `[]` | no | 3 | 16 | 44 | 5 | none |
| `CLAUDE_CONFIG_DIR=<fresh> --restricted --setting-sources "" --tools ""` | `[]` | no | **3, all `builtin`** | 16 | 44 | 5 | none |

Reading:

- `--restricted` and `--bare` stop *settings* and *hooks* but **not host-installed plugins and skills**. Only
  `CLAUDE_CONFIG_DIR` at a per-run directory removes those.
- Even then, three `builtin` plugins (`cc-plugin-sec-default`, `cc-plugin-agents-md`,
  `cc-plugin-plugin-authoring`), 16 skills, 44 slash commands and 5 agent definitions remain. **No flag removes
  them.** This is tolerable only because `--tools ""` leaves them nothing to act through — `Task`/`Agent` and `Skill`
  are absent from `init.tools`, so subagents and skills are unreachable. It is still irreducible surface.
- `CLAUDE_CONFIG_DIR` must point at a **writable** directory; the run created `.claude.json`, `sessions/`, `cache/`,
  `plugins/`, `backups/` inside it.

## 5. MCP as the tool transport

| Fact | Confidence | Source |
|---|---|---|
| Transports: `stdio`, `sse`, `http`, and `sdk` (in-process, SDK hosts only). | documented | <https://code.claude.com/docs/en/mcp> |
| `--mcp-config` accepts a file path **or an inline JSON string**, shape `{"mcpServers":{"<name>":{"type":"stdio","command":…,"args":[…],"env":{…}}}}`. | verified | run below |
| `--strict-mcp-config`: "Only use MCP servers from `--mcp-config`, ignoring all other MCP configurations." | documented | <https://code.claude.com/docs/en/cli-reference> |
| MCP tools are namespaced `mcp__<server>__<tool>`. Server health appears in `init.mcp_servers`; observed `{"name":"engine","status":"connected","source":"dynamic"}`. | verified | run below |
| MCP tools remain **permission-gated**. Under `--permission-prompts none` they are denied unless named in `--allowed-tools` — and `bypassPermissions`, the other way through, is refused by `--restricted`. | verified | two runs: denial, then success after allowlisting |

## 6. THE LOAD-BEARING QUESTION — can Claude Code be restricted to only engine-provided MCP tools?

### **Yes. Documented, and verified by execution.**

`--tools`, verbatim:

> Restrict which built-in tools Claude can use. Use `""` to disable all, `"default"` for the default set, or tool
> names like `"Bash,Edit,Read"`. On macOS, Linux, and WSL, the default set leaves out `Glob` and `Grep` … **The flag
> doesn't affect MCP tools; to deny those too, use `--disallowedTools "mcp__*"`.** A list that omits `EndConversation`
> doesn't remove it; `""` removes it only when no MCP tools remain

— <https://code.claude.com/docs/en/cli-reference>

The documentation also draws the distinction the PoC's `permissions.allow` list did not:

- `--allowed-tools` / `--disallowed-tools` are **permission** lists — "Tools that execute without prompting for
  permission". The doc says outright: "To restrict which tools are available, use `--tools` instead."
- `--tools` is the **availability** list. It is the only thing that removes a built-in.

`--restricted`, verbatim:

> Start in restricted mode. Use it when an evaluation harness drives `claude` on a shared machine and Claude Code must
> not run commands or read that machine's user and project settings. Claude Code removes the built-in tools that run
> commands or code, and WebFetch, unless you name them individually in `--tools`, not through the `default` preset. It
> also confines the built-in file tools to the working directories, loads only managed settings and `--settings`,
> refuses `bypassPermissions`, and refuses to create cloud sessions. Requires Claude Code v2.1.248 or later

— <https://code.claude.com/docs/en/cli-reference>

### The verified recipe

```sh
echo "$BRIEF" | CLAUDE_CONFIG_DIR=/run/cc-home claude -p \
  --tools "" \
  --restricted \
  --setting-sources "" \
  --strict-mcp-config --mcp-config "$ENGINE_MCP_JSON" \
  --allowed-tools "mcp__engine__provision mcp__engine__deploy …" \
  --permission-prompts none \
  --no-session-persistence \
  --output-format stream-json --verbose
```

Measured:

```
init:   tools       = ["mcp__engine__engine_ping"]
        mcp_servers = [{"name":"engine","status":"connected","source":"dynamic"}]
result: subtype=success  is_error=false  terminal_reason=completed  permission_denials=[]
        result = "The engine_ping tool returned: **ENGINE_PONG_7f3a**"
```

One engine-provided MCP tool. Zero built-ins: no shell, no `WebFetch`, no `WebSearch`, no `Read`/`Write`/`Edit`, no
`Task`. The tool was called and returned. **verified.**

### Residue

| Item | Confidence | Note |
|---|---|---|
| `EndConversation` — docs say `""` removes it "only when no MCP tools remain", so with engine MCP tools present it should survive. `init.tools` listed **only** the MCP tool and did not name it. | **unverified** | Either `init.tools` does not enumerate it, or docs and implementation diverge. Harmless in itself — it ends the turn — but **`init.tools` must be treated as a necessary check, not a sufficient tool inventory.** |
| Built-in plugins, skills, slash commands, agent definitions stay loaded (§4). | verified | Unreachable under `--tools ""` because `Task` and `Skill` are absent. Not removable. |
| Server-side tools (`web_search`, `web_fetch`) are counted in `usage.server_tool_use`. Whether `--tools ""` suppresses the model's ability to *request* them, or only the client-side tool, was not isolated. Observed `web_search_requests: 0, web_fetch_requests: 0` in every run. | **unverified** | Egress policy must not rely on this. `CLAUDE_CODE_DISABLE_WEB_FETCH` and `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` exist as additional levers (documented on the env-var page). |

## 7. Structured output from a completed invocation

### What is there, and it is good

From the `result` message — all **verified** by observation:

| Field | Note |
|---|---|
| `subtype` | `"success"` on the success variant. Error variant: `error_during_execution`, `error_max_turns`, `error_max_budget_usd`, `error_max_structured_output_retries` (**documented**, 2.1.311 schema) |
| `is_error` | **The actual error flag.** Observed `subtype: "success"` together with `is_error: true` on a transport failure |
| `terminal_reason` | Typed. Success variant: `blocking_limit`, `rapid_refill_breaker`, `prompt_too_long`, `image_error`, `model_error`, `api_error`, `malformed_tool_use_exhausted`, `aborted_streaming`, `aborted_tools`, `stop_hook_prevented`, `hook_stopped`, `tool_deferred`, `max_turns`, `background_requested`, `completed`. Error variant: `budget_exhausted`, `structured_output_retry_exhausted`, `tool_deferred_unavailable`, `turn_setup_failed` |
| `usage` | `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens_details.thinking_tokens`, `server_tool_use.{web_search,web_fetch}_requests`, `service_tier` |
| `modelUsage` | **Per-model** breakdown with `costUSD`, `provider`, `canonicalModel`, `contextWindow`, `costBasis`. The schema calls `usage` "MAIN AGENT LOOP ONLY — excludes Task subagent, sidechain, and auxiliary model calls" and says "Prefer modelUsage for token/cost accounting" |
| `total_cost_usd` | A **client-side estimate, not billing** |
| `permission_denials` | `[{tool_name, tool_use_id, tool_input}]` — a machine-readable denial ledger |
| `safety_stops` | Non-negative int; see the caveat below |
| `num_turns`, `duration_ms`, `duration_api_ms`, `ttft_ms`, `session_id`, `uuid`, `stop_reason`, `subagent_stats`, `queued_turn_count`, `structured_output` | |

Tool-call transcript: the `assistant`/`user` message pairs in `stream-json`, with `parent_tool_use_id` linking
subagent output. Cost accounting is per model and per provider.

### The sharp edges

Observed, pointing `claude` at a dead endpoint (**verified**):

```
system/api_retry: {"attempt":1,"max_retries":1,"retry_delay_ms":531,"error_status":null,"error":"unknown"}
assistant:        {"model":"<synthetic>","stop_reason":"stop_sequence", …}
result:           subtype="success"  is_error=true  terminal_reason="api_error"
                  api_error_status=null  safety_stops=0  total_cost_usd=0
                  result="API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)"
exit code:        1
```

1. **`result.subtype` is not an error discriminator.** Classify on `is_error` plus `terminal_reason`.
2. **Claude Code synthesises an `assistant` message with `model: "<synthetic>"` on API failure.** Trusted code must
   not treat it as model output.
3. For *this* failure the class existed only in English prose; `api_error_status` was `null`.

### Where the typed classes do live

| Surface | Typed values | Confidence |
|---|---|---|
| `StopFailure` hook, matcher field `error` | `rate_limit`, `overloaded`, `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `verification_required`, `billing_error`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens`, `cloud_credential_error`, `unknown`. The hook's own description: "Fire-and-forget — hook output and exit codes are ignored." | documented (shipped hook metadata, 2.1.311) |
| `assistant` siblings when `is_api_error_message: true` — `api_error` (typed kind) and `api_error_status` (HTTP status) | `max_output_tokens`, `dlp_request_denied`, `claude_code_version_too_old`, **`safety_monitor_blocked`**, `effort_requires_thinking`, `advisor_incompatible`, `tool_history_mismatch`, `autocompact_thrashing`, `pdf_too_large`, `pdf_password_protected`, `media_removed`, `no_response`, `tls_untrusted_ca`, `gateway_content_type`, `provider_credentials`, `gateway_signin_required`, `gateway_session_expired`, `api_key_auth_disabled`, `org_disabled_credential`, `invalid_credential_header`, `model_requires_usage_credits`, …, `limit_reached`, `empty_completion`, `unattended_start_limit`, `unattended_start_unconfirmed` | documented (schema, 2.1.311); marked `@internal` |
| `system/model_refusal_no_fallback` | `original_model`, `request_id`, **`api_refusal_category`**, **`api_refusal_explanation`**, `refused_user_message_uuid`, `content` | documented (schema, 2.1.311) |
| `system/model_refusal_fallback` | `trigger: "refusal"`, `direction`, `scope` (`session` \| `local`), `original_model`, `fallback_model` | documented (schema, 2.1.311) |
| `system/model_fallback` | `trigger: model_not_found \| permission_denied \| overloaded \| server_error \| last_resort \| model_blocked` | documented (schema, 2.1.311) |

Two qualifications the engine must honour:

- The `api_error` enum is `@internal`, uses `.catch(undefined)`, and its own text says "new values are added over
  time, so treat an unknown value as absent." **An unrecognised class must fail closed**, consistent with map
  constraint 24.
- **`safety_stops == 0` does not prove no refusal happened.** The shipped description enumerates what it counts
  (a response ending on `stop_reason: refusal`; a refusal the API answered on a fallback model; a terminal
  content-filter stop; and, where the build can recognise it — "public builds cannot" — `safety_monitor_blocked`)
  and what it does not: a content-filter stop Claude Code answers by re-streaming the request ("so 0 does not rule
  one out"), an organisation's DLP denial (`api_error: dlp_request_denied`), a cloud provider's own guardrail block,
  and an advisor's refusal inside a reply that ends normally. **Positive signal only.**

### The refusal-retry behaviour that violates constraint 17

**Claude Code retries a refused turn on a different model by default.** Schema text for
`system/model_refusal_fallback`:

> Emitted when the primary model ends the stream with `stop_reason "refusal"` and the turn is retried once on a
> fallback model (`direction: "retry"`). When `scope` is `"session"` … the swap is made persistent for the session;
> when `scope` is `"local"`, only that subagent/side-question response came from the fallback model.

And the documented off switch:

> **`CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK`** — Set to `1` to turn off the automatic model switch when a safety
> classifier flags a request, the behavior the `switchModelsOnFlag` setting controls

— <https://code.claude.com/docs/en/env-vars>

| Lever | Confidence |
|---|---|
| `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1` | documented |
| `switchModelsOnFlag` settings key — same behaviour as a setting, so deliverable via `--settings` inline JSON | documented |
| `CLAUDE_CODE_DISABLE_MODEL_ACCESS_FALLBACK` | documented |
| Leave `--fallback-model` unset. Documented behaviour of `CLAUDE_CODE_MAX_RETRIES`: "If you set a fallback model, Claude Code switches to that model rather than showing the error." | documented |
| `CLAUDE_CODE_DISABLE_REFUSAL_RETRY` — present in the 2.1.311 env-var table, **not found in published documentation** | **unverified** |
| `CLAUDE_CODE_REFUSAL_FALLBACK_CATCH_ALL` and a per-category "fallback map" are named in the shipped schema text; no configuration surface is documented | **unverified** |

**This is the most important single finding for [#11](https://github.com/Teagan42/aLLMchemy/issues/11).**
Constraint 17 says a refusal is a typed terminal class, never retried against another provider. Claude Code's
default is the opposite. The engine must set `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1`, leave `--fallback-model`
unset, and treat `system/model_refusal_no_fallback` as the terminal class. Observing
`system/model_refusal_fallback` at all means the policy was already breached.

## 8. Containerisation and host state

| Host dependency | Breaks under confinement? | Mitigation | Confidence |
|---|---|---|---|
| `~/.claude/`, `~/.claude.json` | Needs a writable path | `CLAUDE_CONFIG_DIR=<per-run dir>`, created automatically | verified |
| OS keychain (OAuth credentials) | Absent in a container | `--bare` "skips … keychain reads … Anthropic auth is strictly `ANTHROPIC_API_KEY` or `apiKeyHelper` via `--settings` (OAuth and keychain are never read)". `CLAUDE_CODE_OAUTH_TOKEN` "Takes precedence over keychain-stored credentials" | verified (help text) / documented (env-var page) |
| User/project/local settings files | Leak host policy in | `--restricted` loads only managed settings and `--settings`; `--setting-sources ""` | verified |
| Host-installed plugins and skills | **Leak in under `--restricted` and `--bare` alike** | `CLAUDE_CONFIG_DIR` at a fresh dir | verified |
| Auto-update, telemetry, feature flags, error reporting, release notes, marketplace auto-install, plugin `command` source background runs | Unauthorised egress | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. Note the documented oddity: "**Setting it to `0` or `false` still disables this traffic**; unset the variable to allow it again." Plus `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL`; `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DO_NOT_TRACK` are referenced in prose | documented |
| Runtime | None — self-contained native binary | — | verified |

**Supported ways to give a containerised harness a credential** (**documented**,
<https://code.claude.com/docs/en/env-vars>): `ANTHROPIC_API_KEY` ("In non-interactive mode (`-p`), the key is always
used when present"); `ANTHROPIC_AUTH_TOKEN` (raw `Authorization` value, `Bearer`-prefixed); `apiKeyHelper` delivered
through `--settings` inline JSON with `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`; `CLAUDE_CODE_OAUTH_TOKEN` from
`claude setup-token`; or a third-party provider's own credentials.

Under R2 the only credential the harness needs is one for the **engine's own gateway**. It is not a provider
credential, and it must be scoped so it can do nothing but complete model calls.

**Required-egress domain list: unverified.** The official devcontainer and its firewall script were not read in this
pass. Determine the allowlist empirically under `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` before relying on one.

## 9. Model endpoint redirection, and what silently outranks it

`ANTHROPIC_BASE_URL` is the override: "Override the API endpoint to route requests through a proxy or gateway"
(<https://code.claude.com/docs/en/env-vars>). There is **no CLI flag** for it — it is environment-only, which is
exactly why the environment is the boundary.

### Demonstrated bypass

```
env:   CLAUDE_CODE_USE_BEDROCK=1   AWS_PROFILE=engUsers
set:   ANTHROPIC_BASE_URL=http://127.0.0.1:1      # a closed port
run:   claude -p --model haiku --output-format json "Say OK"
got:   result.subtype=success   result="OK"
       modelUsage[*].provider = "bedrock"
       init.model = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
```

**verified.** The override pointed at a dead port and the call still succeeded — against Bedrock, paid for on the
host's AWS profile. **`CLAUDE_CODE_USE_BEDROCK` silently outranks `ANTHROPIC_BASE_URL`.** This reproduces the PoC's
finding on a current binary and proves endpoint control is an **environment-scrubbing** problem, not a configuration
problem.

### Provider selectors — each routes past `ANTHROPIC_BASE_URL`

From binary 2.1.311: `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`,
`CLAUDE_CODE_USE_GATEWAY`, `CLAUDE_CODE_USE_MANTLE`, `CLAUDE_CODE_USE_ANTHROPIC_AWS`,
`CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD`. **verified** that the binary reads all seven; **unverified** for the
precedence of the five beyond Bedrock and Vertex. The PoC scrubbed two of seven.

Per-provider endpoints: `ANTHROPIC_BEDROCK_BASE_URL`, `ANTHROPIC_BEDROCK_MANTLE_BASE_URL`,
`ANTHROPIC_VERTEX_BASE_URL`, `ANTHROPIC_FOUNDRY_BASE_URL`, `ANTHROPIC_AWS_BASE_URL`,
`ANTHROPIC_GOOGLE_CLOUD_BASE_URL`, `ANTHROPIC_API_HOST`, `ANTHROPIC_UNIX_SOCKET`. (**documented** for those on the
env-var page; **verified present in the binary** for the rest.)

### Auth redirection

`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_CUSTOM_HEADERS` (can set `Authorization` or `Host` outright),
`CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, `ANTHROPIC_AWS_API_KEY` ("takes precedence over AWS
SigV4"), `ANTHROPIC_FOUNDRY_AUTH_TOKEN` ("Takes precedence over `ANTHROPIC_FOUNDRY_API_KEY` and over the Azure
default credential chain"), `ANTHROPIC_FOUNDRY_API_KEY`, `AWS_BEARER_TOKEN_BEDROCK`,
`ANTHROPIC_IDENTITY_TOKEN(_FILE)`, `ANTHROPIC_PROFILE`, `apiKeyHelper`,
`CLAUDE_CODE_CLIENT_CERT`/`_KEY`/`_KEY_PASSPHRASE`, `NODE_EXTRA_CA_CERTS`.

### Whole credential chains, not single variables

The binary embeds the AWS, Google and Azure SDK credential resolvers, so their **entire** environment families are
live: `AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_ROLE_ARN`,
`AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`,
`AWS_CONTAINER_AUTHORIZATION_TOKEN(_FILE)`, `AWS_EC2_METADATA_SERVICE_ENDPOINT`, `AWS_ENDPOINT_URL*`,
`AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_OAUTH_ACCESS_TOKEN`,
`GOOGLE_EXTERNAL_ACCOUNT_*` (including `GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES`), `CLOUD_ML_REGION`,
`AZURE_CLIENT_ID`/`_SECRET`/`_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_CLIENT_CERTIFICATE_PATH`,
`AZURE_POD_IDENTITY_AUTHORITY_HOST`. **verified** that these symbols ship in the binary; **unverified** which are
reachable on each code path.

**Build the harness environment by allowlist, never by inheritance.** A denylist of the variables you happen to know
about is the PoC's failure mode, and this list is why such a list cannot be complete. Note also the documented
caveat: setting a variable to the empty string makes Claude Code treat it as unset for provider selection, **but
"Subprocesses still inherit the empty value"** — empty-string neutralisation is not absence.

### Model-selection variables

`--model` and `/model` override `ANTHROPIC_MODEL`. But `ANTHROPIC_DEFAULT_HAIKU_MODEL`,
`ANTHROPIC_DEFAULT_OPUS_MODEL`, `_SONNET_`, `_FABLE_`, `ANTHROPIC_DEFAULT_MODEL` and `ANTHROPIC_CUSTOM_MODEL_OPTION`
redefine what the **aliases** resolve to, and `ANTHROPIC_DEFAULT_HAIKU_MODEL` also governs "background
functionality". `ANTHROPIC_SMALL_FAST_MODEL` is deprecated but still read. `CLAUDE_CODE_SUBAGENT_MODEL` is in the
binary but **not** on the documented env-var page (**unverified**).

This is why the PoC had to set `ANTHROPIC_DEFAULT_HAIKU_MODEL`: **the harness makes auxiliary model calls on a
different alias than the one you selected**, and the engine's endpoint must serve both.

## 10. Cancellation and timeouts

| Fact | Confidence | Source |
|---|---|---|
| `SIGTERM` to the `claude` process ended it **and reaped its stdio MCP child**. By PID: `claude`=54725, MCP server=54738 (PPID 54725, same PGID); after `kill -TERM 54725` both were gone within 4 s. | verified | run on this machine |
| Under `--tools ""` there are **no shell children at all**, so the orphaned-child class the PoC fought does not arise. | verified | `init.tools == []`; Bash absent |
| Process-group `SIGTERM`/`SIGKILL` remains correct belt-and-braces, and is still required if any built-in shell tool is re-enabled. Claude Code's signal semantics are **not documented**. | **unverified** | no official signal-handling documentation found |
| SDK `interrupt()` exists for TS and Python hosts and needs the control protocol over streaming input. The control-request wire format is not published for a CLI-only host. | **unverified** | — |
| Bounding: `--max-turns`, `--max-budget-usd`, `API_TIMEOUT_MS` (default 600000; `0` removes the limit, v2.1.305+), `CLAUDE_CODE_MAX_RETRIES` (default 10, capped at 15; `CLAUDE_CODE_RETRY_WATCHDOG` removes the cap), `API_FORCE_IDLE_TIMEOUT`, `CLAUDE_STREAM_IDLE_TIMEOUT_MS`, `CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS`, `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`. | documented | <https://code.claude.com/docs/en/env-vars>, `claude --help` |

No single flag bounds total elapsed time. A wall-clock deadline enforced by the engine on the process is still
required.

---

# Codex CLI

## 0. Where the documentation actually lives — read this first

`openai/codex`'s `docs/*.md` are now **stubs**. `docs/config.md` is 15 lines pointing at `developers.openai.com`,
which 308-redirects to `learn.chatgpt.com`.

| Stale location | Current canonical |
|---|---|
| `openai/codex/docs/config.md` | <https://learn.chatgpt.com/docs/config-file/config-reference> |
| `openai/codex/docs/exec.md` | <https://learn.chatgpt.com/docs/non-interactive-mode> |
| `openai/codex/docs/sandbox.md` | <https://learn.chatgpt.com/docs/sandboxing> and <https://learn.chatgpt.com/docs/agent-approvals-security> |
| — | <https://learn.chatgpt.com/docs/developer-commands?surface=cli> (flag reference) |
| — | <https://learn.chatgpt.com/docs/config-file/environment-variables> |

**verified** (`curl` of the raw stubs; `curl -sIL` showing the 308s). Appending `.md` to any
`learn.chatgpt.com/docs/...` URL returns Markdown; `<https://learn.chatgpt.com/llms.txt>` is the index. Any cached
knowledge of `openai/codex/docs/config.md` as the configuration reference is **stale**.

`codex` was **not installed on this machine**. No Codex row is verified by execution. Rows marked **verified** were
read in first-party documentation or in `codex-rs` source.

## 1. Invocation surface

| Fact | Confidence | Source |
|---|---|---|
| `codex exec` (alias `codex e`) is the non-interactive entry point. `--json` (alias `--experimental-json`) makes stdout "a JSON Lines (JSONL) stream". | documented | <https://learn.chatgpt.com/docs/non-interactive-mode> |
| Progress goes to **stderr**; only the final agent message to stdout. `-o/--output-last-message <path>` "writes the final message to the file and still prints it to `stdout`". `--output-schema <path>` requests a final response conforming to a JSON Schema. | documented | same |
| `codex exec -` forces reading the prompt from stdin. | documented | same |
| `codex app-server` exists, marked **Experimental**: JSON-RPC over `--listen stdio:// \| ws://IP:PORT \| unix://[PATH] \| off`, with `--ws-auth capability-token \| signed-bearer-token`. | documented | <https://learn.chatgpt.com/docs/developer-commands?surface=cli> |
| **`codex mcp-server` and the standalone `codex-mcp-server` binary are removed.** Codex can no longer be exposed to the engine *as* an MCP server; the app server is the replacement. | documented | same |
| Must run inside a Git repository "to prevent destructive changes", unless `--skip-git-repo-check`. Already satisfied by map constraint 13. | documented | <https://learn.chatgpt.com/docs/non-interactive-mode> |

### `--json` event schema — read from source

`codex-rs/exec/src/exec_events.rs`
(<https://github.com/openai/codex/blob/main/codex-rs/exec/src/exec_events.rs>),
`#[serde(tag = "type")] pub enum ThreadEvent`. **verified** (source read).

Events: `thread.started` (`thread_id`), `turn.started` (no fields), `turn.completed` (`usage`),
`turn.failed` (`error`), `item.started`, `item.updated`, `item.completed` (each `{item}`), `error`.

`ThreadItemDetails` (snake_case, flattened onto `{id, …}`): `agent_message`, `reasoning`, `command_execution`,
`file_change`, `mcp_tool_call`, `collab_tool_call`, `web_search`, `todo_list`, `error`. `mcp_tool_call` carries a
`status` plus `McpToolCallItemResult` / `McpToolCallItemError`, so **the tool-call transcript is structured and
machine-readable**. `command_execution` carries `CommandExecutionStatus`; `file_change` carries `PatchApplyStatus`
and `PatchChangeKind`.

**There is no `init`-equivalent event. Codex never tells the host what tool set the model received.** See "What we
cannot control".

## 2. SDK language bindings — Python and Go

| Fact | Confidence | Source |
|---|---|---|
| First-party **TypeScript** SDK: `@openai/codex-sdk`, 0.164.0; source at `sdk/typescript/`. | verified | `npm view @openai/codex-sdk version`; <https://github.com/openai/codex/tree/main/sdk/typescript> |
| **No first-party Python SDK** located. | **unverified** (absence of evidence) | no `sdk/python` found in the repo tree; nothing located on PyPI in this pass |
| **No Go SDK or Go bindings.** `openai/openai-go` is the OpenAI *API* SDK, not a Codex driver. | verified | <https://github.com/openai/openai-go>; `gh api 'search/repositories?q=org:openai+go+in:name'` |
| `codex-protocol` on crates.io (0.63.0) is a **third-party fork** — owner `namastex888`, repository `github.com/namastexlabs/codex`. **Not first-party.** No first-party Codex crates were found on crates.io. | verified | <https://crates.io/api/v1/crates/codex-protocol> and `/owners` |

### The Python-vs-Go verdict

**Both Python and Go are in the same position for Codex: spawn `codex exec --json` and parse JSONL.** There is no
Python SDK to prefer, so **Codex removes Python's advantage entirely.** Even a Rust host would have to vendor from
git, since no first-party crates are published.

For [#5](https://github.com/Teagan42/aLLMchemy/issues/5): the language decision cannot rest on "Python has an SDK" —
Python has an SDK for **one** of the two harnesses. If the agent port must cover both (constraint 3), the common
denominator is "spawn a CLI and parse newline-delimited JSON", which Go does as well as Python, with a single static
binary to distribute. What Python buys is Claude-Code-only: typed messages, in-process MCP tools, a `canUseTool`
callback, and `interrupt()`. What Go costs is a hand-written codec per harness plus an out-of-process MCP server —
and none of that blocks R1–R5 on either harness.

## 3. Non-interactive execution

| Fact | Confidence | Source |
|---|---|---|
| `--ask-for-approval never` / `-a never` disables approval prompts. "This option works with all `--sandbox` modes, so you still control Codex's level of autonomy. **Codex makes a best effort within the constraints you set.**" — an action needing approval does not happen; it does not block. | documented | <https://learn.chatgpt.com/docs/agent-approvals-security> |
| `-a/--ask-for-approval` values are now **`on-request \| never` only**. `untrusted` is retired — "Codex and ChatGPT Work no longer support `untrusted` as a selectable approval policy"; `on-failure` is deprecated. | documented | <https://learn.chatgpt.com/docs/sandboxing>, <https://learn.chatgpt.com/docs/config-file/config-reference> |
| **`--full-auto` is removed**: "`--full-auto` is no longer supported." Migrate to `--sandbox workspace-write` or `--approve-for-me`. | documented | <https://learn.chatgpt.com/docs/non-interactive-mode> |
| `--dangerously-bypass-approvals-and-sandbox` (alias `--yolo`) still exists. `--approve-for-me` (alias `--not-so-yolo`) routes approvals through automatic review; it "Conflicts with `--sandbox` and `--yolo`". | documented | <https://learn.chatgpt.com/docs/developer-commands?surface=cli> |
| `approval_policy = { granular = { sandbox_approval, rules, mcp_elicitations, request_permissions, skill_approval } }` keeps chosen categories interactive "while automatically rejecting others". | documented | <https://learn.chatgpt.com/docs/agent-approvals-security> |
| An enabled MCP server with `required = true` that fails to initialise makes exec "exit with an error instead of continuing without that server" — a usable fail-closed guard for the engine's own server. | documented | <https://learn.chatgpt.com/docs/non-interactive-mode> |
| No documented path where `codex exec` blocks on stdin for approval. | documented (by the "best effort" statement) / **unverified** (not exercised) | — |

**PoC drift.** `bin/run-codex.sh` passes `--dangerously-bypass-approvals-and-sandbox`; `codex/config.toml` sets
`approval_policy = "never"` and `sandbox_mode = "danger-full-access"`. `never` survives. `--full-auto` is gone. The
wrapper's habit of probing `--help` before using a flag was the right instinct and should carry forward into the
engine as a startup capability probe.

## 4. Per-invocation configuration

| Knob | Mechanism | Confidence |
|---|---|---|
| Arbitrary config override | **`-c, --config key=value`** — "Values parse as TOML if possible; otherwise the literal string is used." Dotted keys work: the docs define `--disable <feature>` as `-c features.<name>=false` and `--enable` as `-c features.<name>=true` | documented |
| **Ignore the shared user config** | **`--ignore-user-config`** — a run that "doesn't load `$CODEX_HOME/config.toml`". Caveat, verbatim: "**Authentication still uses `CODEX_HOME`.**" | documented |
| Ignore user/project execpolicy rules | `--ignore-rules` | documented |
| No session file on disk | `--ephemeral` | documented |
| Config root | `CODEX_HOME` — "Sets the root for Codex state, including config, auth, logs, sessions, skills, and standalone package metadata." **"If you set it, the directory must already exist."** | documented |
| Working directory | `--cd, -C <path>` | documented |
| Model | `--model, -m` | documented |
| Sandbox | `--sandbox, -s read-only \| workspace-write \| danger-full-access` | documented |
| Approvals | `-a/--ask-for-approval on-request \| never` | documented |
| Extra roots | `--add-dir <path>` (repeatable) | documented |
| Profile | `--profile, -p` → layers `$CODEX_HOME/<name>.config.toml` over base user config | documented |
| Feature toggles | `--disable <feature>` / `--enable <feature>` (repeatable) | documented |
| Reject unknown config keys | `--strict-config` | documented |
| System prompt / instructions | `model_instructions_file` (**replaces** the built-in instructions rather than `AGENTS.md`; renamed from the now-deprecated `experimental_instructions_file`) and `developer_instructions` (injected into the session). `instructions` is "Reserved for future use". Both are config keys, so reachable per invocation via `-c` | documented |
| `AGENTS.md` discovery | `project_doc_fallback_filenames`, `project_doc_max_bytes`, `project_root_markers`, `projects.<path>.trust_level` | documented |
| MCP servers | **No `--mcp-config` equivalent.** Config only — so per invocation via `-c mcp_servers.…` or a per-run `CODEX_HOME` | documented |
| Turn/time bounds | **No `--max-turns` and no timeout flag of any kind** | documented |

A pre-created per-run `CODEX_HOME`, plus `--ignore-user-config`, plus `-c` overrides, gives Codex the isolation
Claude Code gets from `CLAUDE_CONFIG_DIR` + `--setting-sources ""`. **documented**; the `-c mcp_servers.<id>.args=[…]`
TOML-array form specifically was **not exercised** and is **unverified**.

Two useful security properties, both **documented**:

- Project-local `.codex/config.toml` "load[s] only for trusted projects" and **ignores** `openai_base_url`,
  `chatgpt_base_url`, `model_provider`, `model_providers`, `notify`, `profile`, `profiles`,
  `experimental_realtime_ws_base_url`, `otel`. **A compromised workspace cannot repoint the model provider from
  inside the repo** — a real advantage over an environment-driven override.
- `requirements.toml` is an admin-enforced layer users "can't override": `allowed_sandbox_modes`,
  `allowed_approval_policies`, `allowed_permission_profiles`, `additional_developer_instructions`, managed
  `default_permissions`, `allow_managed_hooks_only = true`, and (per the approvals page) `approved_mcp_servers` and
  `allowed_web_search_modes`. **This is the closest thing either harness has to an engine-authored policy the agent
  cannot argue with**, and it deserves a hard look in [#7](https://github.com/Teagan42/aLLMchemy/issues/7).

## 5. MCP as the tool transport

`mcp_servers.<id>` keys, all **documented** at <https://learn.chatgpt.com/docs/config-file/config-reference>:

| Group | Keys |
|---|---|
| stdio | `command`, `args`, `env`, `cwd`, `env_vars` (`array<string \| {name, source = "local" \| "remote"}>`) |
| streamable HTTP | `url`, `http_headers`, `env_http_headers`, `http_headers_helper`, `bearer_token_env_var`, `auth` (`oauth \| chatgpt`) |
| OAuth | `oauth_resource`, `scopes`, `oauth.client_id`, `oauth.client_secret`, `oauth.callback_port`, `oauth.callback_url`; globals `mcp_oauth_callback_port`, `mcp_oauth_callback_url`, `mcp_oauth_credentials_store` (`auto \| file \| keyring`), `mcp_optional_startup_grace_ms` |
| Lifecycle | `startup_timeout_sec` (default 10 s), `startup_timeout_ms`, `tool_timeout_sec` (default 60 s), `enabled`, `required`, `experimental_environment` (`local \| remote`) |
| Tool filtering | `enabled_tools`, **`disabled_tools`** ("Deny list applied after `enabled_tools`"), `default_tools_approval_mode` (`auto \| prompt \| writes \| approve`), `tools.<tool>.approval_mode`, `tools.<tool>.output_token_limit` |

Transports are **stdio and streamable HTTP**. There is no `streamable_http` sub-table and **no `excluded_tools`** —
the deny list is `disabled_tools`. `codex mcp add/get/list/login/logout/remove` exist but mutate shared config and
must not be used by the engine.

### The destructive-annotation trap

> Destructive app/MCP tool calls always require approval when the tool advertises a destructive annotation (unless the
> tool advertises a read annotation, which takes priority).

— <https://learn.chatgpt.com/docs/agent-approvals-security>

The engine's privileged tools — provision, deploy, DNS, billing, `git push` — are **exactly** the ones a well-behaved
MCP server annotates `destructiveHint: true`. Under `-a never` such a call is then rejected rather than executed.
**documented** that approval is required; **unverified** what `never` does to it specifically (the docs say "best
effort", which reads as rejection).

**Settle this with a run before designing the trust boundary.** Either the engine's tools omit the destructive
annotation — defensible, since under constraint 10 the engine's own policy check carries the whole weight anyway — or
`default_tools_approval_mode = "auto"` is set for the engine's server. Do not discover it in production.

## 6. THE LOAD-BEARING QUESTION — can Codex be restricted to only engine-provided MCP tools?

### Yes for the shell and for web search. Unverified for `apply_patch` and the plan tool.

| Built-in | Removable? | Key | Confidence |
|---|---|---|---|
| Command execution (`shell` / `exec_command` / unified exec) | **Yes** | **`features.shell_tool`** — `boolean`, "Enable command execution tools (stable; on by default)". CLI form `--disable shell_tool`, i.e. `-c features.shell_tool=false` | documented |
| Web search | **Yes** | top-level `web_search = "disabled"`, described as the way "to remove the tool"; also `tools.web_search = false`. Deprecated aliases: `features.web_search`, `features.web_search_cached`, `features.web_search_request` | documented |
| `view_image` | **Yes** | `tools.view_image = false` | documented |
| Multi-agent (`spawn_agent`, `send_input`, `resume_agent`, `wait_agent`, `close_agent`) | **Yes** | `features.multi_agent = false`; also `agents.enabled` | documented |
| Browser / Computer Use / apps | **Yes** | `browser_use.*`, `computer_use.*`, `features.apps` | documented |
| Hooks, memories, goals, code mode, skills | **Yes** | `features.hooks`, `features.memories`, `features.goals`, `features.code_mode.enabled`, `features.skill_mcp_dependency_install` | documented |
| **`apply_patch` / file editing** | **No documented key.** The pre-move `include_apply_patch_tool` does **not** appear in the current reference | — | **unverified** |
| **`update_plan` / plan tool** | **No documented key.** `include_plan_tool` does **not** appear in the current reference | — | **unverified** |
| Resumable exec / `write_stdin` | Narrowable without removing exec: managed requirements "can disable resumable processes and `write_stdin`, leaving one-shot `exec_command` available" | `features.unified_exec` under `requirements.toml` | documented |

**`features.shell_tool = false` plus `web_search = "disabled"` removes command execution and network fetch.** Both
are documented config keys reachable per invocation via `-c`. That is a materially better answer than older Codex
documentation supported, and it means the trust boundary does not have to assume an irreducible shell on either
harness.

**But the residue is not nothing.** `apply_patch` has no documented off switch and it writes files. Inside a
workspace-only container that is an acceptable capability — the workspace is the agent's scratch space by design —
but it is **not removable**, so it must be contained by the filesystem boundary rather than by configuration.
`update_plan` is inert.

### Sandbox constrains; it does not remove

This distinction decides where enforcement lives.

> The sandbox applies to spawned commands, not just to built-in file operations. If the agent runs tools like `git`,
> package managers, or test runners, those commands inherit the same sandbox boundaries.

— <https://learn.chatgpt.com/docs/sandboxing>

And, verbatim from the combinations table:

> **Read-only non-interactive (CI)** — `--sandbox read-only --ask-for-approval never` — Codex can read files and
> **run commands within the read-only sandbox**; it never asks for approval.

— <https://learn.chatgpt.com/docs/agent-approvals-security>

Read that carefully. **`read-only` + `never` leaves the shell present and able to execute read-only commands.** It is
a confinement, not a removal. If the requirement is "the agent cannot run a command at all", the lever is
`features.shell_tool = false`, not the sandbox mode. **documented.**

### The recipe — documented, NOT verified

```sh
CODEX_HOME=/run/codex-home \
codex exec --json \
  --ignore-user-config --ignore-rules --ephemeral \
  --sandbox read-only --ask-for-approval never \
  -c features.shell_tool=false \
  -c web_search="disabled" \
  -c tools.view_image=false \
  -c features.multi_agent=false \
  -c features.hooks=false \
  -c 'mcp_servers.engine.command="…"' \
  -c 'mcp_servers.engine.required=true' \
  --strict-config \
  -
```

**Every line is documented; none is verified.** Codex was not installed. Before
[#7](https://github.com/Teagan42/aLLMchemy/issues/7) relies on this, run it and assert on the tool set the model
actually receives. Because Codex emits no `init`-equivalent inventory, the assertion must be made **behaviourally** —
instruct the agent to attempt a shell command and confirm that no `command_execution` item appears.

## 7. Structured output from a completed invocation

### What is there

| Item | Confidence | Note |
|---|---|---|
| Final message | verified | `agent_message` item; also `-o/--output-last-message <path>` |
| Schema-validated final response | documented | `--output-schema <path>` |
| Token accounting | verified | `turn.completed.usage`: `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens` |
| **Cost in dollars** | **absent** | `Usage` has no cost field and no model field. Cost accounting must come from the engine's own gateway, not from the harness |
| Tool-call transcript | verified | `item.*` events: `command_execution`, `file_change`, `mcp_tool_call` (with result/error variants), `web_search`, `reasoning` |
| Exit code | verified | `0` on success, non-zero when a fatal error event was seen — source comment: "Track whether a fatal error was reported by the server so we can exit with a non-zero status for automation-friendly signaling." **No numeric taxonomy.** |

### Typed error classes — there are none

From `codex-rs/exec/src/exec_events.rs`, verbatim (**verified**, source read):

```rust
/// Fatal error emitted by the stream.
pub struct ThreadErrorEvent { pub message: String }

pub struct TurnFailedEvent { pub error: ThreadErrorEvent }

/// An error notification.
pub struct ErrorItem { pub message: String }
```

**Every Codex failure is a free-text `message: String`.** No error code, no HTTP status, no category, no `retryable`
flag. A safety or policy refusal, a 429, a 500, an expired credential and a dropped connection are
**indistinguishable except by matching English prose** — precisely the classification the PoC resorted to and
precisely what trusted code must not do.

This is the sharpest asymmetry in this document. Claude Code gives the engine `terminal_reason`, a typed `api_error`
enum, and a dedicated `system/model_refusal_no_fallback` event carrying `api_refusal_category` and
`api_refusal_explanation`. Codex gives a string.

**Constraint 17's "typed terminal class" cannot be read off a Codex invocation.** For
[#11](https://github.com/Teagan42/aLLMchemy/issues/11), the only sound place to classify a Codex failure is the
engine's own gateway, which sees the provider's HTTP status and response body directly; the harness stream serves
only to correlate.

### The one thing Codex gets right on routing

**No refusal-driven model fallback.** The current configuration reference contains no `*refusal*` key and no key that
retries a turn on a different model. The only retry knobs are counts: `model_providers.<id>.request_max_retries`
(default 4) and `.stream_max_retries` (default 5). **verified** — the full reference was searched for `*refusal*` and
`*fallback*`; the only fallback-named keys are unrelated (`project_doc_fallback_filenames`, `disable_paste_burst`,
`browser_use.default_origin_policy`, `computer_use.default_app_access`, `mcp_servers.<id>.auth` ordering).

Constraint 17 is satisfied by Codex's default behaviour and **violated** by Claude Code's. Opposite problems,
opposite fixes.

### Server-side safety monitoring the engine cannot see or stop

> GPT-6 Astra includes safety monitoring in Codex and ChatGPT Work. Monitoring runs asynchronously and can pause a
> task if it detects potentially unsafe model behavior. A pause can arrive after the activity that triggered it.

— <https://learn.chatgpt.com/docs/agent-approvals-security>

**documented.** An asynchronous, server-side, after-the-fact pause, with no documented event type and no
configuration surface. See "What we cannot control".

## 8. Containerisation and host state

| Host dependency | Breaks under confinement? | Mitigation | Confidence |
|---|---|---|---|
| `$CODEX_HOME` (default `~/.codex`): config, **auth**, logs, sessions, skills, package metadata | Needs a pre-created writable dir — "If you set it, the directory must already exist" | `CODEX_HOME=/run/codex-home`, created by the engine before launch | documented |
| `~/.codex/auth.json` (ChatGPT OAuth) | Absent in a container | Documented path is `CODEX_API_KEY` set **inline per invocation**. For ChatGPT auth, seed `auth.json` "from secure storage and persist refreshes between runs" — explicitly advanced/opt-in; "API keys are the right default for automation", and `auth.json` must be treated "like a password" | documented |
| **`--ignore-user-config` does NOT isolate auth** — "Authentication still uses `CODEX_HOME`" | Yes, if `CODEX_HOME` points at the host's | Always set `CODEX_HOME` per run | documented |
| **Linux sandbox needs `bubblewrap`** | **Likely yes.** "Codex uses the first `bwrap` executable it finds on `PATH`. If no `bwrap` executable is available, Codex falls back to a bundled helper, but that helper **requires support for unprivileged user namespace creation**." Codex warns at startup when `bwrap` is missing or the helper cannot create the namespace | Install `bubblewrap` in the image, or accept `--sandbox danger-full-access` on the grounds that the container *is* the boundary | documented |
| AppArmor `bwrap-userns-restrict` (Ubuntu 24.04/25.04) | Yes, on some hosts | Load the profile, or `sysctl kernel.apparmor_restrict_unprivileged_userns=0` | documented |
| Non-model egress: `check_for_update_on_startup`, `features.remote_plugin` + `marketplaces.*`, `feedback.enabled`, `analytics.enabled`, `otel.*` exporters, `model_catalog_url`, `tui.show_server_version_notice`, `mcp_oauth_callback_*` | Unauthorised egress | Set each off via `-c`; `analytics.enabled = false` is documented to disable the metrics exporter | documented |
| A `codex-linux-sandbox` arg0-dispatch path still runs commands "under Landlock + seccomp" | — | Two sandbox implementations coexist; the docs describe bubblewrap as the current Linux path | verified (source comment, `codex-rs/exec/src/main.rs`) / **unverified** (which applies when) |

**No official Dockerfile or devcontainer** was located, and **no required-egress domain list** is published — both
**unverified**. The documented CI posture is `openai/codex-action`, which works by "starting a Responses API proxy":
OpenAI's own answer to confined automation is a local proxy in front of the model endpoint, the same shape as the
engine's gateway.

Codex also carries an explicit warning worth repeating for R2: do not set `OPENAI_API_KEY`/`CODEX_API_KEY` as
job-level environment variables in workflows that run repository-controlled code, because "tests, build scripts,
lifecycle hooks, or a compromised action in the same job could read them"
(<https://learn.chatgpt.com/docs/non-interactive-mode>). That is the vendor stating constraint 10's rationale.

## 9. Model endpoint redirection, and what outranks it

### The mechanism

`model_providers.<id>` keys (**documented**, <https://learn.chatgpt.com/docs/config-file/config-reference>):
`name`, **`base_url`**, **`env_key`**, `env_key_instructions`, `experimental_bearer_token` ("discouraged; use
`env_key`"), `requires_openai_auth` (default false), **`wire_api`**, `query_params`, `http_headers`,
`env_http_headers`, `request_max_retries` (4), `stream_max_retries` (5), `stream_idle_timeout_ms` (300000),
`model_catalog_url`, `supports_websockets`, `supports_standalone_web_search`, `capabilities.external_web_access`,
`capabilities.remote_compaction` (`unsupported \| v2`), and `auth.command` / `auth.args` / `auth.cwd` /
`auth.refresh_interval_ms` / `auth.timeout_ms`. Selection is `model_provider` (default `openai`); `openai`, `ollama`
and `lmstudio` are reserved names. Bedrock-specific: `model_providers.amazon-bedrock.aws.profile`, `...aws.region`.

**`wire_api` now accepts only `responses`, and it is the default.** **documented.** This is a hard requirement on the
engine's gateway: it must speak the OpenAI **Responses** API, not Chat Completions. The PoC's LiteLLM gateway serves
Anthropic-shaped traffic for Claude Code; a Codex-capable gateway is a **second wire protocol**, not a second model
entry. That belongs in [#11](https://github.com/Teagan42/aLLMchemy/issues/11).

Note `auth.command`: a provider may name a **command Codex executes** to obtain credentials. That is a shell-exec
path that survives `features.shell_tool = false`, because the harness — not the model — invokes it. The engine must
never configure it and should treat its presence in any inherited config as a finding.

### What outranks it

| Fact | Confidence |
|---|---|
| `OPENAI_BASE_URL` and `OPENAI_API_KEY` are **not documented** on the environment-variables page. Whether `OPENAI_BASE_URL` overrides a configured `model_providers.<id>.base_url` is **not addressed either way**. The page scopes itself to "stable public variables Codex reads directly", excluding internal/test variables and self-chosen provider secret names — so **absence is not proof of no effect** | **unverified — the most important open question on the Codex side** |
| `env_key` names a variable **the engine chooses**: "Codex reads the variable named by that config, so the variable name itself is not a fixed Codex environment variable." The engine can pick a name no inherited environment would collide with | documented |
| Documented credential variables: `CODEX_API_KEY` ("Provides an API key to a non-interactive Codex process"), `CODEX_ACCESS_TOKEN` ("a ChatGPT or Codex access token for trusted automation"), `OPENAI_FEDERATION_RULE_ID`, `OPENAI_IDENTITY_TOKEN_FILE`, `OPENAI_WORKLOAD_IDENTITY_CONTEXT` | documented |
| TLS: `CODEX_CA_CERTIFICATE` (PEM CA bundle) **ranks above** `SSL_CERT_FILE`. Either can make the harness trust an interception CA | documented |
| Proxy variables (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`) are **not documented**; Rust HTTP clients commonly honour them | **unverified** |
| `--oss` and `--local-provider lmstudio \| ollama` reroute to a local provider **by flag alone**. The engine must never pass them, and should prefer `--strict-config` | documented |
| `chatgpt_base_url` and `openai_base_url` exist as **config** keys (and are among those ignored in project-local config) | documented |
| Whether the ambient AWS credential chain is consulted for `amazon-bedrock` was not established | **unverified** |

**Codex's endpoint control is config-first, which is structurally safer than Claude Code's.** No documented
environment variable overrides a configured provider, and a compromised workspace cannot repoint it. But the
`OPENAI_BASE_URL` question is open, and until it is answered — by reading `codex-rs` or by a run — **the engine must
treat Codex's environment with the same allowlist discipline as Claude Code's.** Assume nothing from silence.

## 10. Cancellation and timeouts

| Fact | Confidence | Source |
|---|---|---|
| `codex exec` installs **`tokio::signal::ctrl_c()`** and converts it into a graceful interrupt → `request_shutdown` → `client.shutdown()`. On Unix that handler listens for **SIGINT only**. | verified | `codex-rs/exec/src/lib.rs`, the `interrupt_tx` / `tokio::select!` loop |
| **No SIGTERM handler.** SIGTERM therefore takes its default disposition — immediate termination, with no graceful shutdown of MCP stdio children or sandbox helpers. | verified (absence in source) / **unverified** (child-reaping behaviour not exercised) | same |
| **Cancel Codex with SIGINT, then process-group SIGKILL as cleanup** — the reverse of a naive `SIGTERM` reflex, and the opposite of what worked for Claude Code. | verified (mechanism) / **unverified** (cleanup sufficiency) | same |
| **No `--max-turns`, no timeout flag.** Only `model_providers.<id>.stream_idle_timeout_ms` (300000) and MCP `startup_timeout_sec` / `tool_timeout_sec` bound anything. A wall-clock deadline must be the engine's. | documented | <https://learn.chatgpt.com/docs/developer-commands?surface=cli> |
| Sandbox helper children (`bwrap`, or the `codex-linux-sandbox` arg0 dispatch) plus MCP stdio servers: whether they are reaped on parent exit is not documented. | **unverified** | — |

---

# What we cannot control from outside the harness

**This list is the deliverable.** Everything on it must be enforced at a process or network boundary, because no
flag, config key or environment variable reaches it. Ordered by how much damage it does if left unenforced.

## A. Must be enforced at the network boundary

### A1. The model endpoint cannot be guaranteed by configuration — Claude Code

**verified.** `CLAUDE_CODE_USE_BEDROCK=1` made a call succeed against Bedrock while `ANTHROPIC_BASE_URL` pointed at a
closed port. Seven `CLAUDE_CODE_USE_*` selectors exist, each with its own base URL, plus the complete AWS, Google and
Azure credential chains embedded in the binary. There is **no flag** for the endpoint — it is environment-only.

*Enforce:* build the harness environment by **allowlist**, never inheritance. Then make it moot: no route to any
provider from inside the container except the engine's gateway. Egress-deny by default and assert at the network
layer, not by scrubbing a list of names — the list cannot be complete.

### A2. Whether `OPENAI_BASE_URL` overrides a configured provider — Codex

**unverified**, and documentation explicitly declines to say. The environment-variables page scopes itself to
variables it chooses to document and warns that absence is not proof of no effect.

*Enforce:* same as A1 — the network boundary, not the variable list. Resolve the fact by reading `codex-rs` or by a
run, but do not let the answer become load-bearing.

### A3. Server-side tools the local sandbox does not reach — Codex

**documented, verbatim:** the command-network proxy "does not filter web search, app or connector tool calls, MCP
server connections, browser or Computer Use activity, Codex cloud tasks, or **the client's model and authentication
requests**." Claude Code's server-side `web_search` / `web_fetch` are counted in `usage.server_tool_use` but whether
`--tools ""` suppresses the model's ability to request them was **not isolated** (**unverified**).

*Enforce:* assume both harnesses can cause fetches the engine never sees. Egress policy belongs to the container's
network namespace. Also set `web_search = "disabled"` (Codex) and `CLAUDE_CODE_DISABLE_WEB_FETCH` /
`CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` (Claude Code) as defence in depth — not as the boundary.

### A4. Non-model egress: telemetry, auto-update, feature flags, plugin marketplaces

Both harnesses reach the network for reasons unrelated to the task. Both document off switches
(`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`; `check_for_update_on_startup`, `analytics.enabled`, `feedback.enabled`,
`otel.*`, `features.remote_plugin`). **Neither publishes a required-egress domain list** (**unverified** for both).

*Enforce:* default-deny egress and discover the true allowlist empirically. Do not derive it from documentation that
does not exist.

## B. Must be enforced at the process boundary

### B1. No usable wall-clock bound inside either harness

Claude Code has `--max-turns`, `--max-budget-usd` and `API_TIMEOUT_MS`; Codex has neither a turn cap nor any timeout
flag. Neither bounds total elapsed time.

*Enforce:* the engine owns the deadline, and kills the process group.

### B2. Cancellation semantics are undocumented, and differ between harnesses

- Claude Code: signal handling is **not documented** (**unverified**). SIGTERM did reap the stdio MCP child in one
  observed run (**verified** for that case).
- Codex: **SIGINT only** is handled, per source. **No SIGTERM handler** (**verified** by absence). A SIGTERM kills
  the parent outright and may orphan `bwrap` or MCP children (**unverified**).

*Enforce:* per-harness cancellation in the adapter — SIGINT for Codex, SIGTERM for Claude Code — then a process-group
SIGKILL after a grace period, in a PID namespace so nothing can survive it. The PoC's process-group kill was right;
its single signal choice was not.

### B3. `apply_patch` cannot be removed from Codex

**unverified** that any key disables it; no key appears in the current reference. It writes files.

*Enforce:* workspace-only filesystem. Read-only bind mounts everywhere else. Do not rely on the sandbox mode for
this — `read-only` + `never` still lets the shell run read-only commands, so the mode is not a file-write guarantee
either way.

### B4. Irreducible built-in surface in Claude Code

**verified:** with `CLAUDE_CONFIG_DIR` fresh, `--restricted`, `--setting-sources ""` and `--tools ""`, three
`builtin` plugins, 16 skills, 44 slash commands and 5 agent definitions still load. **No flag removes them.**
Benign *today* only because `Task` and `Skill` are absent from `init.tools`.

*Enforce:* assert `init.tools` on every invocation and fail the step if it is not exactly the engine's MCP tool list.
Treat the check as necessary, not sufficient — see B5.

### B5. `init.tools` is not a complete tool inventory

**unverified.** Documentation says `--tools ""` removes `EndConversation` "only when no MCP tools remain", implying it
survives alongside engine MCP tools; `init.tools` did not name it. Either the inventory is incomplete or docs and
implementation diverge.

*Enforce:* behavioural assertion in the conformance suite — attempt a shell command and a network fetch in a
simulation step and assert that no corresponding tool-use event appears. Do not derive the tool set from a field
whose completeness is unproven.

### B6. Codex emits no tool inventory at all

**verified** by reading the event enum: there is no `init`-equivalent event. The engine cannot read back what tool
set the model received.

*Enforce:* the same behavioural assertion as B5, as the **only** available check on Codex.

## C. Must be absorbed by engine policy, because the harness decides first

### C1. Claude Code retries a safety refusal on another model by default

**documented.** `system/model_refusal_fallback` is emitted when a refused turn "is retried once on a fallback model",
and with `scope: "session"` the swap persists for the session. This directly violates constraint 17.

Off switches: `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1` and the `switchModelsOnFlag` setting (**documented**);
`CLAUDE_CODE_DISABLE_REFUSAL_RETRY` and `CLAUDE_CODE_REFUSAL_FALLBACK_CATCH_ALL` (**unverified** — binary only).

*Enforce:* set the documented switch, leave `--fallback-model` unset, and have the gateway reject a second request
for a turn whose first attempt ended in a refusal. Treat observing `system/model_refusal_fallback` as evidence the
policy was already breached. **Belt and braces, because the harness decides before the engine is consulted.**

### C2. Codex has no typed failure class whatsoever

**verified** from source: `ThreadErrorEvent { message: String }`, `TurnFailedEvent { error: ThreadErrorEvent }`,
`ErrorItem { message: String }`. Exit code is 0 or non-zero with no taxonomy. A refusal, a rate limit, a 5xx, an
expired credential and a dropped connection are **indistinguishable except by English prose**.

*Enforce:* classify at the gateway, from the provider's HTTP status and body. The harness stream correlates; it does
not classify. **Constraint 17's typed terminal class cannot be sourced from a Codex invocation.**

### C3. Claude Code's typed error classes are internal and additive

**documented.** The `api_error` enum is marked `@internal`, parsed with `.catch(undefined)`, and its own description
says to "treat an unknown value as absent". `result.subtype` is not an error discriminator — a transport failure
produced `subtype: "success"` with `is_error: true` (**verified**).

*Enforce:* classify on `is_error` + `terminal_reason`; map the `api_error` enum defensively and **fail closed on an
unrecognised value** (constraint 24). Never key on `subtype` alone.

### C4. `safety_stops == 0` does not prove no refusal

**documented.** The field's own description lists four refusal-shaped events it does *not* count, including DLP
denials, cloud-provider guardrail blocks, and content-filter stops Claude Code answers by re-streaming — "so 0 does
not rule one out".

*Enforce:* positive signal only. A refusal verdict must come from `system/model_refusal_no_fallback` or from the
gateway, never from `safety_stops == 0`.

### C5. Server-side asynchronous safety monitoring — Codex

**documented.** "Monitoring runs asynchronously and can pause a task … A pause can arrive after the activity that
triggered it." No documented event type, no configuration surface.

*Enforce:* nothing can. The engine's step model must tolerate a turn that stalls and ends with no explanation, and
the completion predicate (constraint 9) must be the arbiter — not the harness's report. This is an argument for
engine-evaluable predicates independent of harness output, and it should be cited in
[#7](https://github.com/Teagan42/aLLMchemy/issues/7).

### C6. Codex requires MCP approval for destructively-annotated tools

**documented** that approval is required; **unverified** what `-a never` does to such a call. The engine's privileged
tools are exactly the ones that would carry the annotation.

*Enforce:* decide deliberately — omit the annotation on engine tools (defensible: the engine's own policy check is
the real gate under constraint 10), or set `default_tools_approval_mode = "auto"` for the engine's server. Verify by
a run before [#7](https://github.com/Teagan42/aLLMchemy/issues/7) depends on it.

### C7. Cost is an estimate on one harness and absent on the other

**documented / verified.** Claude Code's `total_cost_usd` is a "client-side cost estimate, which can differ from your
bill"; its `usage` covers the main loop only, with `modelUsage` preferred. Codex reports tokens with **no cost field
and no model field**.

*Enforce:* the resource ledger's cost rows must come from the engine's gateway, not from harness output. Harness
numbers are corroboration (constraint 9's posture), never the source of truth. This is also what makes
`--max-budget-usd` unsuitable as the spend guard.

## D. Residual, lower-consequence

### D1. `--output-format json` shape is not stable across flag combinations — Claude Code

**verified** (behaviour) / **unverified** (rule). An array with one flag set, a bare object with another.

*Enforce:* use `stream-json` and key on `type`, or normalise at the boundary.

### D2. Malformed `--settings` fails open under `-p` — Claude Code

**verified** from help text: "Settings files that fail validation are silently ignored in this mode."

*Enforce:* the engine validates its own settings payload before handing it over, and asserts the effect it expected
in `init`.

### D3. Codex documentation moved and the in-repo docs are stubs

**verified.** `openai/codex/docs/*.md` now redirect to `learn.chatgpt.com`. Flags move between versions:
`--full-auto` is removed, `untrusted` is retired, `on-failure` is deprecated, `codex mcp-server` is gone.

*Enforce:* a startup capability probe per harness version, as the PoC's `run-codex.sh` already did by parsing
`--help`. Pin the harness version per run and record it in the journal.

### D4. Claude Code auxiliary model calls use a different alias

**documented.** `ANTHROPIC_DEFAULT_HAIKU_MODEL` also governs "background functionality"; `CLAUDE_CODE_SUBAGENT_MODEL`
exists in the binary but is undocumented (**unverified**).

*Enforce:* the gateway must serve every alias the harness may ask for, as the PoC's `CHAIN_WILDCARD` entry already
did. A 400 on an unexpected alias is a silent failure mode.

### D5. Linux sandbox prerequisites may not hold in a container — Codex

**documented.** `bwrap` on `PATH`, or a bundled helper "requires support for unprivileged user namespace creation";
AppArmor on Ubuntu 24.04/25.04 can block it.

*Enforce:* either install `bubblewrap` in the image, or accept `--sandbox danger-full-access` on the explicit basis
that the container is the boundary and `features.shell_tool = false` removes the shell anyway. Record which, and why.

---

## Summary verdict

| Question | Claude Code | Codex |
|---|---|---|
| Restrictable to only engine MCP tools? | **Yes — verified by execution** | **Yes per documentation** (`features.shell_tool=false`, `web_search="disabled"`); `apply_patch` not removable; **unverified**, nothing was run |
| Fresh per-step invocation (R1) | Yes — `-p`, `--no-session-persistence`, `--session-id` | Yes — `codex exec`, `--ephemeral` |
| Per-invocation config without touching shared files (R2/R3) | Yes — flags + `CLAUDE_CONFIG_DIR` + `--setting-sources ""` | Yes — `-c`, `--ignore-user-config`, `CODEX_HOME` (**auth still reads `CODEX_HOME`**) |
| Non-interactive, cannot block (R5) | Yes — `--permission-prompts none`, verified auto-deny | Yes per documentation — `-a never`, "best effort" |
| Endpoint redirection | Env-only, and **seven provider selectors outrank it** | Config-first and safer; `OPENAI_BASE_URL` precedence **unverified** |
| Wire protocol the gateway must speak | Anthropic Messages | **OpenAI Responses only** (`wire_api`) |
| Typed failure class (R4) | Rich: `terminal_reason`, `api_error` enum, refusal events with category | **None — a bare string** |
| Refusal never retried elsewhere (R4) | **Violated by default**; documented off switch exists | Satisfied by default |
| Cost accounting | Per-model `costUSD`, but a client-side **estimate** | Tokens only, **no cost** |
| Tool inventory readable | `init.tools` (**completeness unproven**) | **None** |
| Programmatic entry point | TS SDK, Python SDK, or CLI + stream-json | TS SDK, or CLI + JSONL. **No Python SDK** |
| Go | No SDK; CLI + stream-json; loses in-process MCP, `canUseTool`, typed `interrupt()` | No SDK; CLI + JSONL; **loses nothing Python would have had** |
| Clean cancellation | SIGTERM (reaped MCP child in test); semantics undocumented | **SIGINT only**; no SIGTERM handler |
