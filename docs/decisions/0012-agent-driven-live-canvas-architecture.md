# ADR 0012: Agent-Driven Live Canvas Architecture

**Status:** Proposed  
**Date:** 2026-03-17  
**Deciders:** Team

---

## Context

ADR 0008 established chat-attached live canvases as a core part of the product:
agents should be able to render interactive, collaborative artifacts inside the
chat experience. The current implementation in `Platform.Chat` provides a good
foundation, but it is still a **canvas persistence and rendering layer**, not
an **agent-manipulable canvas runtime**.

### What exists today

The current implementation already includes:

- a persisted `chat_canvases` table (`Platform.Chat.Canvas`)
- canvas creation via `Platform.Chat.create_canvas/1` and
  `create_canvas_with_message/3`
- a generic persisted `state` map per canvas
- PubSub fanout for `:canvas_created` and `:canvas_updated`
- a chat-side right panel for opening and interacting with a canvas
- built-in canvas types rendered by `PlatformWeb.Chat.CanvasComponents`:
  - `table`
  - `form`
  - `code`
  - `diagram`
  - `dashboard`
  - `custom`

This gives the platform a working collaborative stateful sidecar attached to a
chat message.

### Current limitations

The current system is not yet suitable as the long-term surface that a native
agent can manipulate directly:

1. **Canvas state shape is ad hoc**
   - each built-in canvas type stores a different state schema
   - there is no single canonical document model for agent-generated UIs

2. **Rendering is type-switched and server-authored**
   - `CanvasComponents` uses hardcoded rendering branches by `canvas_type`
   - `custom` currently behaves more like a placeholder than a true dynamic
     component runtime

3. **Mutation surface is too narrow**
   - current updates are mostly specialized LiveView event handlers such as
     `save_canvas_form`, `save_canvas_code`, `save_canvas_diagram`, etc.
   - there is no general patch API an agent can call to manipulate the canvas

4. **No first-class event/action loop for agents**
   - users can interact with built-in forms and controls
   - but there is no normalized action/event channel for an agent to observe and
     react to canvas interactions

5. **No explicit agent tool contract**
   - agents do not yet have a safe, structured API for creating, patching,
     reading, and responding to canvas state

The platform needs an architecture that evolves the current system instead of
throwing it away.

---

## Decision

We will evolve the current chat canvas system into an **agent-driven live canvas
runtime** by introducing a canonical document model, a deterministic patch API,
and an agent-facing tool layer while preserving the current storage and chat
integration.

### Decision summary

1. **Keep the current chat-canvas persistence and message attachment model**
2. **Introduce a canonical canvas document schema stored in `state`**
3. **Add a deterministic patch API for document mutation**
4. **Replace type-specific rendering as the long-term center of gravity with a
   node renderer over the canonical document model**
5. **Introduce a normalized canvas event/action loop**
6. **Expose a narrow agent-facing canvas tool contract**
7. **Treat existing built-in canvas types as document templates / seeds over
   time, not as the final architecture**

---

## Decision Details

### 1. Preserve the current foundation

The following current pieces remain valid and should be preserved:

- `Platform.Chat.Canvas`
- `Platform.Chat.create_canvas/1`
- `Platform.Chat.create_canvas_with_message/3`
- `Platform.Chat.get_canvas/1`
- `Platform.Chat.update_canvas/2`
- `Platform.Chat.update_canvas_state/2`
- `Platform.Chat.PubSub` canvas topics
- the `content_type: "canvas"` chat message model
- the right-side Chat canvas panel in `ChatLive`

This means a canvas remains:
- persisted in Postgres
- linked to a chat message
- collaborative through PubSub
- reopenable later by users and agents

### 2. Canonical document model

The `state` field on a canvas becomes the storage location for a **canonical
canvas document**, rather than being an arbitrary per-type bag of keys.

Example shape:

```elixir
%{
  "version" => 1,
  "kind" => "ui",
  "revision" => 1,
  "root" => %{
    "id" => "root",
    "type" => "stack",
    "props" => %{"gap" => 12},
    "children" => [
      %{
        "id" => "title",
        "type" => "text",
        "props" => %{"value" => "Hello"}
      }
    ]
  },
  "bindings" => %{},
  "meta" => %{}
}
```

Required characteristics:

- stable node IDs
- explicit node `type`
- `props` as serializable maps
- nested `children`
- monotonically increasing `revision`
- versioned document schema for future migrations

### 3. Patch-based mutation model

Canvas updates should move from ad hoc per-canvas handlers to a deterministic
patch contract.

Example operations:

- `{:set_props, node_id, props}`
- `{:replace_children, node_id, children}`
- `{:append_children, node_id, children}`
- `{:insert_after, node_id, sibling_id, node}`
- `{:delete_node, node_id}`
- `{:replace_document, document}`

This becomes the long-term write surface for both:
- humans acting through LiveView handlers
- agents acting through tools

Patches must be:
- structured
- deterministic
- validated before application
- revision-aware to avoid silent stomp/write races

### 4. Renderer over document nodes

