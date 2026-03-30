# ADR 0032 — Design Handoff: Action Cards and Agent-to-Agent DM

**Status:** Proposed  
**Date:** 2026-03-29  
**Author:** Harper Parker / Sage

---

## Context

Pixel (design agent) and Beacon (intake agent) need a structured handoff workflow when a design is ready for implementation. Currently this is text-based (Phase 1). This ADR specifies Phase 2 (approval cards) and Phase 3 (agent-to-agent DM channel).

---

## Phase 2 — Design Ready Action Card

### Problem
Pixel's handoff is a text message. Harper has to read it, reply with approval text, and Beacon has to parse that reply. There's no structured "Approve" action.

### Proposed Solution
Add a new message renderer in the chat UI for `action_card` message type. When a message contains a structured payload with `type: "action_card"`, the UI renders it with buttons.

**Wire format** (agent posts this as a message with metadata):
```json
{
  "type": "action_card",
  "title": "Design Ready for Review",
  "status": "draft",
  "body": "Chat UI — Agent Differentiation (v3)",
  "portal_url": "https://...",
  "file": "designs/startup-suite/chat-ui-v3.html",
  "actions": [
    {"label": "✓ Approve", "event": "design_approved", "payload": {"design_id": "..."}},
    {"label": "✎ Request Changes", "event": "design_changes_requested", "payload": {"design_id": "..."}}
  ]
}
```

**LiveView changes needed:**
- `chat_live.ex` — parse message content for `action_card` type, render as card component
- New `action_card_component.ex` — renders the card with buttons
- `handle_event("design_approved", ...)` — broadcasts to Beacon's runtime with approval payload
- `handle_event("design_changes_requested", ...)` — prompts Harper for notes, sends to Pixel

**Agent-side changes:**
- Pixel uses a new tool `suite_post_action_card` to post structured cards
- Beacon listens for `design_approved` attention events and begins the intake conversation

### Acceptance Criteria
- [ ] Pixel can post a design card with Approve/Request Changes buttons
- [ ] Clicking Approve notifies Beacon and confirms to Harper
- [ ] Clicking Request Changes prompts Harper for notes and sends to Pixel
- [ ] Card shows portal URL as a clickable link
- [ ] Card status updates (DRAFT → APPROVED) after approval

---

## Phase 3 — Agent-to-Agent DM Channel

### Problem
After approval, Pixel and Beacon need to have a back-and-forth conversation to clarify implementation details. This should happen out of the main channel to reduce noise. Harper should be able to observe but not be interrupted.

### Proposed Solution
When `design_approved` fires, Suite automatically creates or reuses a DM space between the Pixel runtime and Beacon runtime. Their conversation happens there. Harper is added as a silent observer (presence without notification).

**Suite changes needed:**
- `create_group_conversation/3` — extend to support agent-to-agent DMs (currently user-only)
- New space kind: `"agent_dm"` — like `dm` but between agents
- RuntimeChannel — dispatch `design_approved` event to Beacon as an attention event with space_id of the new DM
- ControlCenterLive — show agent DM spaces in the Agent Resources panel

**Agent-side changes:**
- Beacon: on `design_approved` attention event, post first message in the DM space to Pixel
- Pixel: respond to Beacon's messages in the DM space with implementation details
- Beacon: when satisfied, call `suite_task_create` with the collected spec, post task link back in original channel

### Acceptance Criteria
- [ ] Approval creates a DM space between Pixel and Beacon
- [ ] Harper can view the DM space in Suite but doesn't get notified for each message
- [ ] Beacon creates a fully-specced task when the DM conversation resolves
- [ ] Task link is posted back in the original channel
- [ ] DM space is reused for the same agent pair (not a new one per design)

---

## Implementation Order
1. Phase 2 first — the approval card is self-contained and high-value
2. Phase 3 second — depends on Phase 2's `design_approved` event

## Backlog Tasks to Create
- [ ] `[feat] Action card message type — render structured cards with buttons in chat`
- [ ] `[feat] design_approved event handler — notify Beacon on approval`
- [ ] `[feat] suite_post_action_card tool — allow agents to post structured cards`
- [ ] `[feat] Agent-to-agent DM space creation`
- [ ] `[feat] Agent DM spaces visible in Agent Resources`
