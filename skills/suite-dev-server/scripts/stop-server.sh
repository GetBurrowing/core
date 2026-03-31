#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/sbin:/sbin:$PATH"

PORT="${1:-}"
PID_FILE=""

if [ -z "$PORT" ]; then
  echo "Usage: $0 <port>" >&2
  exit 1
fi

PID_FILE="/tmp/suite-dev-$PORT.pid"

shutdown_pid() {
  local pid="$1"

  if [ -z "$pid" ]; then
    return 1
  fi

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 1
  fi

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

PIDS="$(/usr/sbin/lsof -ti:"$PORT" || true)"
if [ -n "$PIDS" ]; then
  kill $PIDS >/dev/null 2>&1 || true
  rm -f "$PID_FILE"
  exit 0
fi

rm -f "$PID_FILE"
echo "No running process found for port $PORT" >&2
exit 0