A new renderer should become the canonical rendering path:

- `PlatformWeb.Chat.CanvasRenderer`

It should render a document node tree instead of switching only on
`canvas_type`.

Initial node types should be small and practical:

- `stack`
- `row`
- `card`
- `text`
- `markdown`
- `button`
- `table`
- `form`
- `input`
- `textarea`
- `badge`

Over time, the current built-in canvas types become seeded templates that create
an initial document using those nodes.

Examples:
- a table canvas seeds a document containing a `table` node
- a form canvas seeds a document containing `input` nodes and a submit action
- a dashboard canvas seeds a document containing cards + metric nodes

### 5. Canvas event/action loop

Canvas interactivity should emit normalized events that can be observed by the
app and by agents.

Examples:

```elixir
%{
  "canvas_id" => "...",
  "node_id" => "submit_btn",
  "event" => "click",
  "payload" => %{}
}
```

or

```elixir
%{
  "canvas_id" => "...",
  "node_id" => "customer_form",
  "event" => "submit",
  "payload" => %{"name" => "Alice"}
}
```

This event layer is the bridge between:
- LiveView component interaction
- agent reasoning
- subsequent patch writes back into the canvas

### 6. Agent-facing tool contract

Agents should not manipulate canvases through raw DB writes or arbitrary code.

Instead, expose a structured tool API such as:

- `canvas_create(title, seed_spec)`
- `canvas_get(canvas_id)`
- `canvas_list(space_id)`
- `canvas_patch(canvas_id, ops, revision)`
- `canvas_focus(canvas_id)`
- `canvas_read_events(canvas_id, since)`

The tool contract must be:
- explicit
- JSON-serializable
- revision-aware
- constrained to safe document operations

This keeps the agent’s authority narrow and inspectable.

### 7. Seed templates, not bespoke canvas types

The platform should keep practical built-in seeds for common workflows:

- task board
- form
- decision matrix
- review board
- dashboard
- scratchpad

But these should be implemented as **seeded documents**, not as permanently
special bespoke rendering branches.

---

## Consequences

### Positive

- preserves the current working chat canvas system rather than replacing it
- gives agents a safe, structured way to create and manipulate live surfaces
- enables collaboration between users and agents on the same persisted UI
- unifies human and agent interactions around one document + event model
- supports progressive enhancement: current built-in canvases can migrate over
  time into seeded document templates
- keeps the architecture Phoenix/LiveView-native and deterministic

### Negative / Trade-offs

- introduces a new document and patch validation layer
- adds migration complexity from current ad hoc state maps
- requires a new renderer and node catalog rather than relying on existing
  `canvas_type` branches forever
- revision handling introduces additional implementation complexity
- some current LiveView event handlers will eventually need to be rewritten to
  emit general patch operations

---

## Alternatives Considered

### 1. Keep the current built-in canvas-type architecture indefinitely

Rejected.

This is fine for hand-authored features but not sufficient as the foundation
for agent-driven live canvas manipulation.

### 2. Let agents manipulate canvases through arbitrary LiveView events or raw
DB writes

Rejected.

This would be opaque, unsafe, hard to validate, and hard to reason about.

### 3. Introduce a completely separate browser-side canvas runtime unrelated to
current chat canvases

Rejected for now.

That would discard working persistence, PubSub, and message-linking primitives
that already exist and are aligned with the chat-first product shape.

---

## Initial Implementation Plan

### Phase 1 — Canonical document + patch API

- add `Platform.Chat.CanvasDocument`
- add `Platform.Chat.CanvasPatch`
- add validation for node structure and patch operations
- add revision handling in canvas writes
- keep current built-in canvas UI working while introducing the new contract

### Phase 2 — Renderer + seeded templates

- add `PlatformWeb.Chat.CanvasRenderer`
- support initial node catalog (`stack`, `row`, `card`, `text`, `button`,
  `table`, `form`, `markdown`)
- represent built-in canvases as seeded documents where practical

### Phase 3 — Event/action loop

- add normalized canvas UI events
- define how button clicks, form submits, and similar events are emitted and
  subscribed to
- connect those events to agent-side reasoning and follow-up patch writes

### Phase 4 — Agent tools

- expose canvas creation/patch/read/event tools to the native agent runtime
- limit the tool contract to structured document operations
- avoid arbitrary code execution or uncontrolled component mounting

---

## Non-Goals

This ADR does not define:

- arbitrary server-side execution inside a canvas
- an unrestricted custom component mounting system
- external browser automation as the primary canvas mechanism
- a full scene-graph/editor product in the first phase

The goal is a pragmatic, deterministic live canvas runtime that grows directly
out of the system Core already has.

---

## Follow-Up Work

1. Create `CanvasDocument` and `CanvasPatch` modules
2. Define the initial node schema and validation rules
3. Add revision-aware patch application to `Platform.Chat`
4. Introduce `CanvasRenderer`
5. Migrate one existing canvas type (likely `form` or `table`) to the new
   document path as the first template
6. Define the first agent-facing canvas tool contract
7. Add canvas interaction events and event subscriptions
