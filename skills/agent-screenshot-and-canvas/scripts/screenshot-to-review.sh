#!/usr/bin/env bash
# Capture a screenshot of TARGET_URL via the agent's CDP Chrome, upload it as a
# Suite attachment, embed it in a new canvas, and file a review request.
#
# Required env:
#   SUITE_URL        e.g. http://localhost:4001
#   SUITE_TOKEN      bearer for Suite MCP
#   SUITE_SPACE_ID   uuid of the chat space the canvas lives in
#   VALIDATION_ID    uuid of the validation gate to file evidence against
#   TARGET_URL       URL to screenshot
#   LABEL            human-readable label for the review item
#
# Optional env:
#   CDP_PORT         default 9222
#   SHOT_PATH        default /tmp/agent-shot-<pid>.png
#   CDP_NAVIGATE     path to cdp_navigate.py (default: sibling of this script,
#                    or skills/agent-chrome-cdp/scripts/cdp_navigate.py)
set -euo pipefail

: "${SUITE_URL:?must export SUITE_URL}"
: "${SUITE_TOKEN:?must export SUITE_TOKEN}"
: "${SUITE_SPACE_ID:?must export SUITE_SPACE_ID}"
: "${VALIDATION_ID:?must export VALIDATION_ID}"
: "${TARGET_URL:?must export TARGET_URL}"
: "${LABEL:?must export LABEL}"

CDP_PORT="${CDP_PORT:-9222}"
SHOT_PATH="${SHOT_PATH:-/tmp/agent-shot-$$.png}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CDP_NAVIGATE="${CDP_NAVIGATE:-$SCRIPT_DIR/../../agent-chrome-cdp/scripts/cdp_navigate.py}"

if [ ! -f "$CDP_NAVIGATE" ]; then
  echo "Could not locate cdp_navigate.py (looked at $CDP_NAVIGATE)" >&2
  echo "Set CDP_NAVIGATE to its absolute path." >&2
  exit 1
fi

# 1. Capture
python3 "$CDP_NAVIGATE" "$TARGET_URL" --port "$CDP_PORT" --screenshot "$SHOT_PATH" >/dev/null
SIZE="$(wc -c < "$SHOT_PATH" | tr -d ' ')"
echo "Captured $SHOT_PATH ($SIZE bytes)" >&2

mcp_call() {
  local name="$1" args_json="$2"
  curl -sS "$SUITE_URL/mcp" \
    -H "Authorization: Bearer $SUITE_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg name "$name" --argjson args "$args_json" \
            '{ jsonrpc: "2.0", id: 1, method: "tools/call",
               params: { name: $name, arguments: $args } }')" \
    | jq -r '.result.content[0].text'
}

# 2. Request upload slot
UPLOAD_JSON="$(mcp_call attachment.upload_start "$(jq -n \
  --arg size "$SIZE" \
  '{ filename: "shot.png", content_type: "image/png", byte_size: ($size | tonumber) }')")"
UPLOAD_URL="$(printf '%s' "$UPLOAD_JSON" | jq -r '.upload_url')"
ATTACHMENT_URL="$(printf '%s' "$UPLOAD_JSON" | jq -r '.url')"
ATTACHMENT_ID="$(printf '%s' "$UPLOAD_JSON" | jq -r '.attachment_id')"
echo "Upload slot: $UPLOAD_URL -> $ATTACHMENT_URL (id $ATTACHMENT_ID)" >&2

# 3. PUT the bytes
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  -X PUT "$UPLOAD_URL" \
  -H 'Content-Type: image/png' \
  --data-binary "@$SHOT_PATH")"
case "$HTTP_CODE" in
  200|201|204) ;;
  *) echo "Upload failed (HTTP $HTTP_CODE)" >&2; exit 1 ;;
esac

# 4. Create the canvas
CANVAS_JSON="$(mcp_call canvas.create "$(jq -n \
  --arg space "$SUITE_SPACE_ID" \
  --arg src "$ATTACHMENT_URL" \
  --arg alt "$LABEL" \
  '{ space_id: $space, kind: "evidence", title: "Screenshot evidence",
     content: { children: [ { type: "image", src: $src, alt: $alt } ] } }')")"
CANVAS_ID="$(printf '%s' "$CANVAS_JSON" | jq -r '.canvas_id // .id')"
echo "Canvas created: $CANVAS_ID" >&2

# 5. File the review request
REVIEW_JSON="$(mcp_call review_request_create "$(jq -n \
  --arg vid "$VALIDATION_ID" \
  --arg cid "$CANVAS_ID" \
  --arg label "$LABEL" \
  '{ validation_id: $vid, items: [ { label: $label, canvas_id: $cid } ] }')")"
REVIEW_ID="$(printf '%s' "$REVIEW_JSON" | jq -r '.review_request_id // .id')"

printf 'canvas_id=%s\nreview_request_id=%s\n' "$CANVAS_ID" "$REVIEW_ID"
