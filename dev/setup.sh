#!/usr/bin/env bash
# Bootstrap and doctor for a fresh clone. `make setup`.
#
#   dev/setup.sh            check tools, repair exec bits, create artifacts/
#   dev/setup.sh --hooks    the above, plus install the git pre-commit hook
#   dev/setup.sh --force    overwrite an existing pre-commit hook
#
# Installs nothing globally and writes nothing outside this repo. This package's whole
# premise is that a generated product has no install step (template/billing-core/README.md),
# so the package that generates it cannot acquire one either. There is no package.json here
# and there must not be.
#
# Idempotent: run it as often as you like. Exits nonzero only if a REQUIRED tool is missing.

set -uo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
cd "$ROOT" || exit 2

NODE_MIN_MAJOR=18

install_hooks=0
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hooks) install_hooks=1 ;;
    --force) force=1 ;;
    -h|--help)
      printf 'usage: dev/setup.sh [--hooks] [--force]\n\n'
      printf '  --hooks   install dev/hooks/pre-commit into this clone\n'
      printf '  --force   replace an existing pre-commit hook file\n\n'
      printf 'Checks tools, repairs exec bits, creates artifacts/. Installs nothing globally.\n'
      exit 0
      ;;
    *) printf 'dev/setup.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/allmchemy-setup-XXXXXX") || exit 2
# Separate handlers: a signal trap that only cleans up and returns leaves the run going.
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT
trap 'rm -rf "$TMP"; exit 143' TERM
trap 'rm -rf "$TMP"; exit 129' HUP

missing=0
warns=0
ok()   { printf '  OK      %-14s %-18s %s\n' "$1" "$2" "${3:-}"; }
bad()  { printf '  MISSING %-14s %-18s %s\n' "$1" '-' "$2"; missing=$((missing + 1)); }
absent() { printf '  ABSENT  %-14s %-18s %s\n' "$1" '-' "$2"; warns=$((warns + 1)); }
warn() { printf '  WARN    %-14s %-18s %s\n' "$1" "$2" "$3"; warns=$((warns + 1)); }

# First dotted-number token anywhere in the output. Positional awk does not survive these:
# `uvx --version` appends a build triple, and `ollama --version` prefixes two warning lines
# when no daemon is running.
first_version_token() {
  tr -s ' \t' '\n\n' | sed -E 's/[^0-9A-Za-z.()+-]//g' \
    | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

version_of() {  # tool -> one short version token
  case "$1" in
    bash)       /bin/bash -c 'printf %s "$BASH_VERSION"' 2>/dev/null ;;
    node)       node --version 2>/dev/null ;;
    git)        git --version 2>&1 | first_version_token ;;
    jq)         jq --version 2>&1 | first_version_token ;;
    shellcheck) shellcheck --version 2>&1 | first_version_token ;;
    uvx)        uvx --version 2>&1 | first_version_token ;;
    ollama)     ollama --version 2>&1 | first_version_token ;;
  esac
}

printf 'dev/setup.sh — %s\n' "$ROOT"

printf '\nRequired — nothing in this repo runs without these\n'

if [ -x /bin/bash ]; then
  bver=$(version_of bash)
  # Every script here targets this bash, not whichever newer one is on PATH. GNU bash 3.2 on
  # macOS is the floor: no mapfile, no associative arrays, no ${v^^}. dev/lint.sh enforces it.
  ok bash "${bver:-unknown}" 'portability floor; scripts are parsed under /bin/bash'
else
  bad bash 'no /bin/bash — the portability floor is unavailable'
fi

