#!/usr/bin/env bash
# The only sanctioned secret scan. Contract in playbook/acceptance-gates.md, security gate.
#
# Scans the working tree AND every reachable commit, because a secret already committed is
# a never-downgradable failure that a working-tree scan cannot see.
#
# Never `grep -E '…' && exit 1`: grep exits 1 on a clean scan, so that form inverts the
# gate — a clean repo fails and a dirty one is reported by whatever ran next. Hits are
# collected into a file and the exit code is decided once, at the end.

set -uo pipefail

usage() {
  printf 'usage: secret-scan.sh [path]\n'
  printf '  exit 0 clean, 1 on a hit. Prints <rule> <file>:<line>, never the value.\n'
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

root="${1:-.}"
cd "$root" || { printf 'secret-scan: cannot enter %s\n' "$root" >&2; exit 1; }

# Key shapes, not prefixes, so prose like `sk_test_...` in the playbook is not a hit.
# One rule per line: name, one space, ERE. None of these patterns matches its own text.
RULES='stripe-live-key sk_live_[0-9A-Za-z]{16,}
stripe-test-key sk_test_[0-9A-Za-z]{16,}
stripe-webhook-secret whsec_[0-9A-Za-z]{16,}
aws-access-key-id AKIA[0-9A-Z]{16}
private-key-block -----BEGIN [A-Z ]*PRIVATE KEY-----'

hits=$(mktemp) || exit 1
revs=$(mktemp) || exit 1
errs=$(mktemp) || exit 1
trap 'rm -f "$hits" "$revs" "$errs"' EXIT INT TERM

in_git=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

# A shallow clone's history is truncated, so every `git grep <rev>` for a pruned commit
# fails and a clean report would be a lie. Shallow checkouts are the CI default on several
# runners, so this is the normal path and must be a refusal, not a silent pass.
shallow=0
if [ "$in_git" -eq 1 ]; then
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ] && shallow=1
  [ -f "$(git rev-parse --git-dir 2>/dev/null)/shallow" ] && shallow=1
fi

scanned_history=0
if [ "$in_git" -eq 1 ]; then
  # Tolerate a repo with no commits: rev-list is then empty and the history pass is skipped.
  git rev-list --all > "$revs" 2>/dev/null
  [ -s "$revs" ] && scanned_history=1
fi

while IFS= read -r rule_line; do
  [ -n "$rule_line" ] || continue
  rule=${rule_line%% *}
  pat=${rule_line#* }

  if [ "$in_git" -eq 1 ]; then
    # --untracked: a secret staged nowhere is still sitting on disk.
    #
    # --no-exclude-standard as well: git grep honours .gitignore without it, and a
    # gitignored `.env` is the single most likely home for a real live key. The non-git
    # fallback below uses plain grep and does find it, so omitting this made the scan
    # strictly weaker in exactly the case it was written for.
    git grep -n -I --no-color --untracked --no-exclude-standard -E -e "$pat" -- . 2>/dev/null \
      | cut -d: -f1,2 | sed -E "s|^|${rule} |" >> "$hits"

    if [ "$scanned_history" -eq 1 ]; then
      # Revisions are argv to `git grep`, so a long history overflows ARG_MAX. xargs batches
      # them; its 123 exit status on a no-match batch is deliberately ignored because the hit
      # file, not an exit code, decides the verdict.
      #
      # The `sh -c` wrapper exists so xargs appends revisions BEFORE the `--`. Appended after
      # it they would be read as pathspecs and the whole history pass would silently pass.
      #
      # stderr is captured as a `scan-error` hit rather than discarded: a wholesale failure
      # of the history pass used to be indistinguishable from a clean history.
      xargs -n 200 sh -c 'git grep -n -I --no-color -E -e "$0" "$@" -- .' "$pat" < "$revs" 2>"$errs" \
        | cut -d: -f1,2,3 | sed -E "s|^|${rule} |" >> "$hits"
      sed -E "s|^|scan-error ${rule}: |" "$errs" >> "$hits"
    fi
  else
    # Not a git repo: working tree only, and say so below.
    grep -rn -I -E --exclude-dir=.git --exclude-dir=node_modules -e "$pat" . 2>/dev/null \
      | cut -d: -f1,2 | sed -E "s|^|${rule} |" >> "$hits"
  fi
done <<EOF
$RULES
EOF

sort -u "$hits" -o "$hits"

if [ "$in_git" -eq 0 ]; then
  printf 'secret-scan: not a git repository — working tree only, history unscanned\n'
elif [ "$scanned_history" -eq 0 ]; then
  printf 'secret-scan: no commits yet — working tree only\n'
else
  printf 'secret-scan: working tree plus %s reachable commits\n' "$(wc -l < "$revs" | tr -d ' ')"
fi

# A gate that cannot prove itself FAILS. Reporting a truncated history as scanned is the
# one outcome worse than reporting a hit.
if [ "$shallow" -eq 1 ]; then
  printf 'secret-scan: FAIL — BLOCKER: this is a shallow clone, so the history cannot be scanned.\n'
  printf '  Re-run against a full clone, or `git fetch --unshallow`. A committed key on the\n'
  printf '  deploy host is a never-downgradable failure and an unscanned history hides it.\n'
  exit 1
fi

if [ -s "$hits" ]; then
  printf 'secret-scan: FAIL — %s hit(s). Values withheld.\n' "$(wc -l < "$hits" | tr -d ' ')"
  cat "$hits"
  exit 1
fi

printf 'secret-scan: clean (%s rules)\n' "$(printf '%s\n' "$RULES" | wc -l | tr -d ' ')"
exit 0
