#!/usr/bin/env bash
# Stops the gateway by pidfile and confirms the port is actually free.
#
# Quiet and exit 0 when already stopped: a supervisor calls this on every exit path,
# including the paths where nothing was ever started.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GATEWAY_HOST="${GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${GATEWAY_PORT:-4000}"
PIDFILE="artifacts/gateway-$GATEWAY_PORT.pid"

# A TCP connect. "Released" has to mean nothing holds the socket, not merely that HTTP
# stopped answering — a half-dead proxy still blocks the next start.
port_open() { (exec 3<>"/dev/tcp/$GATEWAY_HOST/$GATEWAY_PORT") 2>/dev/null; }

PID=""
[ -f "$PIDFILE" ] && PID=$(cat "$PIDFILE" 2>/dev/null)
case "$PID" in ''|*[!0-9]*) PID="" ;; esac

if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
  rm -f "$PIDFILE"
  if port_open; then
    printf 'gateway: port %s still answers but no pidfile owns it.\n' "$GATEWAY_PORT" >&2
    printf '  Find it:  lsof -nP -iTCP:%s -sTCP:LISTEN\n' "$GATEWAY_PORT" >&2
    exit 1
  fi
  printf 'gateway: already stopped\n'
  exit 0
fi

kill "$PID" 2>/dev/null
# uvx spawns litellm as a child, so wait for the port rather than the parent pid.
i=0
while [ "$i" -lt 20 ]; do
  port_open || break
  sleep 1
  i=$((i + 1))
done

if port_open; then
  kill -9 "$PID" 2>/dev/null
  pkill -f "litellm --config .*--port $GATEWAY_PORT" 2>/dev/null
  sleep 2
fi

rm -f "$PIDFILE"

if port_open; then
  printf 'gateway: FAIL port %s is still serving after SIGKILL.\n' "$GATEWAY_PORT" >&2
  printf '  Find it:  lsof -nP -iTCP:%s -sTCP:LISTEN\n' "$GATEWAY_PORT" >&2
  exit 1
fi

printf 'gateway: stopped (pid %s); port %s released\n' "$PID" "$GATEWAY_PORT"
