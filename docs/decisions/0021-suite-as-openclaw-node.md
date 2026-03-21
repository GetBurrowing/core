# ADR 0021: Startup Suite as an OpenClaw Node

**Status:** Proposed  
**Date:** 2026-03-20  
**Deciders:** Rowan, Zip  
**Extends:** ADR 0014 (Agent Federation), ADR 0012 (Canvas Architecture)  

---

## Context

The Startup Suite platform connects to OpenClaw via two mechanisms:

1. **RuntimeChannel** — a Phoenix WebSocket channel for agent federation
   (attention signals, replies, typing indicators, tool calls)
2. **Suite-specific tools** — registered via `api.registerTool()` in the
   OpenClaw plugin (canvas_create, send_media, etc.)

This architecture has hit friction:

- **Tool call args serialization bug**: OpenClaw's tool execution calls
  `execute(toolCallId, args, signal)` but the plugin's signature mismatch
  caused the Anthropic tool_use ID to arrive as the `args` parameter.
  Canvas creation was broken for a day before diagnosis.
- **Canvas is a rendering surface, not an RPC call**: Creating and updating
  canvases through tool calls is inherently limited. Each operation requires
  a new tool definition. The node protocol already has a rich canvas command
  surface (`present`, `navigate`, `eval`, `snapshot`, `a2ui_push`) that
  handles the full lifecycle.
- **No incremental updates**: Tool calls are request-response. The node
  protocol supports streaming updates, snapshots, and JavaScript evaluation
  inside the canvas — capabilities that would require many individual tools
  to replicate.
- **Two parallel surfaces**: The OpenClaw `canvas` tool already exists and
  targets nodes. If Suite registered as a node, agents could use the existing,
  battle-tested canvas tool instead of custom Suite-specific tools.

Meanwhile, OpenClaw's **node protocol** is mature and well-documented:

- Nodes connect via WebSocket with `role: "node"`
- Nodes expose a command surface (canvas, camera, device, system, etc.)
- The Gateway handles device pairing, command routing, and capability
  negotiation
- Canvas commands are first-class: present, navigate, eval, snapshot, A2UI

---

## Decision

Startup Suite will register as an **OpenClaw node** in addition to its
existing RuntimeChannel connection. The node connection exposes Suite's
canvas rendering surface through the standard OpenClaw node protocol.

This gives agents the full OpenClaw canvas toolkit for free:

```
Agent → canvas tool → Gateway → Node (Suite) → LiveView canvas rendering
```

---

## Architecture

### Dual Connection Model

Suite maintains two WebSocket connections to the OpenClaw Gateway:

```
Startup Suite Server
  ├─ RuntimeChannel connection (existing)
  │   └─ Agent federation: attention, replies, typing, tool calls
  │
  └─ Node connection (new)
      └─ Canvas surface: present, navigate, eval, snapshot, a2ui
      └─ Future: exec, device commands
```

Both connections authenticate to the same Gateway. The RuntimeChannel handles
chat-level agent communication. The node connection handles device-level
rendering and interaction.

### Node Registration

On startup, Suite connects to the OpenClaw Gateway WebSocket as a node:

```
WS connect → ws://<gateway>:18789
  role: "node"
  device_id: "suite-<instance-id>"
  display_name: "Startup Suite"
  platform: "suite"
  capabilities: ["canvas.present", "canvas.navigate", "canvas.eval",
                  "canvas.snapshot", "canvas.a2ui_push", "canvas.a2ui_reset"]
```

The Gateway creates a device pairing request. Once approved, Suite appears
in `openclaw nodes status` as a paired node.

### Canvas Command Handler

Suite implements a node command handler that translates OpenClaw canvas
commands into LiveView actions:

| OpenClaw Command | Suite Action |
|---|---|
| `canvas.present` | Create or show a canvas, navigate to URL |
| `canvas.navigate` | Navigate an existing canvas to a new URL or content |
| `canvas.eval` | Execute JavaScript in the canvas WebView via JS hook |
| `canvas.snapshot` | Capture canvas state as PNG via html2canvas or server-side |
| `canvas.a2ui_push` | Push A2UI JSONL content to the canvas |
| `canvas.a2ui_reset` | Reset the canvas A2UI state |
| `canvas.hide` | Hide/close the canvas |

