#!/usr/bin/env bash
# Static checks for developing this package. `make lint`.
#
#   dev/lint.sh            every check
#   dev/lint.sh --list     check names
#   dev/lint.sh --only portability
#
# Catches the three things review misses on this tree: GNU-only shell that passes on Linux
# and silently breaks on the macOS bash 3.2 floor, a script that ships without its exec bit,
# and a .claude pointer that has grown into a second copy of a playbook document.
#
# Never fails merely because an optional tool is absent — a lint that is red by default is
# a lint nobody reads.

set -uo pipefail

CHECKS='syntax shellcheck portability selfcheck execbits pointers'

# Floors for the counting checks. Raise them as the tree grows; never lower one to make a
# run green. A check that measured nothing used to report PASS with a count of 0.
MIN_SCANNED=35
MIN_POINTERS=10

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
cd "$ROOT" || exit 2

TMP=$(mktemp -d "${TMPDIR:-/tmp}/allmchemy-lint-XXXXXX") || exit 2
# Separate handlers: a signal trap that only cleans up leaves the run going, so Ctrl-C is
# ignored and the summary still prints over a deleted temp directory.
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 130' INT
trap 'rm -rf "$TMP"; exit 143' TERM
trap 'rm -rf "$TMP"; exit 129' HUP

# `error` only. The tree carries two known-benign warnings (an intentionally unused export
# in gates/_lib.sh, a sk_test_* case pattern in preflight.sh) that are not worth rewriting.
# Raise this to warning or style to audit them: SHELLCHECK_SEVERITY=style dev/lint.sh
SHELLCHECK_SEVERITY="${SHELLCHECK_SEVERITY:-error}"

# .claude/skills/*/SKILL.md and .claude/agents/*.md are ~600-byte pointers at playbook/.
# Anything near this cap has started duplicating the authoritative text, which then drifts.
POINTER_MAX_BYTES="${POINTER_MAX_BYTES:-2000}"

fails=0
notes=0
pass() { printf '  PASS  %-46s %s\n' "$1" "${2:-ok}"; }
fail() { printf '  FAIL  %-46s %s\n' "$1" "${2:-failed}"; fails=$((fails + 1)); }
note() { printf '  NOTE  %-46s %s\n' "$1" "${2:-}"; notes=$((notes + 1)); }

describe() {
  case "$1" in
    syntax)      printf 'bash -n under /bin/bash, node --check' ;;
    shellcheck)  printf "shellcheck at severity $SHELLCHECK_SEVERITY, skipped when absent" ;;
    portability) printf 'GNU-only constructs that break on macOS bash 3.2 or BSD make' ;;
    selfcheck)   printf 'lint.sh re-run under /bin/bash emits no stderr of its own' ;;
    execbits)    printf 'shebang implies the exec bit; sourced fragments must not have it' ;;
    pointers)    printf '.claude pointers stay pointers, not content copies' ;;
  esac
}

PRUNE='-name .git -prune -o -name .worktrees -prune -o -name artifacts -prune -o -name node_modules -prune -o'

all_files() {
  # shellcheck disable=SC2086  # PRUNE is a find expression; word splitting is the point.
  find . $PRUNE -type f -print | sort > "$TMP/files"
}

# Shell is identified by extension OR shebang, so an extensionless hook is checked too.
classify_sources() {
  all_files
  : > "$TMP/sh.list"
  : > "$TMP/mjs.list"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
      *.mjs) printf '%s\n' "$f" >> "$TMP/mjs.list"; continue ;;
      *.sh)  printf '%s\n' "$f" >> "$TMP/sh.list"; continue ;;
    esac
    head -1 -- "$f" 2>/dev/null | grep -qE '^#!.*(bash|/sh)( |$)' \
      && printf '%s\n' "$f" >> "$TMP/sh.list"
  done < "$TMP/files"
  return 0
}

# ---------------------------------------------------------------------------- checks

check_syntax() {
  classify_sources
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if /bin/bash -n "$f" > "$TMP/out" 2>&1; then n=$((n + 1)); else
      fail "bash -n $f" 'parse error'; sed 's/^/        | /' "$TMP/out"
    fi
  done < "$TMP/sh.list"
  if [ "$n" -ge 25 ]; then pass 'bash -n' "$n file(s)"; else fail 'bash -n' "only $n file(s)"; fi

  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if node --check "$f" > "$TMP/out" 2>&1; then n=$((n + 1)); else
      fail "node --check $f" 'parse error'; sed 's/^/        | /' "$TMP/out"
    fi
  done < "$TMP/mjs.list"
  if [ "$n" -ge 8 ]; then pass 'node --check' "$n file(s)"; else fail 'node --check' "only $n file(s)"; fi
}

