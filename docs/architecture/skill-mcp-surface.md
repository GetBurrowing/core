# Skill MCP Surface and Per-Plugin Access Path

**Status:** Audit (current state, 2026-05-06)
**Related:** [ADR 0034 — MCP Endpoint and Capability Bundles](../decisions/0034-mcp-endpoint-and-capability-bundles.md), [Federation Overview](./federation-overview.md)
**Tracking task:** Suite task `019dfaea-df5e-79ed-a5f8-838961435302` — *Verify Claude-channel and OpenClaw federated agents have parity access to DB-shipped skills*. This file is the stage-1 (docs-only) deliverable; stage 2 backfills the bundle, stage 3 cleans up the OpenClaw legacy surface.

---

## TL;DR

Suite ships three centrally-distributed skill tools (`skill_list`, `skill_get`, `skill_upsert`) over its `/mcp` endpoint. **No federated runtime can call them today**, regardless of which plugin it uses, because the `skill` capability bundle is missing from every existing `AgentRuntime.allowed_bundles` row and from the per-runtime default. The chokepoint is on the Suite side — neither the Claude-channel plugin nor the OpenClaw plugin needs a code change for the *built-in* path to start working once the bundle is granted. (The OpenClaw legacy `agentTools` path is a separate, additive cleanup.)

---

## 1. Canonical surface

The skill tools are defined and dispatched in
[`apps/platform/lib/platform/federation/tool_surface.ex`](../../apps/platform/lib/platform/federation/tool_surface.ex):

- `@bundles` (line 20) lists `skill` as one of eleven known bundles.
- `tools_for_bundle("skill")` (line 54) routes to `skill_tools/0`.
- `skill_tools/0` (lines 140–209) defines:
  - `skill_list` — query-filtered summaries, no body.
  - `skill_get` — full markdown by `slug` or `id`.
  - `skill_upsert` — create-or-replace by name; slug is derived.
- `execute("skill_list" | "skill_get" | "skill_upsert", …)` (lines 1574–1581) delegates to `Platform.Skills.ToolHandlers`.

These tool names use underscores (`skill_list`), like every other tool. They used the dotted form (skill.list) until task 01a14a7f; that name is still accepted as a hidden alias but is not listed. MCP clients see the listed names verbatim through `tools/list`.

This module is the **single source of truth** for the federated tool surface — both transports below dispatch through it.

---

## 2. Bundle gating

`AgentRuntime` ([`apps/platform/lib/platform/agents/agent_runtime.ex`](../../apps/platform/lib/platform/agents/agent_runtime.ex)) carries the per-runtime allowlist:

- `@valid_bundles`: `~w(federation space context_read messaging review canvas task plan memory skill attachment files)` — every bundle a runtime row is *permitted* to hold. This must equal `ToolSurface.all_bundles/0` as a set, and a test in `apps/platform/test/platform/agents/agent_runtime_test.exs` enforces that. **The test is the authority, not this paragraph** — prose restating a list drifts silently, and this one had (it named the retired `org_context`, and omitted `memory` and `files`).
- `@default_allowed_bundles`: `~w(federation space context_read messaging attachment skill)` — what a *newly registered* runtime actually gets. Deliberately narrower than `@valid_bundles`: `review` and `files` are grantable but not granted, because `file_add` / `file_delete` mutate and the review tools act on gates. Being in the valid list is permission to be granted, not a grant.
- The `allowed_bundles` field (line 29) defaults to `@default_allowed_bundles`.
- Changesets validate values are a subset of `@valid_bundles` (line 59).

So a freshly-created runtime has zero access to the skill bundle out of the box, and there is no migration that retroactively granted it to existing rows.

---

## 3. Transport asymmetry (known sibling concern)

There are **two** transports through which a federated runtime can invoke tools, and they enforce `allowed_bundles` differently. This audit is for context only — fixing the asymmetry is **not in scope** for this task.

### HTTP (`/mcp`) — strictly enforced

[`PlatformWeb.MCPController`](../../apps/platform/lib/platform_web/controllers/mcp_controller.ex):

- `dispatch("tools/list", …)` (line 68) returns only the tools whose bundle is in `runtime.allowed_bundles`.
- `dispatch("tools/call", …)` (line 77) calls `authorize_tool/2` (line 104) which re-derives the scoped list and refuses (`-32001 "tool '...' not in allowed bundles"`) if the requested name isn't present.

### WebSocket (`/runtime/ws`) — bundle check skipped

[`PlatformWeb.RuntimeChannel.handle_in("tool_call", …)`](../../apps/platform/lib/platform_web/channels/runtime_channel.ex) (line 209) builds a context and calls `ToolSurface.execute(tool, args, context)` directly. There is no `authorize_tool` step, no `allowed_bundles` lookup. Whatever is implemented in `ToolSurface` is callable.

### Implication

