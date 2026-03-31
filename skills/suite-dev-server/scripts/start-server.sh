#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/sbin:/sbin:$PATH"

TARGET_PATH="${1:-$PWD}"
PID_FILE=""
LOG_FILE=""
PORT=""

find_free_port() {
  local candidate
  for candidate in $(seq 4001 4099); do
    if ! /usr/sbin/lsof -ti:"$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "No free port found in 4001-4099" >&2
  return 1
}

resolve_app_dir() {
  local path="$1"

  if [ -d "$path/apps/platform" ]; then
    printf '%s\n' "$path/apps/platform"
    return 0
  fi

  if [ -f "$path/mix.exs" ]; then
    printf '%s\n' "$path"
    return 0
  fi

  echo "Could not resolve apps/platform from: $path" >&2
  return 1
}

APP_DIR="$(resolve_app_dir "$TARGET_PATH")"
PORT="$(find_free_port)"
PID_FILE="/tmp/suite-dev-$PORT.pid"
LOG_FILE="/tmp/suite-dev-$PORT.log"

export MIX_ENV=dev
export SECRET_KEY_BASE="dev_secret_key_base_at_least_64_chars_padding_padding_padding_padding"
export DATABASE_URL="${DATABASE_URL:-postgres://postgres:postgres@127.0.0.1/platform_dev}"
export AGENT_WORKSPACE_PATH="${AGENT_WORKSPACE_PATH:-$HOME/.openclaw}"
export PHX_BIND_IP="${PHX_BIND_IP:-127.0.0.1}"
export APP_URL="http://127.0.0.1:$PORT"

cd "$APP_DIR"

if [ ! -d "_build/dev" ]; then
  echo "_build/dev missing; running mix deps.get" >&2
  mix deps.get >&2
fi

echo "Running migrations in $APP_DIR" >&2
mix ecto.migrate >&2

echo "Starting Phoenix on port $PORT" >&2
nohup env PORT="$PORT" mix phx.server >"$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" >"$PID_FILE"

if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  echo "Phoenix failed to stay running; check $LOG_FILE" >&2
  exit 1
fi

printf '%s\n' "$PORT"
