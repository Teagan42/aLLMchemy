# CLAUDE.md

Read `AGENTS.md` first. Its opening section is a mode router: it decides whether you are
developing this package or running the factory for an operator. Settle that before reading
further, because the two modes have opposite rules about asking questions.

If you are developing the package, read `DEVELOPING.md` and ignore the rest of this file —
everything below describes an unattended run.

`AGENTS.md` holds the autonomy constraint, the playbook index, and the rules that apply on
every harness. This file adds only what is specific to Claude Code.

## Claude Code specifics

- `playbook/roles/*.md` are exposed as subagents in `.claude/agents/`. Use them: dispatch
  per phase and run Phase 4 (billing) and Phase 5 (surface) concurrently in one message.
- The playbook documents are exposed as skills in `.claude/skills/`. Both the skill files
  and the agent files are thin pointers; the authoritative text is under `playbook/`.
- `AskUserQuestion` and `ExitPlanMode` are denied in this repo's `.claude/settings.json`,
  which is the project settings file only for a session rooted **here**. A session rooted
  one directory up loads that directory's settings instead; nested `.claude/settings.json`
  files are not a settings source. Measured, not assumed — see the lab README. Either way
  the denial is deliberate: do not look for a way around it.
- A `Stop` and `SubagentStop` hook rejects any final message that interrogates the user.
  Rewriting costs budget, so apply the decision ladder before closing rather than after
  being blocked.

## Launching

This spends real money and provisions real infrastructure. There is no dry-run flag. Never
run it to try something out — `DEVELOPING.md` says what to use instead.

```sh
./bin/run-claude.sh
```

`bypassPermissions` is the default because `acceptEdits` stalls on the first unapproved
shell command, which is a human interaction by another name. Nothing will stop to confirm.
