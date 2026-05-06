---
name: openclaw-isolated-gateway
description: Stand up an isolated OpenClaw gateway against a local Suite dev server, on a non-default port and state directory so it doesn't collide with your primary OpenClaw install. Covers npm-global install, registering the local Suite as a federated agent runtime, installing and configuring the `startup-suite-channel-plugin`, verifying the WebSocket + MCP path, and clean teardown. Use when you want to exercise federation behavior end-to-end without touching production credentials or your day-to-day OpenClaw config.
---

# OpenClaw Isolated Gateway

This skill stands up a sandboxed [OpenClaw](https://www.npmjs.com/package/openclaw)
gateway pointed at a Suite dev server (see `suite-dev-server`). It uses a
dedicated state directory and a non-default port so it cannot collide with any
existing OpenClaw install you may already have running for production work.

## Prerequisites

- A Suite dev server is reachable. Use `suite-dev-server` to start one and note
  the port — call it `SUITE_PORT` below. The example assumes
  `http://localhost:$SUITE_PORT`.
- Node.js 20+ and `npm` on `PATH`. (`asdf plugin add nodejs && asdf install nodejs 20`
  or your platform's package manager.)
- `curl` and `jq` for the verification step.

## 1. Install OpenClaw under a dedicated state directory

OpenClaw is npm-global. Pick a sandbox state dir and a non-default port up front:

```bash
export OPENCLAW_STATE_DIR="$HOME/.openclaw-suite-dev"
export OPENCLAW_GATEWAY_PORT=19001         # any free port; default is 18789
mkdir -p "$OPENCLAW_STATE_DIR"

# Install the CLI into the standard npm-global prefix.
npm install -g openclaw

# Initialize the isolated config in the sandbox dir.
openclaw --state-dir "$OPENCLAW_STATE_DIR" init --non-interactive
```

`init --non-interactive` writes `$OPENCLAW_STATE_DIR/openclaw.json` with sensible
defaults. The gateway will listen on `127.0.0.1:$OPENCLAW_GATEWAY_PORT`.

> Tip: every subsequent `openclaw …` command in this skill assumes
> `--state-dir "$OPENCLAW_STATE_DIR"`. If you'd rather not pass it every time,
> `export OPENCLAW_STATE=$OPENCLAW_STATE_DIR` and create a tiny shell alias.

Set the gateway port:

```bash
openclaw --state-dir "$OPENCLAW_STATE_DIR" config set gateway.port "$OPENCLAW_GATEWAY_PORT"
```

## 2. Register the local Suite as a federated agent runtime

The Suite admin UI lets you create an agent and a runtime row, mint a bearer
token, and download the credentials. With the Suite dev server running:

1. Visit `http://localhost:$SUITE_PORT/dev/login` and log in as the dev user.
2. Navigate to **Admin -> Agents**.
3. Click **New agent**. Pick a slug (e.g. `dev-zip`), a display name, and the
   bundle list — the safe minimum for federation work is:

   ```
   federation space context_read messaging review canvas task plan org_context skill attachment
   ```

4. After save, open the agent and click **New runtime**. Pick a runtime id
   (e.g. `dev-zip-rt`), choose **OpenClaw** as the runtime type, click
   **Generate token**, and **copy the bearer immediately** — Suite shows it once.

You'll end up with three values to plug into OpenClaw:

```
SUITE_AGENT_SLUG=dev-zip
SUITE_RUNTIME_ID=dev-zip-rt
SUITE_TOKEN=<paste>
```

Save the token to a file so you can refer to it without re-printing:

```bash
printf '%s\n' "$SUITE_TOKEN" > "$OPENCLAW_STATE_DIR/dev-zip.token"
chmod 600 "$OPENCLAW_STATE_DIR/dev-zip.token"
```

## 3. Install and wire `startup-suite-channel-plugin`

The plugin bridges OpenClaw's per-agent runtime to a Suite WebSocket. Install it
into the sandbox:

```bash
openclaw --state-dir "$OPENCLAW_STATE_DIR" \
  plugins install startup-suite-channel-plugin
```

Configure the channel account, MCP server, and agent persona via
`openclaw config set` (do NOT hand-edit `openclaw.json` — it gets clobbered on
gateway start).

```bash
SUITE_PORT=4001                       # whatever your suite-dev-server printed
SUITE_WS=ws://localhost:$SUITE_PORT/runtime/ws
SUITE_MCP=http://localhost:$SUITE_PORT/mcp
SLUG=dev-zip
TOKEN="$(cat "$OPENCLAW_STATE_DIR/$SLUG.token")"

# (a) channel account — the WebSocket runtime the plugin connects to.
openclaw --state-dir "$OPENCLAW_STATE_DIR" config set \
  "channels.startup-suite.accounts.$SLUG" --strict-json "{
    \"url\": \"$SUITE_WS\",
    \"runtimeId\": \"${SLUG}-rt\",
    \"token\": \"$TOKEN\",
    \"autoJoinSpaces\": [],
    \"useMcpTools\": true
  }"

# (b) MCP server — the Suite's tool-call endpoint, scoped to this agent.
openclaw --state-dir "$OPENCLAW_STATE_DIR" config set \
  "mcp.servers.suite-$SLUG" --strict-json "{
    \"url\": \"$SUITE_MCP\",
    \"transport\": \"streamable-http\",
    \"headers\": { \"Authorization\": \"Bearer $TOKEN\" }
  }"

# (c) Agent persona — appended to agents.list.
COUNT="$(jq '.agents.list | length' "$OPENCLAW_STATE_DIR/openclaw.json")"
openclaw --state-dir "$OPENCLAW_STATE_DIR" config set \
  "agents.list[$COUNT]" --strict-json "{
    \"id\": \"$SLUG\",
    \"name\": \"Dev Zip\",
    \"workspace\": \"$OPENCLAW_STATE_DIR/workspace-$SLUG\",
    \"identity\": { \"name\": \"Dev Zip\" },
    \"tools\": {
      \"profile\": \"full\",
      \"alsoAllow\": [\"mcp:suite-$SLUG\"]
    }
  }"

# (d) Routing binding — directs Suite traffic for this agent to the OpenClaw agent.
openclaw --state-dir "$OPENCLAW_STATE_DIR" \
  agents bind --agent "$SLUG" --bind "startup-suite:$SLUG"
```

The helper `scripts/setup-isolated-gateway.sh` chains all of the above; see
"Helper script" below.

## 4. Start the gateway and verify

```bash
openclaw --state-dir "$OPENCLAW_STATE_DIR" gateway start
```

The gateway starts on `127.0.0.1:$OPENCLAW_GATEWAY_PORT`. Tail its log:

```bash
tail -f "$OPENCLAW_STATE_DIR/logs/gateway.log"
```

Within a few seconds you should see:

```
[suite-client] Connecting to ws://localhost:<SUITE_PORT>/runtime/ws
[suite-client] Joined runtime:dev-zip-rt
```

Confirm the Suite side sees it via the Suite MCP `federation_status` tool:

```bash
SUITE_TOKEN="$(cat "$OPENCLAW_STATE_DIR/dev-zip.token")"
curl -sS "$SUITE_MCP" \
  -H "Authorization: Bearer $SUITE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"federation_status","arguments":{}}}' \
  | jq -r '.result.content[0].text | fromjson | .runtimes[] | "\(.runtime_id) online=\(.online)"'
# dev-zip-rt online=true
```

If `online=false`, check the gateway log first; the WebSocket path
`/runtime/ws` is fixed in the Suite endpoint, so a 404 there means a typo in
`channels.startup-suite.accounts.<slug>.url`.

## 5. Cleanup

Stop the gateway and remove the sandbox state:

```bash
openclaw --state-dir "$OPENCLAW_STATE_DIR" gateway stop
rm -rf "$OPENCLAW_STATE_DIR"
```

If you also want to retire the Suite-side records, use the admin UI to delete the
agent + runtime, or directly via the Suite MCP / DB.

## Helper script

`scripts/setup-isolated-gateway.sh` chains steps 1, 3, and 4 — install OpenClaw
into the sandbox, wire the plugin from already-exported env vars (`SUITE_PORT`,
`SUITE_AGENT_SLUG`, `SUITE_RUNTIME_ID`, `SUITE_TOKEN`,
`OPENCLAW_GATEWAY_PORT`, `OPENCLAW_STATE_DIR`), start the gateway, and verify
the WebSocket + MCP path. Step 2 (creating the Suite agent + runtime + bearer)
remains a manual UI flow because it's a security boundary.

## Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `EADDRINUSE` on gateway start | Another OpenClaw instance owns `OPENCLAW_GATEWAY_PORT`. | Pick a different port and re-set `gateway.port`. |
| `[suite-client] Connect failed (404)` | Wrong WebSocket path. | Must be `/runtime/ws`, not `/mcp`. |
| `[suite-client] Connect failed (401)` | Bearer doesn't match a runtime row. | Re-mint the token in the Suite admin UI; update the channel account. |
| `online=false` after a clean connect | Plugin connected then disconnected. | Tail the Suite dev-server log for the disconnect reason (often a bundle the runtime requested but isn't allowed). |
