#!/usr/bin/env bash
# Measure the meetings call surface and print a MACHINE-READABLE verdict block.
#
# WHY THIS EXISTS. Three rounds of the meetings surface passed their e2e gates
# and were rejected on sight by the sponsor: every element the approved canvas
# called for was PRESENT and every colour token was right, but they were wired
# into the WRONG PARENTS. A presence check passes perfectly on a screen that
# reads as a different design. This runner is how a `manual_approval` on a
# meetings stage reaches the sponsor with NUMBERS attached instead of an agent's
# opinion that a screenshot "looks right".
#
# EVERY LINE PRINTS ITS MEASURED VALUE, ON PASS AS WELL AS ON FAIL. A bare PASS
# is indistinguishable from an assertion that COULD NOT FAIL, which is the exact
# failure this whole task exists to remove.
#
# Usage:
#   measure-meeting-layout.sh --base-url http://192.0.2.200:4046 \
#                             --surface meetings|quickmeet \
#                             --viewport 1280x800|390x844
#
# Exit codes — DISTINCT ON PURPOSE:
#   0  every assertion PASSed
#   1  at least one assertion FAILed (a real layout result)
#   2  usage error
#   3  RIG FAULT: /assets/js/app.js did not return 200. NOT a layout failure.
#   4  RIG FAULT: the spec run produced no verdict data at all (crash/timeout).
set -uo pipefail

EXIT_OK=0; EXIT_LAYOUT_FAIL=1; EXIT_USAGE=2; EXIT_ASSETS=3; EXIT_NO_DATA=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(dirname "$SCRIPT_DIR")"

BASE_URL=""; SURFACE=""; VIEWPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --surface)  SURFACE="${2:-}";  shift 2 ;;
    --viewport) VIEWPORT="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '1,30p' "$0"; exit $EXIT_USAGE ;;
    *) echo "measure-meeting-layout: unknown argument '$1'" >&2; exit $EXIT_USAGE ;;
  esac
done

[ -n "$BASE_URL" ] || { echo "measure-meeting-layout: --base-url is required" >&2; exit $EXIT_USAGE; }
case "$SURFACE" in meetings|quickmeet) ;; *)
  echo "measure-meeting-layout: --surface must be 'meetings' or 'quickmeet', got '${SURFACE:-<empty>}'" >&2
  exit $EXIT_USAGE ;;
esac
case "$VIEWPORT" in 1280x800|390x844) ;; *)
  echo "measure-meeting-layout: --viewport must be '1280x800' or '390x844', got '${VIEWPORT:-<empty>}'" >&2
  exit $EXIT_USAGE ;;
esac
BASE_URL="${BASE_URL%/}"

# ─── PART B — THE ASSETS PRECHECK, IN THE RUNNER, NOT IN A README ───────────
#
# The build-host->test-host rsync runs `--delete` and `priv/static` does not exist on build-host,
# so ANY source edit wipes the built assets on test-host. `/assets/js/app.js` then
# 404s, LiveView never connects, and the page renders with NO TILES AT ALL —
# which reads exactly like the feature being missing and would turn every
# assertion below red for a reason that has nothing to do with layout.
#
# `mix assets.build` exits 1 on `mix esbuild excalidraw` while STILL writing a
# serving bundle, so its exit code proves nothing. THE CURL DOES. And the exit
# code here is DISTINCT (3, never 1) so a future reviewer cannot file a rig
# fault as a layout regression.
ASSET_URL="$BASE_URL/assets/js/app.js"
ASSET_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$ASSET_URL" 2>/dev/null || echo 000)"
if [ "$ASSET_CODE" != "200" ]; then
  echo "assets 404 — rig fault, not a layout failure"
  echo "  GET $ASSET_URL returned $ASSET_CODE (expected 200)"
  echo "  The build-host->test-host rsync runs --delete and priv/static does not exist on build-host, so a"
  echo "  source edit wipes the built assets on test-host; the page then renders with no tiles at"
  echo "  all. That reads exactly like the feature being missing. Rebuild assets in the dev"
  echo "  container (mix assets.build — ignore its exit code, it fails on esbuild excalidraw"
  echo "  while still writing a serving bundle) and re-run until this curl returns 200."
  echo "  DO NOT record this run as a layout regression. Exit code $EXIT_ASSETS is reserved"
  echo "  for exactly this rig fault and is never used for a layout FAIL."
  exit $EXIT_ASSETS
