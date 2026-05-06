#!/usr/bin/env bash
# Stop the dedicated agent Chrome started by launch-chrome.sh.
#
# Reads $PROFILE_DIR/chrome.pid (default $HOME/.cache/agent-chrome-profile).
# Refuses to kill the listener on :$PORT if no PID file is present — that could
# be your day-to-day Chrome with debugging accidentally enabled.
set -euo pipefail

PROFILE_DIR="${PROFILE_DIR:-$HOME/.cache/agent-chrome-profile}"
PID_FILE="$PROFILE_DIR/chrome.pid"

if [ ! -f "$PID_FILE" ]; then
  echo "No PID file at $PID_FILE. Refusing to guess." >&2
  exit 0
fi

PID="$(cat "$PID_FILE")"
if ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "PID $PID is not running; cleaning up stale PID file" >&2
  rm -f "$PID_FILE"
  exit 0
fi

kill "$PID" >/dev/null 2>&1 || true
for _ in $(seq 1 10); do
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    rm -f "$PID_FILE"
    exit 0
  fi
  sleep 0.5
done

echo "PID $PID did not exit within 5 s; sending SIGKILL" >&2
kill -9 "$PID" >/dev/null 2>&1 || true
rm -f "$PID_FILE"
