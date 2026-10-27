#!/usr/bin/env bash
# Shared gate helpers. Sourced, never dispatched: verify.sh only runs gates/<name>.sh for
# the nine gate names, and running this file directly just defines functions and exits 0.
#
# The one rule this file exists to enforce: a gate that cannot prove itself FAILS. There is
# no auto-SKIP for a missing check, because the whole package is worthless if "no test was
# written" reads the same as "the test passed".

set -uo pipefail

GATE_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE_DIR=$(dirname -- "$GATE_DIR")
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

_fails=0

# ISO-8601 UTC timestamp to epoch seconds. Prints nothing when the input carries no
# timestamp. `date -d` is GNU-only and awk's mktime is gawk-only, so this is arithmetic;
# the bash 3.2 target rules both of them out.
iso_epoch() {
  printf '%s\n' "$1" | awk '
    function days(y, m, d,   era, yoe, doy, doe) {
      if (m <= 2) { y -= 1; m += 12 }
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (m - 3) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    {
      if (!match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) exit 0
      s = substr($0, RSTART, RLENGTH)
      print days(substr(s,1,4)+0, substr(s,6,2)+0, substr(s,9,2)+0) * 86400 \
            + (substr(s,12,2)+0) * 3600 + (substr(s,15,2)+0) * 60 + (substr(s,18,2)+0)
    }
  '
}

say()  { printf '  %s\n' "$*"; }
head2() { printf '%s\n' "== $*"; }

# Reserved exit code for "I could not run, and here is the BLOCKER". Mirrors verify.sh.
SKIP_EXIT=77

# The runner-visible skip channel: `SKIP: ` at column zero. An indented `say` is the one
# outcome verify.sh cannot tell apart from a pass, so a BLOCKER must never go out through it.
#
# note_skip leaves the gate running, so a tier that cannot prove a deployed assertion still
# proves every local one. verify.sh scores the whole gate SKIP either way, and a SKIP is
# not a pass.
note_skip() { printf 'SKIP: %s\n' "$*"; }
skip()      { note_skip "$*"; exit "$SKIP_EXIT"; }

# Host, not URL prefix. `http://0.0.0.0:3000` and a compose service name are as local as
# localhost, and a prefix list silently passes both as a public target.
host_of() {
  _h=${1#*://}
  _h=${_h%%/*}
  _h=${_h%%\?*}
  _h=${_h##*@}
  case "$_h" in
    \[*) _h=${_h#\[}; _h=${_h%%\]*} ;;
    *)   _h=${_h%%:*} ;;
  esac
  printf '%s' "$_h"
}

# Loopback, link-local, RFC1918, container aliases, and any bare hostname: a name with no
# dot resolves only inside the compose network.
is_local_host() {
  case "$1" in
    localhost|*.localhost|::1|0.0.0.0|host.docker.internal|*.local) return 0 ;;
    127.*|10.*|192.168.*|169.254.*)                                 return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*)                          return 0 ;;
    *.*) return 1 ;;
    *)   return 0 ;;
  esac
}

ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; _fails=$((_fails + 1)); }

# Runs a check command, echoing it first. The exact command belongs in the artifact so a
# failure can be reproduced without guessing.
run() {
  printf '  RUN   %s\n' "$*"
  if "$@"; then
    ok "$1 exited 0"
    return 0
  fi
  bad "$* exited non-zero"
  return 1
}

# Runs a shell string, for product commands that are naturally written as one.
run_sh() {
  printf '  RUN   %s\n' "$1"
  if sh -c "$1"; then
    ok "exited 0"
    return 0
  fi
  bad "$1 exited non-zero"
  return 1
}

file_present() {
  if [ -f "$1" ]; then ok "present: $1"; return 0; fi
  bad "absent: $1"
  return 1
}

# Greps a file for a pattern, naming the requirement rather than the regex.
contains() {
  if [ -f "$1" ] && grep -Eqi -- "$2" "$1"; then ok "$3"; return 0; fi
  bad "$3 (no match for /$2/ in $1)"
  return 1
}

# A `pnpm test:gate:x` command is runnable only if package.json actually declares the
# script. `command -v pnpm` proves nothing about whether the owning agent wrote the test.
product_command_runnable() {
  cmd=$1
  bin=${cmd%% *}
  if ! command -v "$bin" >/dev/null 2>&1; then return 1; fi
  case "$cmd" in
    'pnpm run '*|'npm run '*|'yarn run '*) script=${cmd##* } ;;
    'pnpm '*|'npm '*|'yarn '*)             script=${cmd#* }; script=${script%% *} ;;
    *) return 0 ;;
  esac
  case "$script" in
    install|audit|test|build|lint|typecheck) return 0 ;;
  esac
  [ -f "$PROJECT_DIR/package.json" ] || return 1
  grep -Eq "\"${script}\"[[:space:]]*:" "$PROJECT_DIR/package.json"
}

# The delegating half of the gate split. Named command missing => FAIL with the exact text
# the owning agent needs, never a SKIP.
delegate() {
  gate=$1
  cmd=$2
  if ! product_command_runnable "$cmd"; then
    bad "gate ${gate} has no runnable check: the owning agent must implement ${cmd}"
    return 1
  fi
  run_sh "$cmd"
}

finish() {
  if [ "$_fails" -eq 0 ]; then
    printf '%s: PASS\n' "$1"
    exit 0
  fi
  printf '%s: FAIL (%s failed check(s))\n' "$1" "$_fails"
  exit 1
}
