# ADR 0034: MCP Endpoint and Capability Bundles

**Status:** Proposed
**Date:** 2026-04-14
**Deciders:** Rowan
**Related:** ADR 0007 (Agent Runtime), ADR 0013 (Attention Routing), ADR 0014 (Agent Federation)

---

## Context

Today, federated agents discover and invoke Suite's 53-tool surface indirectly:

- The `startup-suite-channel` OpenClaw plugin hardcodes 39 of the 53 tools as
  `agentTools` and proxies calls back to core over the runtime WebSocket.
- A separate `startup-suite-mcp` TS proxy (github.com/Startup-Suite/mcp-server)
  exposes 18 tools over stdio MCP, also proxying over the runtime WebSocket.

This has three costs:

1. **Duplicate tool definitions.** Every new tool requires edits in core, the
   plugin, and the TS proxy. Users must upgrade both sides to benefit.
2. **Unscoped surface.** Every federated runtime sees every tool regardless of
   role. A small listener model burns context on task/plan tools it will never
   call.
3. **No lazy loading.** The plugin path cannot defer schema delivery; all
   surfaces ship at handshake.

## Decision

Core will expose a **first-class Streamable HTTP MCP endpoint** at `/mcp`, authed
by the existing federation token, with tools scoped by **capability bundles**.

### Architecture

- **Transport:** MCP Streamable HTTP (single endpoint, JSON-RPC + SSE for
  streaming). Falls back to HTTP+SSE transport if client support lags.
- **Auth:** `Authorization: Bearer <token>` verified against
  `AgentRuntime.auth_token_hash`. No new credential surface; the token a peer
  already has for federation is the MCP token.
- **Tunnel topology:** One MCP endpoint per Suite instance. The bearer token
  identifies the runtime; peers expose a single Cloudflare-tunneled
  `/mcp` URL regardless of how many agents federate.
- **Dispatch:** Handler delegates to the existing `Platform.Agents.ToolSurface`
  module. No new business logic.
- **Retirement:** `startup-suite-mcp` (TS proxy) is archived once the native
  endpoint is live. `startup-suite-channel` plugin keeps attention routing,
  session spawn, presence, and usage reporting — but drops all `suite_*` tool
  handlers.

### Capability bundles

Tools are tagged by bundle. Bundles match the nine natural domains already
present in `Platform.Federation.ToolSurface` as private functions:

| Bundle         | Source function       | Typical tools                                          |
| -------------- | --------------------- | ------------------------------------------------------ |
| `federation`   | `federation_tools`    | federation_status                                      |
| `space`        | `space_tools`         | space_list                                             |
| `context_read` | `context_read_tools`  | space_get_context, space_get_messages, space_search    |
| `messaging`    | `messaging_tools`     | send_media                                             |
| `review`       | `review_tools`        | review_request_create                                  |
| `canvas`       | `canvas_tools`        | canvas_create/update/list/get, artifact ops            |
| `task`         | `task_tools`          | task/project/epic CRUD, task_start/complete            |
| `plan`         | `plan_tools`          | plan/stage/validation, prompt_templates, blockers      |
| `org_context`  | `org_context_tools`   | org_context_read/write/list, org_memory_*              |

**Default `allowed_bundles` for new runtimes:**
`["federation", "space", "context_read", "messaging"]` — a listener baseline
that sees spaces and chat without writing tasks, plans, canvases, or org
context.

**Backfill for existing runtimes:** all nine bundles enabled (permissive) to
avoid breaking currently federated agents. Operators opt *out* to shrink.

Two axes gate visibility at runtime:

- **Operator-set allowlist** on `AgentRuntime.allowed_bundles` — policy.
- **Client-requested subset** at session init — ergonomics.

The server returns the intersection. Unknown/disallowed bundles are dropped
silently, with a warning in the server log.

### Tool-discovery mechanism

**Standard `tools/list` with bundle trimming** is the default. A single call at
session start returns the full scoped surface; zero discovery latency; works
with every MCP client. This solves the stated goal of small models not seeing
task tools.

**On-demand `suite_tool_search`** (ToolSearch-style meta-tool) is out of scope
for v1. It is additive and can ship as a future opt-in bundle for agents that
subscribe to the full surface but want to keep context minimal.

## Consequences

**Positive:**
- New tools ship by deploying core alone.
- Context cost scales with an agent's role, not the full surface.
- Single auth story (federation token everywhere).
- One tunnel per Suite instance, no per-agent exposure.

**Negative:**
- `startup-suite-channel` plugin v0.3.x users must upgrade to stay in sync;
  old plugin keeps working but tool calls are deprecated.
- MCP Streamable HTTP transport is newer; if a client lags, we fall back to
  HTTP+SSE dual-endpoint (slightly more configuration).

**Neutral:**
- Session lifecycle is stateless per request for v1. RuntimePresence continues
  to reflect WebSocket state, not MCP connections. Revisit if MCP gains
  subscriptions.

## Phases

1. **Schema + tool surface bundles** (core) — migration drops the unused
   `capabilities` column and adds `allowed_bundles :: {:array, :string}` to
   `agent_runtimes` with the listener default. Existing rows backfill
   permissively (all bundles). `Platform.Federation.ToolSurface` tags each
   tool with `:bundle` and exposes `list_tools/1` filtered by bundle list;
   `tool_definitions/0` continues to return the full surface by delegating to
   `list_tools(all_bundles())`.
2. **MCP transport** (core) — `Platform.Auth.BearerPlug`, `MCPController` under
   `/mcp` handling `initialize`, `tools/list`, `tools/call`. Integration tests
   against a fixture runtime.
3. **Client wiring & docs** — README instructions for
   `claude mcp add suite --transport http ...`. OpenClaw native MCP config.
4. **Retire TS proxy** — archive `startup-suite-mcp` with redirect README.
5. **Simplify channel plugin** — remove `agentTools`, bump version, migration
   notes. Keep SuiteClient, attention routing, session spawn, presence, usage.

## Open questions

- Exact bundle membership may shift as we review the 53-tool surface in detail
  during Phase 1.
- Whether to gate any bundles on `trust_level` as well as explicit allowlist.
- Streamable HTTP vs HTTP+SSE final choice pending Claude Code client check.
