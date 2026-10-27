#!/usr/bin/env bash
# Gate `build` — zero type errors, zero lint errors, production build succeeds, and no new
# suppression added to get there. A green build bought with @ts-ignore is a red build.
set -uo pipefail
. "$(dirname -- "$0")/_lib.sh"

head2 'gate build'

cd "$PROJECT_DIR" || { bad "cannot enter $PROJECT_DIR"; finish build; }

if ! file_present "$PROJECT_DIR/package.json"; then
  bad 'gate build has no runnable check: the owning agent must create package.json with typecheck, lint and build scripts'
  finish build
fi

run_sh "${INSTALL_CMD:-pnpm install --frozen-lockfile}"
run_sh "${TYPECHECK_CMD:-pnpm typecheck}"
run_sh "${LINT_CMD:-pnpm lint}"
run_sh "${BUILD_CMD:-pnpm build}"

SUPPRESSIONS='@ts-ignore|@ts-nocheck|eslint-disable'

# Prefer the diff: a suppression that predates this run is the operator's, not the agent's.
# Without a base ref there is nothing to diff against, so the absolute count is used and the
# allowance stays 0 — which is the honest reading of "no suppression added to pass this gate".
base="${BUILD_BASE_REF:-}"
if [ -z "$base" ]; then
  for candidate in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then base=$candidate; break; fi
  done
fi

if [ -n "$base" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  added=$(git diff "$base" -- . 2>/dev/null | grep -E '^\+' | grep -Ec "$SUPPRESSIONS")
  if [ "${added:-0}" -eq 0 ]; then
    ok "no suppression added since $base"
  else
    bad "$added suppression line(s) added since $base"
    git diff "$base" -- . 2>/dev/null | grep -E '^\+' | grep -E "$SUPPRESSIONS" | head -40
  fi
else
  found=$(grep -REc "$SUPPRESSIONS" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
    --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.next . 2>/dev/null \
    | awk -F: '{ n += $NF } END { print n + 0 }')
  if [ "${found:-0}" -eq 0 ]; then
    ok "no suppression anywhere in the tree (no base ref to diff against)"
  else
    bad "$found suppression(s) in the tree and no base ref to prove they predate this run"
    grep -REn "$SUPPRESSIONS" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
      --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.next . 2>/dev/null | head -40
  fi
fi

finish build
