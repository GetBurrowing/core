#!/usr/bin/env bash
# Run the call-control LABEL SWING probe and print its records.
# FE-20, task 01a0773e-cea9-7001-98f5-be6c37607e91.
#
# WHY THIS IS A SCRIPT AND NOT A PASTED COMMAND. Stage 3 has to run the
# IDENTICAL measurement three times — against main, against the fix, and
# against a mutant — and compare the numbers. A measurement whose setup lives
# in a chat message is a measurement that will be re-created slightly
# differently the second time, and the difference will be read as a result.
#
# Usage:
#   measure-call-control-swing.sh --base-url http://localhost:4077 \
#                                 --db platform_01a0773e_fe20 \
#                                 [--no-seed] [--grep <pattern>]
#
# Exit codes — DISTINCT ON PURPOSE, following the sibling runner's convention:
#   0  the probe ran and produced records
#   1  the probe ran and an assertion FAILED (a real result)
#   2  usage error
#   3  RIG FAULT: /assets/js/app.js did not return 200
#   4  RIG FAULT: the run produced no records at all (crash/timeout)
set -uo pipefail

EXIT_OK=0; EXIT_FAIL=1; EXIT_USAGE=2; EXIT_ASSETS=3; EXIT_NO_DATA=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(dirname "$SCRIPT_DIR")"

BASE_URL=""; DB=""; SEED=1; GREP_PAT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --db)       DB="${2:-}";       shift 2 ;;
    --grep)     GREP_PAT="${2:-}"; shift 2 ;;
    --no-seed)  SEED=0;            shift 1 ;;
    -h|--help)  sed -n '1,26p' "$0"; exit $EXIT_USAGE ;;
    *) echo "measure-call-control-swing: unknown argument '$1'" >&2; exit $EXIT_USAGE ;;
  esac
done
[ -n "$BASE_URL" ] || { echo "measure-call-control-swing: --base-url is required" >&2; exit $EXIT_USAGE; }
[ "$SEED" = "0" ] || [ -n "$DB" ] || {
  echo "measure-call-control-swing: --db is required unless --no-seed is passed" >&2; exit $EXIT_USAGE; }
BASE_URL="${BASE_URL%/}"

# ─── THE ASSETS PRECHECK ────────────────────────────────────────────────────
#
# A fresh worktree needs BOTH `mix deps.get` AND `npm install` in
# apps/platform/assets. Skip the second and app.js 404s: the page still renders
# server-side markup, LiveView never connects, no toggle does anything, and
# every rect recorded is a measurement of a dead page. That failure looks like
# a clean run with suspiciously round deltas, so it is caught HERE, with an
# exit code that can never be confused for a layout result.
ASSET_URL="$BASE_URL/assets/js/app.js"
ASSET_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ASSET_URL" 2>/dev/null || echo 000)"
if [ "$ASSET_CODE" != "200" ]; then
  echo "assets $ASSET_CODE — RIG FAULT, not a measurement"
  echo "  GET $ASSET_URL returned $ASSET_CODE (expected 200)"
  echo "  Run: (cd apps/platform/assets && npm install) && (cd apps/platform && mix assets.build)"
  echo "  Exit $EXIT_ASSETS is reserved for this and is never used for a probe failure."
  exit $EXIT_ASSETS
fi

# ─── THE LIVEKIT PRECHECK ───────────────────────────────────────────────────
#
# The probe needs @in_meeting true so the Leave button renders and the row has
# its real five items. With a non-empty LIVEKIT_URL and no SFU behind it, the
# join is undone ~60ms later by the client's own `meeting_left` push and the
# row silently loses Leave. The spec fails loudly in that case; this note is
# here so the fix is on hand when it does.
echo "note: the dev server must be booted with an EMPTY LIVEKIT_URL and a set"
echo "      LIVEKIT_API_KEY/LIVEKIT_API_SECRET. See the spec header for why."

if [ "$SEED" = "1" ]; then
  "$SCRIPT_DIR/seed-call-control-fixture.sh" --db "$DB" || {
    echo "measure-call-control-swing: fixture seed failed" >&2; exit $EXIT_NO_DATA; }
fi

cd "$E2E_DIR" || exit $EXIT_NO_DATA
RAW="$(mktemp)"; trap 'rm -f "$RAW"' EXIT

# `--retries=0`: a retry re-emits every record and the table would then be
# built from two interleaved runs.
set -- test call_control_label_swing --retries=0 --workers=1 --reporter=list
[ -n "$GREP_PAT" ] && set -- "$@" --grep "$GREP_PAT"
BASE_URL="$BASE_URL" npx playwright "$@" >"$RAW" 2>&1
RUN_STATUS=$?

RECORDS="$(grep -c '^\[fe20\] ' "$RAW" 2>/dev/null || echo 0)"
echo "=== fe20 records ($RECORDS) ==="
grep '^\[fe20\] ' "$RAW" || true

if [ "$RECORDS" -eq 0 ]; then
  echo "measure-call-control-swing: the probe produced NO records (playwright exit $RUN_STATUS)."
  echo "  Treat a crash/timeout as a RIG fault, not a measurement. Raw tail:"
  tail -40 "$RAW"
  exit $EXIT_NO_DATA
fi

if [ "$RUN_STATUS" -ne 0 ]; then
  echo "--- playwright reported a failure; tail follows ---"
  tail -40 "$RAW"
  exit $EXIT_FAIL
fi
exit $EXIT_OK
