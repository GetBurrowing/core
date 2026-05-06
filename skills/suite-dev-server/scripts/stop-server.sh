#!/usr/bin/env bash
# Stop a Suite Phoenix dev server started by start-server.sh.
#
# Usage: stop-server.sh [--force] <port>
#   Without --force, requires /tmp/suite-dev-<port>.pid (the PID we wrote at
#   start). With --force, falls back to whatever's listening on that port —
#   only use this after confirming with `lsof -nP -i :<port>` (macOS) or
#   `ss -tlnp "sport = :<port>"` (Linux) that it's actually yours.
set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
  shift
fi

PORT="${1:-}"

if [ -z "$PORT" ]; then
  echo "Usage: $0 [--force] <port>" >&2
  exit 1
fi

PID_FILE="/tmp/suite-dev-$PORT.pid"

shutdown_pid() {
  local pid="$1"
  [ -z "$pid" ] && return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  kill "$pid" >/dev/null 2>&1 || return 1
  for _ in $(seq 1 10); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE")"
  if shutdown_pid "$PID"; then
    rm -f "$PID_FILE"
    exit 0
  fi
fi

if [ "$FORCE" -eq 1 ]; then
  PIDS=""
  if command -v lsof >/dev/null 2>&1; then
    PIDS="$(lsof -ti:"$PORT" || true)"
  elif command -v fuser >/dev/null 2>&1; then
    PIDS="$(fuser -n tcp "$PORT" 2>/dev/null | tr -d ':\n' || true)"
  fi
  if [ -n "$PIDS" ]; then
    # shellcheck disable=SC2086
    kill $PIDS >/dev/null 2>&1 || true
    rm -f "$PID_FILE"
    exit 0
  fi
fi

rm -f "$PID_FILE"
echo "No running process found for port $PORT (PID file absent; rerun with --force to kill the listener anyway)" >&2
exit 0