check_shellcheck() {
  if ! command -v shellcheck > /dev/null 2>&1; then
    note 'shellcheck absent' 'lint depth reduced; brew install shellcheck'
    return
  fi
  classify_sources
  # xargs, not argv expansion: the list is read from a file so a path with a space survives.
  if xargs shellcheck -S "$SHELLCHECK_SEVERITY" -- < "$TMP/sh.list" > "$TMP/out" 2>&1; then
    pass "shellcheck -S $SHELLCHECK_SEVERITY" "$(grep -c . "$TMP/sh.list") file(s)"
  else
    fail "shellcheck -S $SHELLCHECK_SEVERITY" 'findings below'
    sed 's/^/        | /' "$TMP/out"
  fi
}

# The tables live in dev/port-rules.txt and dev/make-rules.txt, not in a heredoc here. A
# heredoc forced this file to exempt itself from its own scan, and that exemption was the
# one hole in the portability floor.
rules_of() {  # rule file -> ERE@reason lines, comments and blanks dropped
  [ -f "$1" ] || return 1
  grep -vE '^[[:space:]]*(#|$)' "$1"
}

# Strips comments before matching. The repo documents each banned construct in a comment
# explaining why it is banned, so an un-stripped grep flags its own documentation.
strip_comments() {
  case "$1" in
    *.mjs) sed -e 's|^[[:space:]]*//.*$||' -e 's|[[:space:]]//.*$||' "$1" ;;
    *)     sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1" ;;
  esac
}