Each command arrives as a JSON-RPC message over the node WebSocket:

```json
{
  "type": "node.invoke",
  "command": "canvas.present",
  "params": {
    "url": "https://example.com",
    "width": 800,
    "height": 600
  },
  "requestId": "req-123"
}
```

Suite acknowledges with a result:

```json
{
  "type": "node.invokeResult",
  "requestId": "req-123",
  "result": { "ok": true }
}
```

### Canvas Rendering in Suite

When a canvas command arrives, Suite:

1. Resolves which space the canvas belongs to (from the command context or
   a default mapping)
2. Creates or updates a `Platform.Chat.Canvas` record
3. Broadcasts via PubSub to all LiveView sessions viewing that space
4. The `CanvasRenderer` LiveView component renders the content

For `canvas.present` with a URL: render in an iframe or fetch + render.
For `canvas.a2ui_push`: render the A2UI JSONL as structured HTML components.
For `canvas.eval`: execute JS in the client via a `phx-hook` and return
the result through the node WebSocket.
For `canvas.snapshot`: trigger a client-side screenshot via `html2canvas`
or a server-side headless capture, base64-encode, return through the
node WebSocket.

### Node Client (Elixir)

A new `Platform.Federation.NodeClient` module manages the node WebSocket
connection:

```elixir
defmodule Platform.Federation.NodeClient do
  @moduledoc """
  Connects to the OpenClaw Gateway as a node, exposing Suite's canvas
  rendering surface through the standard node protocol.
  """

  use WebSockex

  # Connect with role: "node" and device metadata
  # Handle incoming node.invoke commands
  # Dispatch to Platform.Federation.NodeCommandHandler
  # Return node.invokeResult responses
  # Reconnect with backoff on disconnect
end
```

### Command Handler

```elixir
defmodule Platform.Federation.NodeCommandHandler do
  @moduledoc """
  Routes node commands to the appropriate Suite subsystem.
  """

  def handle_command("canvas.present", params, ctx)
  def handle_command("canvas.navigate", params, ctx)
  def handle_command("canvas.eval", params, ctx)
  def handle_command("canvas.snapshot", params, ctx)
  def handle_command("canvas.a2ui_push", params, ctx)
  def handle_command("canvas.a2ui_reset", params, ctx)
  def handle_command("canvas.hide", params, ctx)
end
```

### Configuration

Suite's node connection is configured alongside the existing runtime
connection:

```elixir
# config/runtime.exs
config :platform, Platform.Federation.NodeClient,
  gateway_url: "ws://127.0.0.1:18789",
  device_id: "suite-#{System.get_env("INSTANCE_ID", "default")}",
  display_name: "Startup Suite",
  token: System.get_env("OPENCLAW_GATEWAY_TOKEN"),
  capabilities: ~w(canvas.present canvas.navigate canvas.eval
                    canvas.snapshot canvas.a2ui_push canvas.a2ui_reset),
  reconnect_interval_ms: 5_000,
  max_reconnect_interval_ms: 60_000
```

---

## Chat Integration Model

### Space-Scoped Canvas

Node canvas commands are **space-scoped**. When an agent creates or updates
a canvas, it appears within a specific chat space where participants can see
and interact with it.

**Space resolution priority:**

1. Explicit `space_id` in command params (agent specified it)
2. Current engagement context from RuntimeChannel (whichever space the
   agent is actively replying in — tracked via sticky engagement state)
3. Default space (first space where the agent is principal or member)

The NodeClient tracks the agent's current space context by observing
attention signals that arrive through the RuntimeChannel. Canvas commands
inherit that context automatically — the agent doesn't need to specify
a space_id when replying to a conversation and creating a canvas in the
same flow.

### Canvas Rendering in the Chat UI

Canvas appears in two places simultaneously:

