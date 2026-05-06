#!/usr/bin/env bash
# Start a Suite Phoenix dev server in the background on a free port.
#
# Cross-platform (macOS / Linux / WSL2). Picks a port in 4001-4099 using whichever
# of (ss, lsof, /dev/tcp) is available. Honors any DATABASE_URL or
# PG{HOST,PORT,USER,PASSWORD,...} you've already exported; otherwise defaults
# match apps/platform/config/dev.exs (postgres@localhost:5432).
#
# Usage: start-server.sh [worktree_path]
#   worktree_path defaults to $PWD. May be the worktree root or apps/platform.
# Env overrides:
#   PHX_BIND_IP   bind address (default 127.0.0.1)
#   APP_URL       advertised URL (default http://localhost:<port>)
set -euo pipefail

TARGET_PATH="${1:-$PWD}"

# -- Resolve the Phoenix app dir ----------------------------------------
resolve_app_dir() {
  local path="$1"
  if [ -d "$path/apps/platform" ]; then
    printf '%s\n' "$path/apps/platform"; return 0
  fi
  if [ -f "$path/mix.exs" ]; then
    printf '%s\n' "$path"; return 0
  fi
  echo "Could not resolve apps/platform from: $path" >&2
  return 1
}

# -- Find a free port using whatever tool is available ------------------
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH "sport = :$p" 2>/dev/null | grep -q LISTEN && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  # /dev/tcp probe — works in bash on macOS and Linux without external tools.
  (exec 3<>/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1 && { exec 3<&-; exec 3>&-; return 0; }
  return 1
}

find_free_port() {
  local candidate
  for candidate in $(seq 4001 4099); do
    if ! port_in_use "$candidate"; then
      printf '%s\n' "$candidate"; return 0
    fi
  done
  echo "No free port found in 4001-4099" >&2
  return 1
}

APP_DIR="$(resolve_app_dir "$TARGET_PATH")"
PORT="$(find_free_port)"
PID_FILE="/tmp/suite-dev-$PORT.pid"
LOG_FILE="/tmp/suite-dev-$PORT.log"

export MIX_ENV=dev
# A dev-only signing key. Phoenix requires >= 64 chars.
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-dev_secret_key_base_at_least_64_chars_padding_padding_padding_padding}"
export PHX_BIND_IP="${PHX_BIND_IP:-127.0.0.1}"
export APP_URL="${APP_URL:-http://localhost:$PORT}"

cd "$APP_DIR"

if [ ! -d "_build/dev" ]; then
  echo "_build/dev missing; running mix deps.get" >&2
  mix deps.get >&2
fi

echo "Running migrations in $APP_DIR" >&2
mix ecto.migrate >&2

echo "Starting Phoenix on $PHX_BIND_IP:$PORT (advertised as $APP_URL)" >&2
nohup env PORT="$PORT" mix phx.server >"$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" >"$PID_FILE"

# Give the BEAM a moment to either start or crash before we declare success.
sleep 1
if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  echo "Phoenix failed to stay running; check $LOG_FILE" >&2
  exit 1
fi

printf '%s\n' "$PORT"
