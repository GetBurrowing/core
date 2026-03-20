# ADR 0017: Attention Router Silence Hardening

**Status:** Accepted  
**Date:** 2026-03-20  
**Related:** ADR 0013 (Attention Routing and Channel Policy), ADR 0014 (Agent Federation)  
**Deciders:** Rowan Ellis  

## Context

After deploying the attention routing system (ADR 0013) and federated agents (ADR 0014), the following issues surfaced in production use of Suite chat:

1. **Accidental silencing.** The NLP silence detection patterns included common words like `stop`, `leave`, `enough`, `quiet`, and `silence`. Normal conversation ("stop what you're doing", "I have enough context", "leave those files alone") triggered silence without the user realizing it.

2. **Permanent NLP silence.** When silence was triggered by NLP detection, `silence_agent/3` was called with `until: nil`, meaning the agent was silenced indefinitely — only an explicit @mention could unsilence it. Users experienced the agent "going dead" with no explanation.

3. **Stale UI silence state.** When an @mention unsilenced an agent (inside `decide_agent/3`), only the database was updated — no PubSub event was broadcast. The chat UI, which listens for `{:agent_silenced, _}` to update the silence indicator, had no corresponding `{:agent_unsilenced, _}` handler. The indicator remained stuck on "silenced" until the page was refreshed.

4. **Silence button inoperable for federated agents.** The `toggle_agent_silence` event handler relied on `agent_presence.agent.id` from `WorkspaceBootstrap.status()`, which is only populated for built-in/workspace agents. For federated agents (`runtime_type: "external"`), `agent_presence.agent` was nil, causing the handler to fall through to a no-op. The button appeared clickable but did nothing.

Combined, these bugs created a scenario where:
- A user talks to a federated agent in Suite chat
- Normal conversation accidentally triggers silence (e.g. "stop and help me with X")
- The agent goes silent with no timeout
- The silence button in the UI doesn't work for federated agents
- @mentioning might unsilence the DB but the UI still shows "silenced"
- The user resorts to repeated @mentions wondering why the agent won't respond

## Decision

### 1. Tighten silence patterns

Removed ambiguous single-word triggers: `stop`, `leave`, `enough`, `quiet`, `silence`.

Kept unambiguous multi-word phrases: `shut up`, `back off`, `be quiet`, `hush`, `shush`, `go away`, `that's all`, `that's enough`, `you're dismissed`, `only when mentioned`, `quiet down/please/now`.

The principle: a silence trigger should be something a user would only say if they actually want the agent to be quiet. False positives are worse than false negatives — users can always click the silence button.

### 2. NLP silence gets a 30-minute timeout

NLP-triggered silence now passes `until: DateTime.add(now, 1800, :second)` instead of `nil`. This matches the UI button's 30-minute timeout and ensures the agent automatically recovers even if the user doesn't realize silence was triggered.

The `silenced?/1` check in `decide_agent` already respects `silenced_until` — when the timeout expires, the agent returns to normal routing.

### 3. Broadcast `:agent_unsilenced` on @mention recovery

When `decide_agent` detects `silenced? and is_mentioned`, it now broadcasts `{:agent_unsilenced, %{participant_id, space_id}}` after calling `unsilence_agent/2`.

`ChatLive` handles this event with `assign(socket, :agent_silenced, false)`, keeping the UI in sync without requiring a page refresh.

### 4. Silence toggle works for all agent types

The `toggle_agent_silence` event handler no longer depends on `agent_presence.agent.id`. Instead, it queries `Chat.list_participants(space_id, participant_type: "agent")` directly and operates on the first agent participant found. This works identically for built-in and federated agents.

## Consequences

### Positive

- Agent silencing requires clear intent — normal conversation no longer accidentally silences agents
- Silence always expires (30 min max for NLP, configurable for UI), eliminating "permanently dead agent" scenarios
- UI silence indicator stays in sync via PubSub in both directions (silence and unsilence)
- Federated agents have full UI parity with built-in agents for silence management

### Negative

- Fewer NLP silence triggers means users who want to silence via natural language need more explicit phrasing
- The 30-minute timeout is a fixed constant — could be made configurable per-space or per-user in the future

### Future considerations

- Add a silence state indicator in the chat header that shows "silenced until HH:MM" so users understand the state
- Consider a "silence confirmation" UX — when NLP detects silence intent, show a toast asking "Silence agent?" rather than doing it automatically
- Expose silence timeout as a space-level setting