```
┌──────────────────────────────────┬───────────────────┐
│  Chat messages                   │  Canvas panel     │
│                                  │                   │
│  Rowan: diagram the pipeline?     │  ┌─────────────┐ │
│                                  │  │             │ │
│  Zip: Here's the deploy pipeline │  │  [diagram]  │ │
│  📎 Canvas: Deploy Pipeline      │  │             │ │
│                                  │  └─────────────┘ │
│  Rowan: add the CI step           │                   │
│                                  │  (live updates)   │
│  Zip: Updated ✓                  │                   │
└──────────────────────────────────┴───────────────────┘
```

**1. Inline reference in chat:** When the agent creates a canvas, a message
with `content_type: "canvas"` is posted in the conversation. This shows as
a clickable card ("📎 Canvas: Deploy Pipeline") that focuses the canvas
panel. The existing `Platform.Chat.Canvas` schema and `CanvasRenderer`
component handle this — no new UI pattern needed.

**2. Side panel:** The canvas renders in a persistent side panel (desktop)
or overlay sheet (mobile). The panel stays visible while the conversation
continues. Multiple canvases are tabbed.

### Canvas Lifecycle in Chat

| Event | Chat behavior | Canvas panel |
|---|---|---|
| Agent creates canvas (`canvas.present`) | Canvas message posted in chat | Panel opens with content |
| Agent updates canvas (`canvas.navigate`, `canvas.eval`, `canvas.a2ui_push`) | No new chat message | Panel updates live via PubSub |
| Agent takes snapshot (`canvas.snapshot`) | Nothing visible | Returns base64 PNG to agent |
| Agent hides canvas (`canvas.hide`) | No chat message | Panel closes |
| User closes panel | No chat message | Panel closes, canvas persists |
| User clicks canvas reference in chat | Nothing | Panel reopens to that canvas |
| Run completes | No change | Canvas persists as an artifact |
| New canvas in same space | New canvas message in chat | Tabbed alongside existing |

**Key principle:** Canvas creation and chat messages are **two separate
actions** from the agent. The agent sends a reply ("Here's the diagram")
and creates a canvas — they're independent. The NodeCommandHandler
automatically posts the canvas reference message in chat when
`canvas.present` is called, so the agent doesn't need to coordinate both
manually.

### Feedback: User → Canvas → Agent

Users can interact with canvases. Interactions feed back to the agent:

**Passive feedback (automatic):**
- When a user opens, closes, or switches canvas tabs, a lightweight
  context event is pushed to the agent's run context (if active).
- Canvas visibility state is tracked — the agent knows if anyone is
  looking at its canvas.

**Active feedback (user-initiated):**
- Users can comment on a canvas from the chat: "@Zip the colors are wrong
  on the diagram" — this routes through normal attention routing.
- Future: canvas-level reactions or annotations that push context items.

**Agent self-verification:**
- Agent creates canvas → `canvas.snapshot` → gets screenshot → analyzes it
- Agent evals JS: `canvas.eval "document.querySelectorAll('.error').length"`
- If something looks wrong, agent pushes an update and re-checks
- This snapshot-verify-correct loop is unique to the node protocol — tool
  calls can't do interactive verification.

### Context Synchronization

The NodeClient and RuntimeChannel share agent identity but operate on
different connections. Context must stay synchronized:

```
RuntimeChannel                    NodeClient
  │                                  │
  │ attention signal (space_id) ──►  │ (updates current_space)
  │                                  │
  │ ◄── canvas created ─────────────│ (posts canvas message via Chat)
  │                                  │
  │ sticky engagement ──────────►   │ (canvas commands go to same space)
  │                                  │
  │ engagement expires ─────────►   │ (clears current_space)
```

Both connections run in the same BEAM node, so synchronization is a
simple GenServer message or shared ETS lookup — no network round-trip.

---

## What This Replaces

### Suite-specific tools that become unnecessary

| Old (plugin tool) | New (node canvas command) |
|---|---|
| `suite_canvas_create` | `canvas.present` |
| `suite_canvas_update` | `canvas.navigate` / `canvas.eval` |
| future canvas tools | Already handled by node protocol |