if command -v node > /dev/null 2>&1; then
  nver=$(version_of node)
  nmaj=${nver#v}
  nmaj=${nmaj%%.*}
  if [ "${nmaj:-0}" -ge "$NODE_MIN_MAJOR" ] 2>/dev/null; then
    ok node "$nver" ">= $NODE_MIN_MAJOR required"
  else
    bad node "node $nver is below the required major $NODE_MIN_MAJOR"
  fi
  if [ "${nmaj:-0}" -lt 23 ] 2>/dev/null; then
    # `node --test <dir>` finds nothing and exits 0 before node 23, so a directory-form test
    # command reports green having run no tests. dev/test.sh uses the glob form for this reason.
    warn node "$nver" '`node --test <dir>` needs 23+; the glob form is used instead'
  fi
else
  bad node 'install node 18 or newer'
fi

if command -v git > /dev/null 2>&1; then
  ok git "$(version_of git)" 'secret-scan.sh scans history, not just the tree'
else
  bad git 'install git; secret-scan.sh cannot scan history without it'
fi

if command -v jq > /dev/null 2>&1; then
  ok jq "$(version_of jq)" 'hook payloads and litellm responses'
else
  bad jq 'install jq; the Claude hooks parse their JSON payloads with it'
fi

printf '\nOptional — what you lose when absent\n'

if command -v shellcheck > /dev/null 2>&1; then
  ok shellcheck "$(version_of shellcheck)" 'full lint depth'
else
  absent shellcheck 'dev/lint.sh notes and continues; shell bugs land uncaught'
fi

if command -v uvx > /dev/null 2>&1; then
  ok uvx "$(version_of uvx)" 'gateway/up.sh runs LiteLLM'
else
  absent uvx 'no model-failover gateway; the cloud tier loses per-request failover'
fi

if command -v ollama > /dev/null 2>&1; then
  ok ollama "$(version_of ollama)" 'local model tier available'
else
  absent ollama 'no local tier; model_fallback: local degrades to cloud-only'
fi

printf '\nRepository\n'

# A fresh clone from a filesystem that dropped the mode bits leaves every launcher
# non-executable, and the first symptom is a bare "permission denied" from verify.sh.
#
# Tracked files only, via git ls-files. A `find` walk marked untracked downloads executable
# too, which is a setup script deciding that arbitrary content may run.
#
# `chmod u+x`, never `chmod +x`: +x grants group and other as well, so it widened a 0600
# private file to 0711. Only the owner needs to run a launcher.
fixed=0
checked=0
tracked=1
if ! git ls-files -z > "$TMP/tracked" 2>/dev/null || [ ! -s "$TMP/tracked" ]; then
  tracked=0
  find . -name .git -prune -o -name .worktrees -prune -o -name artifacts -prune \
    -o -name node_modules -prune -o -type f -print0 2>/dev/null > "$TMP/tracked"
fi
: > "$TMP/repaired"
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  [ "$(head -c 2 -- "$f" 2>/dev/null)" = '#!' ] || continue
  checked=$((checked + 1))
  if [ ! -x "$f" ]; then
    chmod u+x "$f" && { fixed=$((fixed + 1)); printf '%s\n' "$f" >> "$TMP/repaired"; }
  fi
done < "$TMP/tracked"
# Keyed on the shebang, never the .sh extension: gateway/env.sh is sourced and must stay
# non-executable.
scope='tracked'
[ "$tracked" -eq 1 ] || scope='untracked tree — not a git repo'
printf '  OK      %-14s %-18s %s\n' 'exec bits' "$checked script(s)" "$fixed repaired ($scope)"
# Name every path. A silent mode change is the kind of thing nobody finds until review.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  printf '  OK      %-14s %-18s %s\n' '' 'chmod u+x' "$f"
done < "$TMP/repaired"

if mkdir -p artifacts 2>/dev/null; then
  printf '  OK      %-14s %-18s %s\n' 'artifacts/' 'present' 'verify.sh and launcher transcripts land here'
else
  printf '  WARN    %-14s %-18s %s\n' 'artifacts/' 'uncreatable' 'verify.sh will fail at startup'
  warns=$((warns + 1))
fi

for pat in 'artifacts/' '.env*'; do
  if grep -qF -- "$pat" .gitignore 2>/dev/null; then
    printf '  OK      %-14s %-18s %s\n' '.gitignore' "$pat" 'ignored'
  else
    printf '  WARN    %-14s %-18s %s\n' '.gitignore' "$pat" 'NOT ignored — credentials or run output are stageable'
    warns=$((warns + 1))
  fi
done

printf '\nGit hook\n'

hookdir=$(git rev-parse --git-path hooks 2>/dev/null)
src="$ROOT/dev/hooks/pre-commit"
if [ -z "$hookdir" ]; then
  printf '  SKIP    %-14s %-18s %s\n' 'pre-commit' 'not a git repo' 'nothing to install into'
elif [ "$install_hooks" -eq 0 ]; then
  # Never silent. A hook that appears in someone's clone without being asked for is a
  # surprise 20-second delay on every commit, and the first guess is that git is broken.
  if [ -e "$hookdir/pre-commit" ]; then
    printf '  OK      %-14s %-18s %s\n' 'pre-commit' 'installed' "$hookdir/pre-commit"
  else
    printf '  OFFER   %-14s %-18s %s\n' 'pre-commit' 'not installed' 'install with: make hooks'
  fi
else
  mkdir -p "$hookdir" 2>/dev/null
  if [ -e "$hookdir/pre-commit" ] && [ ! -L "$hookdir/pre-commit" ] && [ "$force" -eq 0 ]; then
    printf '  WARN    %-14s %-18s %s\n' 'pre-commit' 'exists' 'a real file is already there; re-run with --force'
    warns=$((warns + 1))
  else
    # Absolute symlink, so the hook tracks edits to dev/hooks/pre-commit and works from a
    # linked worktree, where .git is a file and a relative link would dangle.
    if ln -sf "$src" "$hookdir/pre-commit" 2>/dev/null; then
      printf '  OK      %-14s %-18s %s\n' 'pre-commit' 'installed' "$hookdir/pre-commit -> $src"
    else
      printf '  WARN    %-14s %-18s %s\n' 'pre-commit' 'failed' "cannot write $hookdir"
      warns=$((warns + 1))
    fi
  fi
fi

printf '\n'
if [ "$missing" -gt 0 ]; then
  printf '%s required tool(s) missing. Install them, then re-run `make setup`.\n' "$missing"
  exit 1
fi
[ "$warns" -eq 0 ] || printf '%s advisory warning(s) above — none blocks development.\n' "$warns"
printf 'setup ok. Next: `make check` (lint then test). `make test ARGS=--quick` for the fast loop.\n'
printf 'Developing this package rather than running the factory? Read DEVELOPING.md.\n'
exit 0
