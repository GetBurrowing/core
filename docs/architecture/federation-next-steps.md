# Federation: Next Steps

Post-Phase 1 work items for the federated agent experience.

---

## 1. Federated Agent Presence in Suite UI

Suite knows when a runtime's WebSocket is connected or disconnected. Surface this:

- **Chat sidebar**: show green/gray dot next to federated agent's name based on WebSocket connection state
- **Chat header**: "Zip (connected)" vs "Zip (offline)" when in a space with a federated agent
- **Agent Resources detail**: show real-time connection status, last_connected_at, connection uptime
- **Typing indicator timeout**: if no reply arrives within 60s after typing=true, auto-clear to prevent stuck "thinking" state

Implementation: track connected runtime_ids in a Registry or ETS table in RuntimeSocket connect/disconnect callbacks. Expose via a `Federation.runtime_online?(runtime_id)` function. ChatLive and ControlCenterLive read from it.

---

## 2. Error Visibility in Suite

When the federated agent encounters errors (401, 429, 503, timeouts), the channel plugin now sends a human-readable error message back to Suite. Extend this:

- **Visual treatment**: error replies should render differently from normal messages (warning styling, not a regular chat bubble)
- **Structured error metadata**: RuntimeChannel should accept `{ type: "error", error_code: "rate_limited", message: "..." }` in addition to `{ type: "reply" }`, so Suite can style them appropriately
- **Error aggregation**: track error counts per runtime in the Agent Resources detail view. If a runtime is consistently failing (e.g., 5 consecutive 429s), surface a banner: "This agent's model provider is rate-limiting requests"

---

## 3. Hide Irrelevant Config for Federated Agents

When an agent has `runtime_type: "external"`, the Agent Resources detail view should NOT show:

### Hide these (not configurable from Suite for federated agents):
- Model config (primary model, fallbacks) — controlled by the remote OpenClaw
- Sandbox mode — controlled by the remote OpenClaw
- Max concurrent — controlled by the remote OpenClaw
- Thinking default — controlled by the remote OpenClaw
- Workspace files (SOUL.md, etc.) — live on the remote OpenClaw
- Memory browser — memories live on the remote OpenClaw
- Runtime start/stop/refresh buttons — the runtime is the remote OpenClaw, not a local process
- Vault credentials — credentials live on the remote OpenClaw
- Sessions browser — sessions live on the remote OpenClaw

### Show these (Suite-side concerns):
- Agent name and display name (editable — this is how the agent appears in Suite)
- Connection status (online/offline, last connected, uptime)
- Runtime ID and registration info
- Trust level (viewer/participant/collaborator/admin)
- Linked spaces (which spaces this agent is a participant in)
- Attention mode per space (on_mention/collaborative/directed)
- Suspend / Revoke / Regenerate Token actions
- Error history / health summary

### Implementation approach:
- In ControlCenterLive, check `agent.runtime_type` when rendering the detail panel
- `runtime_type == "external"` → show the "Connection" section prominently, hide model/workspace/memory/sessions/vault sections
- `runtime_type == "built_in"` → show everything (current behavior)
- Add a visual indicator on the agent card: "Federated" badge for external agents

---

## 4. Proper Plugin SDK Integration (future)

The `openclaw agent` CLI approach works but spawns a full process per message. Long-term:

- **Investigate `api.runtime.subagent.run()`** — the types exist but the behavior is undocumented. File an issue or ask in the OpenClaw community.
- **Alternative: Gateway WebSocket API** — the plugin could connect to the local gateway WebSocket as an operator and use `chat.send` / `agent.run` methods directly, avoiding process spawning.
- **The plugin SDK refactor** (docs/refactor/plugin-sdk.md) is in progress — once `dispatchReplyFromConfig` and `resolveAgentRoute` are stable, migrate to the proper channel plugin pattern.

---

## 5. Multi-Agent Federation

Once the single-agent federation is solid:

- Allow multiple runtimes to connect simultaneously
- Each runtime brings its own agent
- The attention router's principal agent pattern (ADR 0013) determines who responds to unaddressed messages
- Direct @mentions route to the specific agent's runtime
- Agent capability discovery: runtimes declare what their agent can do (chat, canvas, tools) and Suite surfaces this in the UI

---

## 6. Context Quality

The current attention signal includes a context bundle from the ContextPlane. Improve it:

- **Conversation history**: include recent messages from the space (currently only sends the triggering message)
- **Canvas content summaries**: not just IDs but brief descriptions of what's in each canvas
- **Participant context**: who's in the space, who's online, who's been active recently
- **Context budget**: cap the context bundle at ~4K tokens to avoid bloating the agent's prompt
