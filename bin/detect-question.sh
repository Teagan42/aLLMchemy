#!/usr/bin/env bash
# Reads a candidate final message on stdin. Exit 0 if it interrogates the user, 1 if not.
# Harness-agnostic: the Claude Code Stop hook and the Codex wrapper both call this.
#
# Strips fenced code, quoted spans, and markdown table rows before matching. Legitimate
# reports quote example questions and print the DECISIONS.md "question that went unasked"
# column; matching those would block correct closing messages.
#
# An unclosed fence is prose, not code. A model that opens a yaml block and then asks, which
# is common when output is truncated mid-block, must still be caught — so fenced lines are
# buffered and released when EOF arrives with the fence still open.
#
# Double-quoted and backticked spans are stripped over the whole text, not per line, because
# a quoted example question wrapped across a newline is still a quotation.
#
# A `'` span is stripped only when anchored on both sides, shorter than 80 characters, and
# free of a sentence-ending `.`. Agent prose is full of contractions and sentences, and a
# looser rule erases the question between a stray opener and the next apostrophe.
#
# Fails closed on "not a question" (exit 1) if anything is missing, so a broken detector
# never blocks a run. The policy layer, not this script, is the real guarantee.
#
# Exit 2 means the pattern file is malformed. That is not "clean": an unreadable rule used
# to abort grep mid-list and leave the remaining rules unevaluated, silently.

set -uo pipefail

patterns="${QUESTION_PATTERNS:-$(dirname "$0")/question-patterns.txt}"
[ -f "$patterns" ] || exit 1

q=\'
text=$(awk '
  function isfence(s) { return s ~ /^[[:space:]]*(```|~~~)/ }
  { line[NR] = $0 }
  END {
    out = ""; buf = ""; fence = 0
    for (i = 1; i <= NR; i++) {
      if (isfence(line[i])) { if (fence) buf = ""; fence = !fence; continue }
      if (fence) { buf = buf line[i] "\n"; continue }
      if (line[i] ~ /^[[:space:]]*\|/) continue
      out = out line[i] "\n"
    }
    if (fence) out = out buf
    gsub(/"[^"]*"/, "", out)
    gsub(/`[^`]*`/, "", out)
    printf "%s", out
  }
' | sed -E -e "s/(^|[[:space:]]|\()${q}[^${q}.]{0,80}${q}([[:space:]]|[.,;:!?)]|$)/\1\2/g" \
           -e 's/[“][^”]*[”]//g')

[ -n "${text//[[:space:]]/}" ] || exit 1

# Redirect, not a pipe: a piped `while` runs in a subshell where `exit` cannot escape.
while IFS= read -r re; do
  case "$re" in ''|\#*) continue ;; esac
  # grep exits 2 on a bad ERE. Probing against /dev/null separates "no match" (1) from
  # "unparseable rule" (2), which otherwise reads as a clean message.
  grep -E -e "$re" /dev/null 2>/dev/null
  [ $? -le 1 ] || {
    printf 'detect-question: malformed pattern in %s: %s\n' "$patterns" "$re" >&2
    exit 2
  }
  if printf '%s' "$text" | grep -Eqi -- "$re"; then
    [ -n "${DETECT_VERBOSE:-}" ] && printf 'matched: %s\n' "$re" >&2
    exit 0
  fi
done < "$patterns"
exit 1
