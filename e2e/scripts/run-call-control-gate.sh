#!/usr/bin/env bash
# Run the FE-20 call-control GEOMETRY GATE, and stage 1's baseline probe
# beside it. Task 01a0773e-cea9-7001-98f5-be6c37607e91, stage 3.
#
# WHY BOTH, AND IN THIS ORDER. The probe (`call_control_label_swing.spec.ts`)
# is the instrument stage 1 measured `main` with, and it is deliberately
# unmodified: running it here means the fix and the mutant are measured by
# the same instrument as the baseline, not by a re-creation of it. The gate
# (`call_control_geometry_gate.spec.ts`) is the assertion layer that did not
# exist at stage 1, because a threshold invented before the measurement
# exists is a threshold fitted to a guess.
#
# THE MUTATION RUN USES THIS EXACT COMMAND. Revert the stage-2 change, run
# `mix assets.build`, and invoke this script again with the same arguments.
# Nothing in the spec files is edited for the mutant: the gate resolves the
# visible label by discarding words held at `visibility: hidden` and falling
# back to the span's own text, so it reads both trees unchanged.
#
# Usage:
#   run-call-control-gate.sh --base-url http://localhost:4077 \
#                            --db platform_01a0773e_fe20 \
#                            [--no-seed] [--gate-only] [--probe-only]
#
# Exit codes, distinct on purpose and matching the sibling runner:
#   0  everything ran and passed
#   1  a spec ran and an assertion FAILED (a real result, including a mutant
#      dying, which is what stage 3's case 5 wants to see)
#   2  usage error
#   3  RIG FAULT: /assets/js/app.js did not return 200
#   4  RIG FAULT: a run produced no records at all (crash or timeout)
set -uo pipefail

EXIT_OK=0; EXIT_FAIL=1; EXIT_USAGE=2; EXIT_ASSETS=3; EXIT_NO_DATA=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(dirname "$SCRIPT_DIR")"

BASE_URL=""; DB=""; SEED=1; RUN_GATE=1; RUN_PROBE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url)  BASE_URL="${2:-}"; shift 2 ;;
    --db)        DB="${2:-}";       shift 2 ;;
    --no-seed)   SEED=0;            shift 1 ;;
    --gate-only) RUN_PROBE=0;       shift 1 ;;
    --probe-only) RUN_GATE=0;       shift 1 ;;
    -h|--help)   sed -n '1,33p' "$0"; exit $EXIT_USAGE ;;
    *) echo "run-call-control-gate: unknown argument '$1'" >&2; exit $EXIT_USAGE ;;
  esac
done
[ -n "$BASE_URL" ] || { echo "run-call-control-gate: --base-url is required" >&2; exit $EXIT_USAGE; }
[ "$SEED" = "0" ] || [ -n "$DB" ] || {
  echo "run-call-control-gate: --db is required unless --no-seed is passed" >&2; exit $EXIT_USAGE; }
BASE_URL="${BASE_URL%/}"

# ─── THE ASSETS PRECHECK ────────────────────────────────────────────────────
# Without `npm install` in apps/platform/assets, app.js 404s: the page still
# renders server-side markup, LiveView never connects, no toggle does
# anything, and every rect is a measurement of a dead page whose row did not
# move because nothing ever happened to it. Caught here, with an exit code
# that can never be read as a layout result.
ASSET_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE_URL/assets/js/app.js" 2>/dev/null || echo 000)"
if [ "$ASSET_CODE" != "200" ]; then
  echo "assets $ASSET_CODE — RIG FAULT, not a measurement"
  echo "  GET $BASE_URL/assets/js/app.js returned $ASSET_CODE (expected 200)"
  echo "  Run: (cd apps/platform/assets && npm install) && (cd apps/platform && mix assets.build)"
  exit $EXIT_ASSETS
fi

# The dev server must be booted with an EMPTY LIVEKIT_URL and a set
# LIVEKIT_API_KEY / LIVEKIT_API_SECRET. With a URL and no SFU behind it the
# join is undone ~60ms later by the client's own `meeting_left` push and the
# row silently loses its Leave button. Both specs fail loudly in that case.
echo "note: boot the dev server with LIVEKIT_URL= (empty), key and secret set."

if [ "$SEED" = "1" ]; then
  "$SCRIPT_DIR/seed-call-control-fixture.sh" --db "$DB" || {
    echo "run-call-control-gate: fixture seed failed" >&2; exit $EXIT_NO_DATA; }
fi

cd "$E2E_DIR" || exit $EXIT_NO_DATA
STATUS=$EXIT_OK

run_spec() {
  local spec="$1" tag="$2" raw
  raw="$(mktemp)"
  echo
  echo "═══ $tag ($spec) ═══"
  # `--retries=0`: a retry re-emits every record and the tables below would
  # then be built from two interleaved runs.
  BASE_URL="$BASE_URL" npx playwright test "$spec" --retries=0 --workers=1 --reporter=list \
    >"$raw" 2>&1
  local rc=$?
  local records
  records="$(grep -cE '^\[fe20(-gate)?\] ' "$raw" 2>/dev/null || echo 0)"
  echo "--- records ($records) ---"
  grep -E '^\[fe20(-gate)?\] ' "$raw" || true
  if [ "$records" -eq 0 ]; then
    echo "$tag: NO records (playwright exit $rc) — treat a crash or timeout as a rig fault."
    tail -40 "$raw"; rm -f "$raw"
    exit $EXIT_NO_DATA
  fi
  if [ "$rc" -ne 0 ]; then
    echo "--- $tag reported a FAILURE; tail follows ---"
    tail -60 "$raw"
    STATUS=$EXIT_FAIL
  else
    echo "--- $tag passed ---"
  fi
  rm -f "$raw"
}

[ "$RUN_PROBE" = "1" ] && run_spec call_control_label_swing "BASELINE PROBE (stage 1, unmodified)"
[ "$RUN_GATE" = "1" ] && run_spec call_control_geometry_gate "GEOMETRY GATE (stage 3)"

exit $STATUS
