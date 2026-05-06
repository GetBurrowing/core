#!/usr/bin/env bash
# Set up an isolated OpenClaw gateway pointed at a local Suite dev server.
#
# Reads the following env vars (export before running):
#   OPENCLAW_STATE_DIR    e.g. $HOME/.openclaw-suite-dev
#   OPENCLAW_GATEWAY_PORT e.g. 19001
#   SUITE_PORT            port the Suite dev server is listening on
#   SUITE_AGENT_SLUG      e.g. dev-zip
#   SUITE_RUNTIME_ID      e.g. dev-zip-rt
#   SUITE_TOKEN           bearer minted by the Suite admin UI
#
# Idempotent: re-running with the same env will overwrite the channel account,
# MCP server, and persona for SUITE_AGENT_SLUG.
set -euo pipefail

: "${OPENCLAW_STATE_DIR:?must export OPENCLAW_STATE_DIR}"
: "${OPENCLAW_GATEWAY_PORT:?must export OPENCLAW_GATEWAY_PORT}"
: "${SUITE_PORT:?must export SUITE_PORT}"
: "${SUITE_AGENT_SLUG:?must export SUITE_AGENT_SLUG}"
: "${SUITE_RUNTIME_ID:?must export SUITE_RUNTIME_ID}"
: "${SUITE_TOKEN:?must export SUITE_TOKEN}"

mkdir -p "$OPENCLAW_STATE_DIR"

if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw CLI not found on PATH; installing globally via npm" >&2
  npm install -g openclaw
fi

OC=(openclaw --state-dir "$OPENCLAW_STATE_DIR")

if [ ! -f "$OPENCLAW_STATE_DIR/openclaw.json" ]; then
  "${OC[@]}" init --non-interactive
fi

"${OC[@]}" config set gateway.port "$OPENCLAW_GATEWAY_PORT"

if ! "${OC[@]}" plugins list 2>/dev/null | grep -q '^startup-suite-channel-plugin'; then
  "${OC[@]}" plugins install startup-suite-channel-plugin
fi

SUITE_WS="ws://localhost:${SUITE_PORT}/runtime/ws"
SUITE_MCP="http://localhost:${SUITE_PORT}/mcp"
SLUG="$SUITE_AGENT_SLUG"

# (a) channel account
"${OC[@]}" config set "channels.startup-suite.accounts.$SLUG" --strict-json "{
  \"url\": \"$SUITE_WS\",
  \"runtimeId\": \"$SUITE_RUNTIME_ID\",
  \"token\": \"$SUITE_TOKEN\",
  \"autoJoinSpaces\": [],
  \"useMcpTools\": true
}"

# (b) MCP server
"${OC[@]}" config set "mcp.servers.suite-$SLUG" --strict-json "{
  \"url\": \"$SUITE_MCP\",
  \"transport\": \"streamable-http\",
  \"headers\": { \"Authorization\": \"Bearer $SUITE_TOKEN\" }
}"

# (c) agent persona — append to the end of agents.list if absent
COUNT="$(jq '.agents.list | length' "$OPENCLAW_STATE_DIR/openclaw.json")"
EXISTING_INDEX="$(jq -r --arg slug "$SLUG" \
  '[.agents.list | to_entries[] | select(.value.id==$slug) | .key] | first // empty' \
  "$OPENCLAW_STATE_DIR/openclaw.json")"
TARGET_INDEX="${EXISTING_INDEX:-$COUNT}"
"${OC[@]}" config set "agents.list[$TARGET_INDEX]" --strict-json "{
  \"id\": \"$SLUG\",
  \"name\": \"$SLUG\",
  \"workspace\": \"$OPENCLAW_STATE_DIR/workspace-$SLUG\",
  \"identity\": { \"name\": \"$SLUG\" },
  \"tools\": {
    \"profile\": \"full\",
    \"alsoAllow\": [\"mcp:suite-$SLUG\"]
  }
}"

# (d) routing binding
"${OC[@]}" agents bind --agent "$SLUG" --bind "startup-suite:$SLUG" || true

# Start (or restart) the gateway.
"${OC[@]}" gateway restart >/dev/null 2>&1 || "${OC[@]}" gateway start

# Wait briefly for the WebSocket to come up.
for _ in $(seq 1 20); do
  if grep -q "Joined runtime:$SUITE_RUNTIME_ID" "$OPENCLAW_STATE_DIR/logs/gateway.log" 2>/dev/null; then
    echo "Gateway connected to Suite runtime $SUITE_RUNTIME_ID" >&2
    exit 0
  fi
  sleep 1
done

echo "Gateway did not log 'Joined runtime:$SUITE_RUNTIME_ID' within 20 s." >&2
echo "Tail of gateway log:" >&2
tail -30 "$OPENCLAW_STATE_DIR/logs/gateway.log" >&2 || true
exit 1
