#!/usr/bin/env bash
# Launch a dedicated Chrome (or Chromium) with CDP enabled on 127.0.0.1:9222.
#
# macOS + Linux. Auto-discovers the binary; override with CHROME_BIN.
#
# Env:
#   PORT          CDP port (default 9222)
#   PROFILE_DIR   user data dir (default $HOME/.cache/agent-chrome-profile)
#   HEADLESS      "1" to run with --headless=new
#   CHROME_BIN    explicit binary path
set -euo pipefail

PORT="${PORT:-9222}"
PROFILE_DIR="${PROFILE_DIR:-$HOME/.cache/agent-chrome-profile}"
PID_FILE="$PROFILE_DIR/chrome.pid"
LOG_FILE="$PROFILE_DIR/chrome.log"

mkdir -p "$PROFILE_DIR"

discover_chrome() {
  if [ -n "${CHROME_BIN:-}" ] && [ -x "$CHROME_BIN" ]; then
    printf '%s\n' "$CHROME_BIN"; return 0
  fi
  case "$(uname -s)" in
    Darwin)
      for cand in \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium" \
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
        [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
      done
      ;;
    Linux)
      for cand in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge; do
        if command -v "$cand" >/dev/null 2>&1; then
          command -v "$cand"; return 0
        fi
      done
      ;;
  esac
  return 1
}

CHROME="$(discover_chrome)" || {
  echo "Could not find Chrome / Chromium. Set CHROME_BIN to override." >&2
  exit 1
}

# Refuse to start if another Chrome already owns the CDP port.
if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1; then
  exec 3<&-; exec 3>&-
  echo "Port $PORT is already in use. Stop the existing Chrome (or pick another PORT)." >&2
  exit 1
fi

ARGS=(
  "--remote-debugging-port=$PORT"
  "--remote-debugging-address=127.0.0.1"
  "--user-data-dir=$PROFILE_DIR"
  "--no-first-run"
  "--no-default-browser-check"
  "--disable-background-networking"
  "--disable-default-apps"
)

if [ "${HEADLESS:-0}" = "1" ]; then
  ARGS+=("--headless=new" "--hide-scrollbars" "--mute-audio")
fi

echo "Launching: $CHROME ${ARGS[*]}" >&2
nohup "$CHROME" "${ARGS[@]}" >"$LOG_FILE" 2>&1 &
PID=$!
echo "$PID" >"$PID_FILE"

# Wait up to 10 s for the CDP endpoint to come up.
for _ in $(seq 1 20); do
  if curl -sSf "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
    echo "Chrome CDP up on http://127.0.0.1:$PORT (pid $PID)" >&2
    exit 0
  fi
  sleep 0.5
done

echo "Chrome did not respond on $PORT within 10 s. See $LOG_FILE" >&2
exit 1