The `suite_canvas_create` tool in the OpenClaw plugin can be removed once
the node connection is stable. Agents use the standard `canvas` tool
targeting the Suite node instead.

### What stays on RuntimeChannel

- Agent replies (chat messages)
- Typing indicators
- Attention signals (message routing)
- `reply_with_media` (file attachments in chat)
- Tool calls for non-canvas Suite operations (task creation, etc.)

Chat is inherently a channel concern. Canvas is inherently a node concern.
Clean separation.

---

## Benefits Over Current Approach

1. **Battle-tested protocol**: The node canvas protocol is used by macOS,
   iOS, and Android apps. It's well-tested and well-documented.

2. **Rich command surface**: Present, navigate, eval, snapshot, A2UI —
   all available without writing new tool definitions.

3. **No tool args serialization bugs**: Node commands use a different code
   path (node.invoke) than plugin-registered tools. The args serialization
   issue doesn't apply.

4. **Agent-agnostic**: Any agent connected to the Gateway can target the
   Suite node — not just the one connected via RuntimeChannel.

5. **Incremental canvas updates**: Agents can eval JS, push A2UI updates,
   and snapshot results — interactive canvas workflows that tool calls
   can't support.

6. **Snapshot for verification**: Agents can take a screenshot of the canvas
   to verify their rendering looks correct — closing the feedback loop.

---

## Implementation Phases

### Phase 1: Node Client + Connection
- `Platform.Federation.NodeClient` (WebSockex-based)
- Connect to Gateway as a node with device metadata
- Handle device pairing flow
- Reconnect with exponential backoff
- Supervised under `Platform.Application`

### Phase 2: Canvas Command Handler
- `Platform.Federation.NodeCommandHandler`
- `canvas.present` → create/update canvas + PubSub broadcast
- `canvas.navigate` → update canvas URL/content
- `canvas.hide` → hide/remove canvas
- `canvas.a2ui_push` / `canvas.a2ui_reset` → A2UI rendering

### Phase 3: Interactive Commands
- `canvas.eval` → execute JS in client via phx-hook, return result
- `canvas.snapshot` → client-side screenshot, base64 return
- Round-trip through LiveView for client-side operations

### Phase 4: Plugin Cleanup
- Remove `suite_canvas_create` from the OpenClaw plugin
- Update docs: agents use `canvas` tool with `node=suite-*`
- Keep `suite_send_media` and other chat-specific tools

---

## Consequences

### Positive

- Canvas operations use a proven, documented protocol
- No more custom tool definitions for canvas — it's all node commands
- Agents get richer canvas interaction (eval, snapshot, A2UI)
- Clean separation: chat = RuntimeChannel, canvas = node
- Future node capabilities (exec, device commands) come for free

### Negative / Trade-offs

- Two WebSocket connections from Suite to Gateway (manageable)
- Device pairing adds a one-time setup step
- Canvas state must be synchronized between the node protocol and
  LiveView — adds complexity
- `canvas.eval` requires a round-trip through LiveView to the client
  and back, adding latency for JS evaluation

### Risks

- Node protocol may assume single-user rendering (one device, one screen).
  Suite has multiple users viewing the same canvas. The broadcast fan-out
  must handle this correctly.
- Gateway node routing may need to be aware that Suite is both a node
  and a runtime — ensure commands route to the right connection.
- If the node connection drops, canvas commands fail. The RuntimeChannel
  (chat) should continue working independently.

---

## References

- OpenClaw node docs: `/opt/homebrew/lib/node_modules/openclaw/docs/nodes/index.md`
- OpenClaw canvas docs: `/opt/homebrew/lib/node_modules/openclaw/docs/platforms/mac/canvas.md`
- ADR 0012: Agent-Driven Live Canvas Architecture
- ADR 0014: Agent Federation and External Runtimes
- `Platform.Chat.Canvas` — existing canvas schema
- `PlatformWeb.Chat.CanvasRenderer` — existing canvas rendering component
- `startup-suite-channel/src/suite-client.ts` — existing WebSocket client
