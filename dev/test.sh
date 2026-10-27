#!/usr/bin/env bash
# The single test entrypoint for developing this package. `make test`, or `make check` for
# lint plus this.
#
#   dev/test.sh                   every suite
#   dev/test.sh --quick           skip the slow suites (what the pre-commit hook runs)
#   dev/test.sh --suite intake    one suite, repeatable
#   dev/test.sh --list            suite names and what each covers
#
# Seven scattered commands means a developer runs three of them. One entrypoint with one
# exit code is the only form that survives contact with a repair loop.
#
# Offline and daemon-free by construction, so it passes in CI and on a plane. gateway/up.sh
# binds a port and talks to providers, so it is deliberately NOT a suite here; gateway/probe.sh
# covers that path by hand.
#
# Written to the bash 3.2 floor (macOS /bin/bash): no mapfile, no declare -A, no ${v^^}.

set -uo pipefail

SUITES='syntax portability patterns detector failover billing intake chain gates secrets'
# Only failover is slow (~16s; it spawns fake launchers through the supervisor). `secrets`
# stays in --quick on purpose: a pre-commit hook that does not scan for keys is theatre.
SLOW='failover'

# Floors for the counting checks. Raise them when the tree grows; never lower one to make a
# run green. They exist so a check that measured nothing cannot report PASS — an empty file
# list used to print `0 file(s)` next to a green suite.
MIN_SH=25
MIN_MJS=8

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
cd "$ROOT" || exit 2

TMP=$(mktemp -d "${TMPDIR:-/tmp}/allmchemy-test-XXXXXX") || exit 2
# Holds the planted-secret directory while the `secrets` suite runs. Named in the trap so a
# failure mid-suite cannot leave a fake live key sitting in someone's working tree. It is
# planted under the gitignored artifacts/, so even a SIGKILL leaves nothing stageable.
PLANT=''
cleaned=0
cleanup() {
  [ "$cleaned" -eq 1 ] && return 0
  cleaned=1
  [ -n "$PLANT" ] && rm -rf "$PLANT"
  rm -rf "$TMP"
  return 0
}
# Separate handlers: a signal handler that only cleans up and returns leaves the run going,
# so Ctrl-C used to be ignored and the script still reported its summary and exit code.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

RESULTS="$TMP/results"
: > "$RESULTS"
total_fails=0
suite_fails=0

pass() { printf '  PASS  %-46s %s\n' "$1" "${2:-ok}"; }
fail() { printf '  FAIL  %-46s %s\n' "$1" "${2:-failed}"; suite_fails=$((suite_fails + 1)); }

indent() { sed 's/^/        | /' "$1"; }

run_cmd() {  # label, command words…
  label=$1
  shift
  if "$@" > "$TMP/cmd.out" 2>&1; then
    pass "$label" 'exit 0'
  else
    fail "$label" "exit $?"
    indent "$TMP/cmd.out"
  fi
}

describe() {
  case "$1" in
    syntax)   printf 'bash -n every .sh under /bin/bash, node --check every .mjs' ;;
    portability) printf 'dev/lint.sh --only portability — the bash 3.2 / BSD floor' ;;
    patterns) printf 'every rule in bin/question-patterns.txt is valid and load-bearing' ;;
    detector) printf 'bin/test-detect-question.sh — question detector and Stop hook' ;;
    failover) printf 'bin/test-failover.sh — model failover supervisor (slow)' ;;
    billing)  printf 'template/billing-core unit tests' ;;
    intake)   printf 'validate-intake.mjs accepts the example and rejects a bad intake' ;;
    gates)    printf 'template/verify.sh --list emits exactly the nine gate names' ;;
    secrets)  printf 'secret-scan.sh is clean here and fires on a planted key' ;;
  esac
}

# ---------------------------------------------------------------------------- suites