A federated agent's effective permission to call `skill.*` (or any other tool) depends on which transport its plugin uses, independent of the formal bundle grant. Today this means:

- Plugins that proxy via the runtime WebSocket can already call `skill.*` (the channel never gates).
- Plugins that connect to `/mcp` directly are gated and currently locked out.

This is worth tightening in a follow-up — either by adding bundle enforcement to the channel handler or by formally classifying the WebSocket as a privileged transport — but the audit task ends with surfacing it.

---

## 4. Per-plugin access paths

### Claude-channel — [`Startup-Suite/claude-code-suite-channel`](https://github.com/Startup-Suite/claude-code-suite-channel)

A narrow chat-only Claude Code channels plugin. Surfaces four tools to the Claude session: `suite_reply`, `suite_reply_with_media`, `suite_reply_chunk`, `suite_typing`. **It does not proxy any Suite tool surface.** The README (lines 11–21) is explicit: full Suite tool access requires registering Suite's `/mcp` as a separate MCP server:

```bash
claude mcp add startup-suite --transport http https://<your-suite>/mcp \
  --header "Authorization: Bearer <runtime_token>"
```

So Claude reaches `skill.*` strictly via the **HTTP `/mcp`** transport — and is therefore subject to the bundle gate.

### OpenClaw — [`Startup-Suite/openclaw-suite-channel`](https://github.com/Startup-Suite/openclaw-suite-channel) (locally cloned as `~/sources/startup-suite-channel`)

Two operating modes, controlled by per-account `useMcpTools` config (`src/plugin-state.ts`, `src/channel.ts` line 81):

- **`useMcpTools: true`** — `agentTools` returns `[]` (`channel.ts` line 86). The agent talks to Suite `/mcp` directly, same path as Claude-channel. Same bundle gate applies.
- **`useMcpTools: false` (legacy)** — `agentTools` returns ~30 hardcoded tool definitions (`channel.ts` lines 87–~609), all of which `execute` by calling `suiteToolExecute(...)` over the runtime WebSocket (which bypasses bundle gating per §3). **None of the `skill.*` tools are in this legacy list** — no `suite_skill_list`, no `suite_skill_get`, no `suite_skill_upsert`. Operators on the legacy mode see no skill tools at all from this plugin.

---

## 5. Why parity is broken today

Putting §2 + §3 + §4 together:

| Plugin / mode                   | Transport to Suite | Bundle gate? | Hardcoded skill tools? | Net result            |
| ------------------------------- | ------------------ | ------------ | ---------------------- | --------------------- |
| Claude-channel                  | HTTP `/mcp`        | Yes          | n/a                    | Locked out            |
| OpenClaw, `useMcpTools: true`   | HTTP `/mcp`        | Yes          | n/a                    | Locked out            |
| OpenClaw, `useMcpTools: false`  | Runtime WebSocket  | No           | None                   | No tools to call      |

Every path is currently broken. The MCP-direct paths fail at the gate; the legacy WebSocket path has nothing to call.

The fix has two parts, tracked under the same Suite task:

- **Stage 2** — backfill `skill` into every existing runtime's `allowed_bundles` (and add it to the per-runtime default). Pattern: mirror [`20260419220000_agent_runtime_attachment_bundle.exs`](../../apps/platform/priv/repo/migrations/20260419220000_agent_runtime_attachment_bundle.exs). This unlocks both MCP-direct paths.
- **Stage 3** — register the missing `suite_skill_*` shims in OpenClaw's legacy `agentTools` so operators on `useMcpTools: false` aren't second-class.

---

## 6. End-to-end parity verification recipe

Once the stage-2 migration has been applied, two quick spot-checks confirm parity:

### Claude-channel

```bash
# In a Claude Code session that has the Suite MCP server configured:
# (the plugin install + `claude mcp add startup-suite ...` from §4)
> /mcp                       # confirm "startup-suite" connected
> Use skill_list to show me the registered skills.
```

Expected: Claude calls `skill_list` and returns a non-empty count with skill summaries. Pre-fix: `-32001 "tool 'skill.list' not in allowed bundles"`.

### OpenClaw, `useMcpTools: true`

Same expectation — the federated agent's loop should be able to call `skill_list` directly against `/mcp`. Confirm via the runtime's tool-call log, or with a short conversational prompt.

### OpenClaw, `useMcpTools: false`

Stage 2 alone won't help this mode (the WebSocket path doesn't honor bundle config and has no shim). Stage 3 adds `suite_skill_list` / `suite_skill_get` / `suite_skill_upsert` to the legacy `agentTools` block; verify by inspecting the tool list the OpenClaw runtime advertises.

---

## 7. Where to look next

- ADR 0034 — design rationale for capability bundles and the per-bundle authorization model.
- `Platform.Skills.ToolHandlers` — the implementation behind `skill_list/get/upsert`.
- Federation overview — context for how attention routing and tool calls reach a runtime.
