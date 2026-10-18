#!/usr/bin/env bash
# Set up an isolated OpenClaw gateway pointed at a local Suite dev server.
#
# Reads the following env vars (export before running):
#   OPENCLAW_STATE_DIR    e.g. $HOME/.openclaw-suite-dev
#   OPENCLAW_GATEWAY_PORT e.g. 19001
#   BURROW_PORT           port the Suite dev server is listening on
#   BURROW_AGENT_SLUG     e.g. dev-zip
#   BURROW_RUNTIME_ID     e.g. dev-zip-rt
#   BURROW_TOKEN          bearer minted by the Suite admin UI
#
# The legacy SUITE_PORT, SUITE_AGENT_SLUG, SUITE_RUNTIME_ID and SUITE_TOKEN
# names still work and print a deprecation line on stderr.
#
# Idempotent: re-running with the same env will overwrite the channel account,
# MCP server, and persona for BURROW_AGENT_SLUG.
set -euo pipefail

# compat BURROW_NAME LEGACY_NAME: set and export the BURROW_ variable from
# itself, else from the legacy name with one deprecation line on stderr. An
# empty value counts as unset; when both are set the BURROW_ value wins.
compat() {
  burrow=$1 suite=$2
  eval "b=\${$burrow:-} s=\${$suite:-}"
  if [ -z "$b" ]; then
    if [ -z "$s" ]; then
      echo "must export $burrow (or legacy $suite)" >&2
      exit 1
    fi
    echo "deprecated: $suite is set; rename it to $burrow" >&2
    eval "$burrow=\$s"
  fi
  export "${burrow?}"
}

: "${OPENCLAW_STATE_DIR:?must export OPENCLAW_STATE_DIR}"
: "${OPENCLAW_GATEWAY_PORT:?must export OPENCLAW_GATEWAY_PORT}"
compat BURROW_PORT SUITE_PORT
compat BURROW_AGENT_SLUG SUITE_AGENT_SLUG
compat BURROW_RUNTIME_ID SUITE_RUNTIME_ID
compat BURROW_TOKEN SUITE_TOKEN

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

BURROW_WS="ws://localhost:${BURROW_PORT}/runtime/ws"
BURROW_MCP="http://localhost:${BURROW_PORT}/mcp"
SLUG="$BURROW_AGENT_SLUG"

# (a) channel account
"${OC[@]}" config set "channels.startup-suite.accounts.$SLUG" --strict-json "{
  \"url\": \"$BURROW_WS\",
  \"runtimeId\": \"$BURROW_RUNTIME_ID\",
  \"token\": \"$BURROW_TOKEN\",
  \"autoJoinSpaces\": [],
  \"useMcpTools\": true
}"

# (b) MCP server
"${OC[@]}" config set "mcp.servers.suite-$SLUG" --strict-json "{
  \"url\": \"$BURROW_MCP\",
  \"transport\": \"streamable-http\",
  \"headers\": { \"Authorization\": \"Bearer $BURROW_TOKEN\" }
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
  if grep -q "Joined runtime:$BURROW_RUNTIME_ID" "$OPENCLAW_STATE_DIR/logs/gateway.log" 2>/dev/null; then
    echo "Gateway connected to Suite runtime $BURROW_RUNTIME_ID" >&2
    exit 0
  fi
  sleep 1
done

echo "Gateway did not log 'Joined runtime:$BURROW_RUNTIME_ID' within 20 s." >&2
echo "Tail of gateway log:" >&2
tail -30 "$OPENCLAW_STATE_DIR/logs/gateway.log" >&2 || true
exit 1