scan_with() {  # rule file, list file -> appends to $TMP/hits
  rules_of "$1" > "$TMP/rules" || { fail 'portability' "missing rule file $1"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    strip_comments "$f" > "$TMP/stripped"
    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      pat=${rule%%@*}
      reason=${rule#*@}
      grep -nE -e "$pat" "$TMP/stripped" 2>/dev/null \
        | awk -F: -v f="$f" -v r="$reason" '{ printf "%s:%s  %s\n", f, $1, r }' >> "$TMP/hits"
    done < "$TMP/rules"
  done < "$2"
  return 0
}

check_portability() {
  classify_sources
  cat "$TMP/sh.list" "$TMP/mjs.list" > "$TMP/all.list"
  printf 'Makefile\n' > "$TMP/make.list"
  : > "$TMP/hits"

  scan_with "$ROOT/dev/port-rules.txt" "$TMP/all.list" || return
  scan_with "$ROOT/dev/make-rules.txt" "$TMP/make.list" || return

  nfiles=$(grep -c . "$TMP/all.list")
  nrules=$(( $(rules_of "$ROOT/dev/port-rules.txt" | grep -c .) \
           + $(rules_of "$ROOT/dev/make-rules.txt" | grep -c .) ))
  if [ -s "$TMP/hits" ]; then
    fail 'portability' "$(grep -c . "$TMP/hits") hit(s)"
    sed 's/^/        | /' "$TMP/hits"
  elif [ "$nfiles" -lt "$MIN_SCANNED" ]; then
    fail 'portability' "only $nfiles file(s) scanned, expected >= $MIN_SCANNED"
  else
    pass 'portability' "$nrules rules, $((nfiles + 1)) file(s)"
  fi
}

# Runs this script against itself under the bash 3.2 floor and fails on any stderr of its
# own. A GNU-ism in the linter breaks at runtime, writes to stderr, and the report still
# said `lint clean` — the rules were fine, the reporting was not.
check_selfcheck() {
  # Guard, not decoration: an inner run must never reach this check again.
  [ -z "${LINT_SELFCHECK:-}" ] || { pass 'self-check' 'nested run, skipped'; return; }
  LINT_SELFCHECK=1 /bin/bash "$ROOT/dev/lint.sh" --only portability --only execbits \
    > "$TMP/self.out" 2> "$TMP/self.err"
  rc=$?
  if [ -s "$TMP/self.err" ]; then
    fail 'lint.sh runs without stderr' 'its own diagnostics below'
    sed 's/^/        | /' "$TMP/self.err"
  elif [ "$rc" -ne 0 ]; then
    fail 'lint.sh re-run under /bin/bash' "exit $rc"
    sed 's/^/        | /' "$TMP/self.out"
  else
    pass 'lint.sh runs clean under /bin/bash' 'no stderr, exit 0'
  fi
}

has_shebang() { [ "$(head -c 2 -- "$1" 2>/dev/null)" = '#!' ]; }

check_execbits() {
  # Keyed on the shebang, not the extension. gateway/env.sh is a .sh with no shebang: it is
  # sourced, and making it executable invites `./env.sh`, which sets variables in a shell
  # that exits immediately. Both directions are enforced for that reason.
  all_files
  : > "$TMP/hits"
  shebanged=0
  fragments=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if has_shebang "$f"; then
      shebanged=$((shebanged + 1))
      [ -x "$f" ] || printf '%s  has a shebang but is not executable (chmod +x)\n' "$f" >> "$TMP/hits"
    else
      case "$f" in
        *.sh)
          fragments=$((fragments + 1))
          [ -x "$f" ] && printf '%s  executable but has no shebang; a sourced fragment must not be\n' "$f" >> "$TMP/hits"
          ;;
      esac
    fi
  done < "$TMP/files"

  if [ -s "$TMP/hits" ]; then
    fail 'exec bits' "$(grep -c . "$TMP/hits") hit(s)"
    sed 's/^/        | /' "$TMP/hits"
  else
    pass 'exec bits' "$shebanged executable, $fragments sourced fragment(s)"
  fi
}

check_pointers() {
  [ -d .claude ] || { note 'no .claude adapter' 'pointer check skipped'; return; }
  find .claude/skills .claude/agents -type f -name '*.md' 2>/dev/null | sort > "$TMP/ptr.list"
  : > "$TMP/hits"
  n=0
  biggest=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    size=$(wc -c < "$f" | tr -d ' ')
    [ "$size" -gt "$biggest" ] && biggest=$size
    [ "$size" -gt "$POINTER_MAX_BYTES" ] && \
      printf '%s  %s bytes > %s; inline a path into playbook/ instead of copying its text\n' \
        "$f" "$size" "$POINTER_MAX_BYTES" >> "$TMP/hits"
  done < "$TMP/ptr.list"

  if [ -s "$TMP/hits" ]; then
    fail 'pointer files' "$(grep -c . "$TMP/hits") too large"
    sed 's/^/        | /' "$TMP/hits"
  elif [ "$n" -lt "$MIN_POINTERS" ]; then
    # Deleting .claude/skills and .claude/agents outright used to report PASS with 0 files.
    fail 'pointer files' "only $n file(s), expected >= $MIN_POINTERS — adapters missing?"
  else
    pass 'pointer files' "$n file(s), largest ${biggest}B of ${POINTER_MAX_BYTES}B"
  fi
}

# ---------------------------------------------------------------------------- driver

usage() {
  printf 'usage: dev/lint.sh [--only NAME]… [--list]\n\n'
  printf 'checks, in run order:\n'
  for c in $CHECKS; do printf '  %-12s %s\n' "$c" "$(describe "$c")"; done
  printf '\nexit 0 only when every check passed. NOTE lines are advisory and never fail.\n'
}

selected=''
while [ $# -gt 0 ]; do
  case "$1" in
    --list)   for c in $CHECKS; do printf '%-12s %s\n' "$c" "$(describe "$c")"; done; exit 0 ;;
    # An explicit check, not ${2:?…}: that aborts with exit 1 and a shell line number,
    # which a caller cannot tell apart from "a check failed".
    --only)
      [ $# -ge 2 ] || { printf 'dev/lint.sh: --only needs a name\n' >&2; usage >&2; exit 2; }
      selected="$selected $2"; shift
      ;;
    --only=*) selected="$selected ${1#--only=}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'dev/lint.sh: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

run="$CHECKS"
if [ -n "$selected" ]; then
  for want in $selected; do
    ok=0
    for c in $CHECKS; do [ "$c" = "$want" ] && ok=1; done
    [ "$ok" -eq 1 ] || { printf 'dev/lint.sh: no check named %s\n' "$want" >&2; exit 2; }
  done
  run=''
  for c in $CHECKS; do
    for want in $selected; do [ "$c" = "$want" ] && run="$run $c" && break; done
  done
fi

printf 'dev/lint.sh — %s\n' "$ROOT"
for c in $run; do
  printf '\n%s — %s\n' "$c" "$(describe "$c")"
  "check_$c"
done

printf '\n'
[ "$notes" -eq 0 ] || printf '%s advisory note(s): an optional tool is missing, not a failure.\n' "$notes"
if [ "$fails" -eq 0 ]; then
  printf 'lint clean\n'
  exit 0
fi
printf '%s lint failure(s)\n' "$fails"
exit 1
