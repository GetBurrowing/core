#!/usr/bin/env bash
# Run Playwright e2e tests against a freshly-started worktree dev server.
#
# This wires the four steps an agent has to chain together by hand otherwise:
#
#   1. Start a Phoenix dev server on a free port (4001-4099) for the worktree.
#   2. Build assets if priv/static is missing them (fresh worktrees).
#   3. Install e2e/node_modules and the matching Playwright browsers if missing.
#   4. Run `playwright test` with BASE_URL pointed at the chosen port.
#
# The server is always stopped on exit (trap on EXIT), even if tests fail or
# the script is interrupted with Ctrl-C.
#
# Usage:
#   scripts/run-e2e.sh                        # run all specs against $PWD worktree
#   scripts/run-e2e.sh tests/chat_reactions.spec.ts
#   scripts/run-e2e.sh --headed tests/chat_reactions.spec.ts
#   WORKTREE=~/projects/core-task-09 scripts/run-e2e.sh
#
# Env overrides:
#   WORKTREE            path to the worktree (default: $PWD)
#   PHX_BIND_IP         bind address (default 127.0.0.1)
#   E2E_SKIP_ASSETS=1   skip the asset rebuild step (faster if you just ran it)
#   E2E_SKIP_INSTALL=1  skip npm install + browser install (faster on warm runs)
#
# Exit codes: 0 tests passed | non-zero playwright failure or setup error.

set -euo pipefail

WORKTREE="${WORKTREE:-$PWD}"
# Allow caller to invoke from anywhere as long as WORKTREE resolves to a core checkout.
if [ ! -d "$WORKTREE/apps/platform" ]; then
  echo "ERROR: WORKTREE='$WORKTREE' does not look like a core checkout (no apps/platform)." >&2
  echo "       Pass --worktree <path> or cd into the worktree before running." >&2
  exit 2
fi

APP_DIR="$WORKTREE/apps/platform"
E2E_DIR="$WORKTREE/e2e"
SKILLS_DIR="$WORKTREE/skills/suite-dev-server/scripts"

if [ ! -d "$E2E_DIR" ]; then
  echo "ERROR: $E2E_DIR not found. This worktree predates the e2e suite." >&2
  exit 2
fi

# -- 1. Start dev server on a free port ---------------------------------
echo ">>> Starting dev server for $WORKTREE" >&2
PORT="$("$SKILLS_DIR/start-server.sh" "$WORKTREE")"
echo ">>> Phoenix listening on port $PORT" >&2

# Always stop the server, even on failure / Ctrl-C.
cleanup() {
  local exit_code=$?
  echo ">>> Stopping dev server on port $PORT" >&2
  "$SKILLS_DIR/stop-server.sh" "$PORT" >/dev/null 2>&1 || true
  exit $exit_code
}
trap cleanup EXIT INT TERM

"$SKILLS_DIR/wait-for-server.sh" "$PORT"

# -- 2. Build assets if missing -----------------------------------------
if [ "${E2E_SKIP_ASSETS:-0}" != "1" ]; then
  if [ ! -f "$APP_DIR/priv/static/assets/js/app.js" ]; then
    echo ">>> priv/static/assets/js/app.js missing — building assets" >&2
    (cd "$APP_DIR/assets" && npm install --silent)
    (cd "$APP_DIR" && mix assets.build)
  else
    echo ">>> Assets already built" >&2
  fi
fi

# -- 3. Install e2e deps + browsers if missing --------------------------
if [ "${E2E_SKIP_INSTALL:-0}" != "1" ]; then
  if [ ! -d "$E2E_DIR/node_modules" ]; then
    echo ">>> Installing e2e/node_modules" >&2
    (cd "$E2E_DIR" && npm install --silent)
  fi
  # `install-browsers` is idempotent — if the cached revision matches, it's a no-op.
  echo ">>> Ensuring Playwright browsers match the pinned version" >&2
  (cd "$E2E_DIR" && npm run install-browsers --silent) >&2
fi

# -- 4. Run Playwright ---------------------------------------------------
echo ">>> Running playwright test against http://localhost:$PORT" >&2
cd "$E2E_DIR"
BASE_URL="http://localhost:$PORT" exec node_modules/.bin/playwright test "$@"