# Writes $TMP/sh.list and $TMP/mjs.list. Shell is identified by extension OR shebang, so
# extensionless hooks (dev/hooks/pre-commit) are syntax-checked instead of silently skipped.
# artifacts/ is run output and .worktrees/ belongs to another checkout; neither is source.
classify_sources() {
  find . -name .git -prune -o -name .worktrees -prune -o -name artifacts -prune \
    -o -name node_modules -prune -o -type f -print | sort > "$TMP/files"
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

suite_syntax() {
  classify_sources

  # /bin/bash explicitly, not $BASH: the floor this package must parse under is macOS
  # bash 3.2, and a newer bash on PATH would accept bash-4 syntax that ships broken.
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if /bin/bash -n "$f" > "$TMP/syn.out" 2>&1; then
      n=$((n + 1))
    else
      fail "bash -n $f" 'parse error'
      indent "$TMP/syn.out"
    fi
  done < "$TMP/sh.list"
  bashver=$(/bin/bash -c 'printf %s "$BASH_VERSION"' 2>/dev/null)
  # Floor, not decoration. A classify_sources that found nothing used to report PASS with a
  # count of 0, so running from a pruned or wrong directory read as a green syntax check.
  if [ "$n" -ge "$MIN_SH" ]; then
    pass "bash -n (/bin/bash ${bashver:-unknown})" "$n file(s)"
  else
    fail "bash -n (/bin/bash ${bashver:-unknown})" "only $n file(s), expected >= $MIN_SH"
  fi

  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if node --check "$f" > "$TMP/syn.out" 2>&1; then
      n=$((n + 1))
    else
      fail "node --check $f" 'parse error'
      indent "$TMP/syn.out"
    fi
  done < "$TMP/mjs.list"
  if [ "$n" -ge "$MIN_MJS" ]; then
    pass "node --check ($(node --version))" "$n file(s)"
  else
    fail "node --check ($(node --version))" "only $n file(s), expected >= $MIN_MJS"
  fi
}

suite_portability() {
  # bash -n parses mapfile, declare -A, sed -r and bare timeout without complaint, so the
  # syntax suite cannot see the repo's hard constraint. `make test` must cover it alone:
  # anyone who runs only the headline command would otherwise ship GNU-only shell.
  run_cmd 'dev/lint.sh --only portability' ./dev/lint.sh --only portability
}

# Each rule in question-patterns.txt gets one fixture that only that rule matches, so
# deleting any rule turns this red. bin/test-detect-question.sh cannot do this job: its
# cases are deliberately realistic, and each is caught by several rules at once.
suite_patterns() {
  rules='bin/question-patterns.txt'
  fixtures='bin/question-pattern-fixtures.txt'
  for f in "$rules" "$fixtures"; do
    [ -f "$f" ] || { fail "$f exists" 'missing'; return; }
  done

  grep -vE '^[[:space:]]*(#|$)' "$rules"    > "$TMP/rules"
  grep -vE '^[[:space:]]*(#|$)' "$fixtures" > "$TMP/fixtures"
  nr=$(grep -c . "$TMP/rules")
  nf=$(grep -c . "$TMP/fixtures")
  if [ "$nr" -gt 0 ]; then pass 'rules present' "$nr rule(s)"; else fail 'rules present' 'none'; return; fi
  if [ "$nr" = "$nf" ]; then
    pass 'one fixture per rule' "$nf fixture(s)"
  else
    fail 'one fixture per rule' "$nr rule(s) but $nf fixture(s) — add the missing fixture"
  fi

  # A malformed ERE made grep abort mid-list and leave the remaining rules unevaluated.
  bad=0
  ri=0
  while IFS= read -r re; do
    [ -n "$re" ] || continue
    ri=$((ri + 1))
    grep -E -e "$re" /dev/null 2>/dev/null
    [ $? -le 1 ] || { fail "rule $ri is a valid ERE" "$re"; bad=$((bad + 1)); }
  done < "$TMP/rules"
  [ "$bad" -eq 0 ] && pass 'every rule is a valid ERE' "$nr checked"

  # Fixture i must match exactly one rule, and across all fixtures every rule index must
  # appear exactly once. That bijection is what makes each rule individually load-bearing.
  : > "$TMP/pairs"
  fi=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    fi=$((fi + 1))
    ri=0
    hits=0
    which=''
    while IFS= read -r re; do
      [ -n "$re" ] || continue
      ri=$((ri + 1))
      if printf '%s' "$t" | grep -Eqi -- "$re" 2>/dev/null; then
        hits=$((hits + 1))
        which="$which $ri"
        printf '%s\n' "$ri" >> "$TMP/pairs"
      fi
    done < "$TMP/rules"
    if [ "$hits" -ne 1 ]; then
      fail "fixture $fi matches exactly one rule" "matched $hits:$which"
    fi
    # Isolation is not enough: the detector strips quoted and fenced spans first, so a
    # fixture can match its rule here and still be invisible end to end.
    printf '%s' "$t" | ./bin/detect-question.sh || \
      fail "fixture $fi trips detect-question.sh" 'exit nonzero — rule is unreachable'
  done < "$TMP/fixtures"

  uncovered=''
  ri=0
  while IFS= read -r re; do
    [ -n "$re" ] || continue
    ri=$((ri + 1))
    c=$(grep -c "^$ri\$" "$TMP/pairs")
    [ "$c" = 1 ] || uncovered="$uncovered $ri($c)"
  done < "$TMP/rules"
  if [ -z "$uncovered" ]; then
    pass 'every rule is load-bearing' "$nr rule(s), 1 fixture each"
  else
    fail 'every rule is load-bearing' "rule(s) with no single owning fixture:$uncovered"
  fi
}

suite_detector() {
  run_cmd 'bin/test-detect-question.sh' ./bin/test-detect-question.sh
}

suite_failover() {
  run_cmd 'bin/test-failover.sh' ./bin/test-failover.sh
}

suite_billing() {
  # The glob form, not `node --test <dir>`: directory support landed in node 23 and this
  # package targets node 22, where the directory form finds nothing and exits 0.
  run_cmd 'node --test template/billing-core/test/*.test.mjs' \
    node --test template/billing-core/test/*.test.mjs
}

suite_intake() {
  run_cmd 'intake.example.yaml validates' node bin/validate-intake.mjs intake.example.yaml

  # The happy path alone cannot distinguish a working validator from `exit 0`. This fixture
  # breaks two keywords the schema actually uses: maximum, and additionalProperties:false.
  bad="$TMP/bad-intake.yaml"
  printf 'price_usd: 500\nbilling_provider: venmo\nnot_a_real_field: x\n' > "$bad"
  if node bin/validate-intake.mjs "$bad" > "$TMP/bad.out" 2>&1; then
    fail 'bad intake must be rejected' 'exit 0 — validator accepted price_usd 500 and an unknown field'
    indent "$TMP/bad.out"
  else
    rc=$?
    pass 'bad intake rejected' "exit $rc"
    # A validator that rejects everything silently, or for the wrong reason, used to pass
    # here: the count was printed, never compared. Each of the three breaks must be named.
    for want in 'above the maximum' 'unknown field' 'not one of'; do
      if grep -q "$want" "$TMP/bad.out"; then
        pass "  reason: $want" 'reported'
      else
        fail "  reason: $want" 'not reported — rejected for the wrong reason'
        indent "$TMP/bad.out"
      fi
    done
  fi

  # Seam 12: the schema, the questionnaire and the example describe one contract. Nothing
  # cross-read them before, so dropping a question from QUESTIONNAIRE.md was invisible.
  run_cmd 'schema, questionnaire and example agree' node bin/validate-intake.mjs --check-docs
}

# The provider chain is the failover configuration, so a renderer that accepts a broken
# chain ships a gateway that routes nowhere. Both directions are asserted: valid chains
# render in order, invalid ones refuse.
suite_chain() {
  R='node bin/render-gateway-config.mjs'

  if $R --chain 'cloud ollama ollama2' --out "$TMP/c1.yaml" > "$TMP/c1.log" 2>&1; then
    pass 'cloud-first chain renders' 'exit 0'
  else
    fail 'cloud-first chain renders' "exit $?"
    indent "$TMP/c1.log"
  fi
  if grep -q '    - cloud: \["ollama", "ollama2"\]' "$TMP/c1.yaml"; then
    pass 'fallbacks follow chain order' 'cloud -> ollama -> ollama2'
  else
    fail 'fallbacks follow chain order' 'missing or reordered'
  fi

  # The configurability that matters: a local provider leads by reordering alone, with no
  # edit to providers.conf and no hand-written config.
  if $R --chain 'mlx cloud' --out "$TMP/c2.yaml" > "$TMP/c2.log" 2>&1 \
     && grep -q '    - mlx: \["cloud"\]' "$TMP/c2.yaml"; then
    pass 'a local provider can be primary' 'mlx -> cloud'
  else
    fail 'a local provider can be primary' 'mlx-first chain did not render'
    indent "$TMP/c2.log"
  fi
  if grep -q 'CHAIN_PRIMARY="mlx"' "$TMP/c2.env"; then
    pass 'sidecar names the primary' 'mlx'
  else
    fail 'sidecar names the primary' 'CHAIN_PRIMARY wrong or absent'
  fi
  # Two local SERVERS each hold their own weights and fight for RAM; two models on one
  # server just swap inside it. Warning on the latter would cry wolf on the default chain.
  $R --chain 'mlx ollama cloud' --out "$TMP/c3.yaml" > "$TMP/c3.log" 2>&1
  if grep -q 'WARNING' "$TMP/c3.log"; then
    pass 'two local servers warn' 'emitted'
  else
    fail 'two local servers warn' 'absent'
  fi
  if grep -q 'WARNING' "$TMP/c1.log"; then
    fail 'one local server stays quiet' 'warned on the default chain'
  else
    pass 'one local server stays quiet' 'no warning'
  fi

  # content_policy_fallbacks must never be an ACTIVE key: a refusal is an answer, not an
  # outage. The rendered file explains that in a comment, so match uncommented lines only.
  if grep -E '^[[:space:]]*content_policy_fallbacks' "$TMP/c1.yaml" >/dev/null; then
    fail 'no content-policy fallback' 'rendered — refusals would be re-rolled'
  else
    pass 'no content-policy fallback' 'unset'
  fi

  printf 'notools | openai/x | http://127.0.0.1:1 | yes | no\n' > "$TMP/bad.conf"
  for case in 'empty::' 'unknown:cloud nope:' 'duplicate:cloud cloud:' ; do
    label=${case%%:*}; rest=${case#*:}; chain=${rest%%:*}
    if $R --chain "$chain" --print >/dev/null 2>&1; then
      fail "refuses a $label chain" 'rendered anyway'
    else
      pass "refuses a $label chain" "exit $?"
    fi
  done
  # A provider that cannot emit tool_use cannot drive an agentic run at all.
  if FACTORY_PROVIDERS_FILE="$TMP/bad.conf" $R --chain notools --print >/dev/null 2>&1; then
    fail 'refuses a tool-less primary' 'rendered anyway'
  else
    pass 'refuses a tool-less primary' "exit $?"
  fi
}

suite_gates() {
  expected='build core recurrence billing security legal operations cost stranger-path'
  # `!` replaces the command's status, so `$?` in the failure branch was always 0 and the
  # FAIL line sent a maintainer after the test harness instead of verify.sh.
  if ./template/verify.sh --list > "$TMP/gates.out" 2>&1; then
    :
  else
    rc=$?
    fail 'verify.sh --list' "exit $rc"
    indent "$TMP/gates.out"
    return
  fi
  got=$(tr '\n' ' ' < "$TMP/gates.out" | sed -E 's/ +$//')
  count=$(grep -c . "$TMP/gates.out")
  if [ "$count" = 9 ]; then pass 'nine gates listed' "$count"; else fail 'nine gates listed' "got $count"; fi
  if [ "$got" = "$expected" ]; then
    pass 'gate names and order match' 'exact'
  else
    fail 'gate names and order match' "got: $got"
  fi
  # Named, never numbered, per playbook/acceptance-gates.md. A digit here means someone
  # renumbered the acceptance gates into the G1-G8 product-selection namespace.
  if grep -qE '^G?[0-9]' "$TMP/gates.out"; then
    fail 'gates are named, not numbered' 'numeric gate name present'
  else
    pass 'gates are named, not numbered' 'ok'
  fi

  # --list only echoes verify.sh's own GATES variable, so the comparisons above prove one
  # string equals another. Deleting a gate script left every check green while the gate
  # could not run at all. Each name must resolve to a runnable script.
  missing=''
  undispatchable=''
  checked=0
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    checked=$((checked + 1))
    if [ ! -x "template/gates/$g.sh" ]; then
      missing="$missing $g"
      continue
    fi
    # Artifacts into $TMP: the gates themselves FAIL here (there is no built product), and
    # the only thing under test is that verify.sh finds and runs the script.
    ARTIFACT_DIR="$TMP/gate-artifacts" ./template/verify.sh --gate "$g" > "$TMP/g.out" 2>&1
    rc=$?
    if [ "$rc" -ge 2 ] || grep -q 'gate script missing' "$TMP/g.out"; then
      undispatchable="$undispatchable $g(exit $rc)"
    fi
  done < "$TMP/gates.out"

  if [ "$checked" -eq 9 ]; then pass 'nine gate scripts checked' "$checked"; else fail 'nine gate scripts checked' "got $checked"; fi
  if [ -z "$missing" ]; then
    pass 'every listed gate has an executable script' "$checked script(s)"
  else
    fail 'every listed gate has an executable script' "missing or not executable:$missing"
  fi
  if [ -z "$undispatchable" ]; then
    pass 'every listed gate is dispatchable' '--gate <name> reaches the script'
  else
    fail 'every listed gate is dispatchable' "$undispatchable"
  fi
}

suite_secrets() {
  # secret-scan.sh refuses a shallow clone outright, because an unscanned history hides a
  # committed key. actions/checkout defaults to depth 1, so CI needs `fetch-depth: 0` or this
  # suite is red for a reason that looks like a bug in the scanner. Named here, not guessed.
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    fail 'clone has full history' 'shallow clone — set fetch-depth: 0, or run `git fetch --unshallow`'
    return
  fi

  run_cmd 'clean tree scans clean' ./template/secret-scan.sh

  # The key is assembled from two fragments so this file never contains the literal shape
  # secret-scan.sh matches — otherwise the clean-tree check above would fail on us.
  #
  # Planted under artifacts/, which .gitignore covers, because the trap cannot run on
  # SIGKILL or power loss: a repo-root plant survived and `git add -A` would commit it.
  # secret-scan.sh passes --no-exclude-standard, so being gitignored does not hide it.
  mkdir -p "$ROOT/artifacts" 2>/dev/null
  PLANT=$(mktemp -d "$ROOT/artifacts/devtest-planted-secret-XXXXXX") || { fail 'plant a fake key' 'mktemp failed'; return; }
  printf 'STRIPE_SECRET_KEY=%s%s\n' 'sk_' 'live_0123456789abcdefghijklmn' > "$PLANT/planted.env"
  if ./template/secret-scan.sh > "$TMP/scan.out" 2>&1; then
    fail 'planted key must trip the scanner' 'exit 0 — a scanner that never fires is worse than none'
    indent "$TMP/scan.out"
  else
    pass 'planted key trips the scanner' "exit $?"
    if grep -q 'stripe-live-key' "$TMP/scan.out"; then
      pass '  correct rule named' 'stripe-live-key'
    else
      fail '  correct rule named' 'hit reported under the wrong rule'
      indent "$TMP/scan.out"
    fi
  fi
  rm -rf "$PLANT"
  PLANT=''
  if ./template/secret-scan.sh > "$TMP/scan2.out" 2>&1; then
    pass 'tree clean again after removal' 'exit 0'
  else
    fail 'tree clean again after removal' 'residue left behind'
    indent "$TMP/scan2.out"
  fi
}

# ---------------------------------------------------------------------------- driver

usage() {
  printf 'usage: dev/test.sh [--quick] [--suite NAME]… [--list]\n\n'
  printf 'suites, in run order:\n'
  for s in $SUITES; do printf '  %-12s %s\n' "$s" "$(describe "$s")"; done
  printf '\n--quick skips:'
  for s in $SLOW; do printf ' %s' "$s"; done
  printf '\nexit 0 only when every selected suite passed.\n'
}

quick=0
selected=''
while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      for s in $SUITES; do printf '%-12s %s\n' "$s" "$(describe "$s")"; done
      exit 0
      ;;
    --quick)   quick=1 ;;
    # An explicit check, not ${2:?…}: that aborts with exit 1 and a message naming a shell
    # line number, which a caller cannot tell apart from "a suite failed".
    --suite)
      [ $# -ge 2 ] || { printf 'dev/test.sh: --suite needs a name\n' >&2; usage >&2; exit 2; }
      selected="$selected $2"; shift
      ;;
    --suite=*) selected="$selected ${1#--suite=}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'dev/test.sh: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$selected" ]; then
  for want in $selected; do
    ok=0
    for s in $SUITES; do [ "$s" = "$want" ] && ok=1; done
    if [ "$ok" -eq 0 ]; then
      printf 'dev/test.sh: no suite named %s. The suites are: %s\n' "$want" "$SUITES" >&2
      exit 2
    fi
  done
  # Reorder to canonical run order so output is comparable between invocations.
  run=''
  for s in $SUITES; do
    for want in $selected; do [ "$s" = "$want" ] && run="$run $s" && break; done
  done
else
  run="$SUITES"
fi

printf 'dev/test.sh — %s\n' "$ROOT"
[ "$quick" -eq 1 ] && printf 'mode: --quick (slow suites skipped)\n'

for s in $run; do
  skip=0
  if [ "$quick" -eq 1 ]; then
    for sl in $SLOW; do [ "$sl" = "$s" ] && skip=1; done
  fi
  if [ "$skip" -eq 1 ]; then
    printf '\n%s — %s\n' "$s" "$(describe "$s")"
    printf '  SKIP  %-46s %s\n' 'suite not run' '--quick'
    printf '%s\t%s\t%s\t%s\n' "$s" SKIP 0 '--quick' >> "$RESULTS"
    continue
  fi

  printf '\n%s — %s\n' "$s" "$(describe "$s")"
  suite_fails=0
  started=$(date -u '+%s')
  "suite_$s"
  elapsed=$(( $(date -u '+%s') - started ))
  if [ "$suite_fails" -eq 0 ]; then status=PASS; else status=FAIL; fi
  printf '%s\t%s\t%s\t%ss\n' "$s" "$status" "$suite_fails" "$elapsed" >> "$RESULTS"
  total_fails=$((total_fails + suite_fails))
done

printf '\n| Suite | Status | Failures | Time |\n|---|---|---|---|\n'
awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$RESULTS"

ran=$(awk -F'\t' '$2 != "SKIP" { n++ } END { print n + 0 }' "$RESULTS")
okn=$(awk -F'\t' '$2 == "PASS" { n++ } END { print n + 0 }' "$RESULTS")
printf '\n%s of %s suite(s) run passed.\n' "$okn" "$ran"

if [ "$total_fails" -eq 0 ]; then
  printf 'all pass\n'
  exit 0
fi
printf '%s failing check(s)\n' "$total_fails"
exit 1
