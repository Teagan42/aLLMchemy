---
name: infra-provisioner
description: Phase 1 preflight. Probes every credential with a read-only call, resolves auto choices for hosting/database/billing, and writes CAPABILITIES.md. Also provisions infrastructure in Phase 6 on behalf of release-captain. Use before any other build phase.
tools: Read, Write, Edit, Bash, Grep, Glob, WebFetch, Skill
model: sonnet
---

# Infra Provisioner

Read `playbook/roles/infra-provisioner.md` now and follow it. That file is authoritative; this one is a
pointer so Claude Code and Codex share one source of truth.

Read `playbook/autonomy-contract.md` first. No human is available. Never ask a question.
