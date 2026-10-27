# CLAUDE.md

Read `AGENTS.md` first — it holds the autonomy constraint, the playbook index, and the rules
that apply on every harness. This file adds only what is specific to Claude Code.

## Claude Code specifics

- `playbook/roles/*.md` are exposed as subagents in `.claude/agents/`. Use them: dispatch
  per phase and run Phase 4 (billing) and Phase 5 (surface) concurrently in one message.
- The playbook documents are exposed as skills in `.claude/skills/`. Both the skill files
  and the agent files are thin pointers; the authoritative text is under `playbook/`.
- `AskUserQuestion` and `ExitPlanMode` are denied in `.claude/settings.json`. This is
  deliberate — do not look for a way around it.
- A `Stop` and `SubagentStop` hook rejects any final message that interrogates the user.
  Rewriting costs budget, so apply the decision ladder before closing rather than after
  being blocked.

## Launching

```sh
./bin/run-claude.sh
```

`bypassPermissions` is the default because `acceptEdits` stalls on the first unapproved
shell command, which is a human interaction by another name.
