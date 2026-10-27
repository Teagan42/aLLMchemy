#!/usr/bin/env bash
# Claude Code launcher. The no-questions guard runs as a Stop hook from .claude/settings.json,
# so this only has to start the run with permissions that will not stall it.
#
# acceptEdits is deliberately not used: it stalls on the first unapproved shell command,
# which is a human interaction by another name.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "claude not found; set CLAUDE_BIN" >&2; exit 1; }

# Override with CLAUDE_FLAGS="--permission-mode default" to approve interactively instead.
FLAGS="${CLAUDE_FLAGS---permission-mode bypassPermissions}"

exec "$CLAUDE_BIN" $FLAGS "$(cat <<'EOF'
Read AGENTS.md, then playbook/00-kickoff.md, and execute the run described there.
No human is available. Never ask a question; resolve every unknown with the decision
ladder in playbook/autonomy-contract.md and record it in DECISIONS.md.
EOF
)"