fi

# ─── RIG FINGERPRINT ────────────────────────────────────────────────────────
#
# 400x dev ports are shared across agents. Capturing another agent's server
# renders a DIFFERENT branch and reads as "the feature is missing". This block
# is printed so a reviewer can see WHICH server was measured. It is a partial
# signal and says so: two servers on the same branch fingerprint identically.
ASSET_SHA="$(curl -s --max-time 20 "$ASSET_URL" 2>/dev/null | sha256sum | cut -c1-16)"
ASSET_LEN="$(curl -s -o /dev/null -w '%{size_download}' --max-time 20 "$ASSET_URL" 2>/dev/null || echo 0)"

# MEASURED, NOT ASSUMED: the asset hash ALONE does not identify the server.
# Checked 2026-09-02 — this task's container on :4046 and the sibling task's on
# :4040 return a BYTE-IDENTICAL app.js, so a reviewer comparing hashes would see
# a match while measuring the wrong branch entirely. The identifying question is
# WHICH CONTAINER owns the port, so ask test-host directly. Best-effort: if the ssh
# is unavailable the block says UNKNOWN rather than silently claiming a match.
PORT="${BASE_URL##*:}"
WORKTREE_ID="$(basename "$(cd "$E2E_DIR/.." && pwd)")"
SERVED_BY="$(ssh -o BatchMode=yes -o ConnectTimeout=6 deploy@test-host.local \
  "podman ps --format '{{.Names}} {{.Ports}}'" 2>/dev/null \
  | awk -v p=":$PORT->" '$0 ~ p {print $1}' | head -1)"
if [ -z "$SERVED_BY" ]; then
  SERVER_ID="UNKNOWN (could not ask test-host which container owns port $PORT)"
elif [ "$SERVED_BY" = "dev-platform-$WORKTREE_ID" ]; then
  SERVER_ID="$SERVED_BY == dev-platform-$WORKTREE_ID (MATCHES this worktree)"
else
  SERVER_ID="$SERVED_BY != dev-platform-$WORKTREE_ID -- WRONG SERVER: this port is served by ANOTHER TASK BRANCH"
fi

cd "$E2E_DIR" || exit $EXIT_NO_DATA
RAW="$(mktemp)"; trap 'rm -f "$RAW"' EXIT

# `--retries=0`: a retry re-emits every measurement line and the verdict block
# would then be built from two interleaved runs.
BASE_URL="$BASE_URL" npx playwright test meeting_layout_geometry \
  --retries=0 --workers=1 --reporter=list \
  --grep "$SURFACE @ $VIEWPORT" >"$RAW" 2>&1
RUN_STATUS=$?

VERDICT="$(python3 "$SCRIPT_DIR/verdict_block.py" \
  --raw "$RAW" --surface "$SURFACE" --viewport "$VIEWPORT" \
  --base-url "$BASE_URL" --asset-sha "$ASSET_SHA" --asset-bytes "$ASSET_LEN" \
  --server-id "$SERVER_ID" \
  --run-status "$RUN_STATUS")"
VERDICT_STATUS=$?
printf '%s\n' "$VERDICT"

# An `.unmeasured` row means an assertion died BEFORE printing a number, so the
# verdict block has no measurement to show for it and the reason lives only in
# the spec output. Dump that tail rather than leaving the reader with a FAIL and
# nothing to read — an unexplained FAIL is how a rig state gets filed as a
# layout regression.
if printf '%s' "$VERDICT" | grep -q '\.unmeasured'; then
  echo "--- spec output tail (an assertion failed before logging a measurement) ---"
  tail -40 "$RAW"
  echo "--- end spec output tail ---"
fi

case "$VERDICT_STATUS" in
  0) exit $EXIT_OK ;;
  1) exit $EXIT_LAYOUT_FAIL ;;
  *) echo "measure-meeting-layout: the spec produced no verdict data (playwright exit $RUN_STATUS)."
     echo "  Raw output follows — treat a crash/timeout as a RIG fault, not a layout result."
     tail -40 "$RAW"
     exit $EXIT_NO_DATA ;;
esac
