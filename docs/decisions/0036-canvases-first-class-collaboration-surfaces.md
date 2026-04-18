# ADR 0036: Canvases as First-Class Collaboration Surfaces

**Status:** Proposed
**Date:** 2026-04-18
**Deciders:** Rowan
**Related:** ADR 0008 (Chat Backend Architecture), ADR 0012 (Agent-Driven Live Canvas Architecture — superseded by this ADR), ADR 0020 (Chat Rich Content Rendering), ADR 0030 (Meetings — LiveKit Voice/Video), ADR 0033 (Org-Level Context Management), ADR 0035 (ChatLive Modularization)

---

## Context

Canvases were introduced in ADR 0008 as chat-attached live artifacts and elaborated in ADR 0012 as the long-term surface for agent-driven collaborative UIs. ADR 0012 was Proposed but only partially implemented: the canonical document model (`CanvasDocument`) and patch API (`CanvasPatch`) were coded, but they coexist with the ad-hoc per-type implementation they were meant to replace, and neither the renderer nor the event loop have been cut over. The present implementation is a half-finished transition.

### What exists today

Canvases are space-scoped rows in `chat_canvases` with a nullable `message_id` that implies they are message-subordinate. There are three parallel worlds:

1. **Legacy type-switched canvases.** `canvas_type` is one of `table | form | code | diagram | dashboard | custom`, each with its own ad-hoc `state` shape. Mutations flow through per-type LiveView handlers (`canvas_save_form`, `canvas_save_code`, `canvas_save_diagram`, `canvas_refresh_dashboard`). Rendering is a hardcoded case analysis in `PlatformWeb.Chat.CanvasComponents`.
2. **Canonical document canvases.** `CanvasDocument` stores a validated node tree with revisions; `CanvasPatch` defines a structured mutation API. `PlatformWeb.Chat.CanvasRenderer` renders the tree recursively. Neither is wired to any UI handler; the patch API has no human or agent caller.
3. **Specialized rendering paths.** `CanvasRenderer` additionally dispatches over URL canvases (iframe rendering) and A2UI-formatted canvases (JSONL parsing), each with its own code path and no relationship to the canonical document.

### Concrete failure modes

These failures come up repeatedly in real use:

- **Agents produce malformed initial state on create.** The `state` map has no published contract, so agents guess at the shape. The shape is different per `canvas_type` and inconsistently validated. Canvases frequently arrive DOA.
- **Patches miss their target.** When agents do emit patches, the target `node_id` is often stale or wrong — either because the agent never saw current state, or because state changed between the agent's read and its write. Errors when they happen are unstructured and agents cannot self-correct.
- **Contract is opaque.** There is no single source of truth for "what kinds exist, what props they accept, what children are allowed." Node-kind knowledge lives implicitly in the renderer's case analysis and the validator's internal checks. Agents have nowhere to read the contract.

### Use cases the current model does not support

Two near-term product scenarios expose the message-subordinate model as fundamentally wrong:

1. **Workshop / mind-map surface.** Multiple humans in a voice meeting classify speech-transcribed chunks into a live mind-map ("problem areas", "solutions identified"). An agent listens and attaches chunks to category nodes. The canvas is the *view*, not an inline attachment to some message. There may not be a chat at all.
2. **POC UI prototyping.** A small group collaborates with an agent to build a visual mockup of a client-facing UI. The canvas is the design surface; conversation happens over voice or adjacent chat, but the canvas is the artifact.

Both use cases require canvases to be first-class space-scoped objects, not chat-message attachments. The existing task system precedent reinforces this: plans and review evidence are canvas-shaped surfaces that exist independently of any chat message.

### Design principle

The current implementation was built ad-hoc across several passes and is now structurally incoherent. We treat it as a prototype. This ADR establishes the intended shape and we migrate or cleave rather than carry legacy paths forward. There is no compat layer; old data either converts cleanly to the new model or is dropped during migration.

## Decision

Canvases become **first-class, space-scoped collaboration surfaces** with a unified document model, a single write surface, a published contract, and a real-time concurrency model that leans on Elixir/LiveView-native primitives.

Seven commitments:

1. **Canvas is a first-class space-scoped object.** It exists at the space level; chat messages may reference it as embeds. It has its own lifecycle, PubSub topic, and presence footprint.
2. **One document model.** The canonical node-tree document replaces all ad-hoc state shapes, URL canvases, and A2UI-formatted canvases. A2UI input is translated on ingress and has no parallel rendering path.
3. **One write surface.** All mutations flow through the patch API. Humans, agents, and task-system code share the same entry point; there is no type-specific mutation handler.
4. **Per-canvas GenServer with rebase-or-reject concurrency.** A registered process serializes writes for its canvas, rebases compatible patches, and rejects conflicts with structured, machine-actionable feedback.
5. **Node kinds are declared modules.** Each kind owns its schema, renderer, default props, event emissions, and presence metadata shape. The registry of kinds is the single source of truth from which agent tool schemas, patch validation, and renderer dispatch are all derived.
6. **Three agent tools.** `canvas.create`, `canvas.patch`, `canvas.describe`. Tool JSON Schemas are compiled from the kind registry at boot. Structured rejection lets agents self-correct on the next turn.
7. **Clone-only cross-space operation.** A canvas can be cloned into another space; it cannot be moved. Messages in the source stay valid; the clone is a new artifact.

## Detailed design

### 1. Space-first-class schema

`chat_canvases` is re-shaped:

- `space_id` — required FK. Not nullable.
- `message_id` — **removed.** Messages reference canvases, not the reverse.
- `created_by` — required FK to the creating principal (user or agent).
- `document` — the canonical document (node tree with revision). Replaces the ad-hoc `state` map.
- `deleted_at` — soft deletion. Canvases are archival objects; deletion is rare and reversible.
- `cloned_from` — nullable FK to a source canvas id, for provenance.

`chat_messages` gains:

- `canvas_id` — nullable FK. A message embeds zero or one canvas. A canvas can be referenced by many messages.

Legacy columns (`canvas_type`, `component_module`, free-form `state`) are dropped. `CanvasComponents` is deleted. Per-type event handlers (`canvas_save_form`, `canvas_save_code`, `canvas_save_diagram`, `canvas_refresh_dashboard`) are deleted. The A2UI JSONL parsing path is deleted. See **Migration**.

### 2. Node kind registry

The canonical document is a tree of nodes. Each node has:

- A stable `id` (canvas-local UUID, assigned at creation, never rewritten)
- A `kind` (enum value drawn from the registry)
- A typed `props` map (schema defined by the kind)
- Ordered `children` (when the kind permits them)

Each kind is **one Elixir module** under `Platform.Chat.Canvas.Kinds.*` that declares:

| Declaration | Purpose |
|---|---|
| `schema/0` | Required/optional structural props and their types |
| `styling/0` | Styling props (variant, tone, density, etc.) and allowed values |
| `children/0` | `:none`, `:any`, or a whitelist of allowed child kinds |
| `defaults/0` | Default props for a freshly inserted node of this kind |
| `events/0` | Structured events this kind can emit (form submit, button click, checklist toggle) |
| `presence_shape/0` | Kind-specific presence metadata (cursor position, selection rect) |
| `render/1` | Phoenix function component rendering this node given its props and children |

The initial kind set (target ~14):

**Structural:** `stack`, `row`, `card`
**Content:** `text`, `markdown`, `heading`, `badge`, `image`, `code`, `mermaid`
**Interactive (behavioral):** `form`, `action_row`, `checklist`, `checklist_item`, `table`
**Specialized (future additions covered by the same pattern):** `mindmap` (SVG/canvas graph surface with positioned nodes and edges), `ui_preview` (sandboxed iframe for agent-generated UI code; source must be deployment-local or explicitly whitelisted, never arbitrary remote URLs), `iframe` (general-purpose sandboxed embed with the same scope restrictions)

There are **no templates.** Agents generating a canvas emit the canonical document they want; any domain-specific seed shapes (task plans, review evidence) are private constructors in their own contexts that return canonical documents.

### 3. Styling as a first-class concern

Unstyled, prebuilt compositional nodes fail quickly in practice. Styling is declared alongside structural props from day one.

- **Per-kind styling surface.** Each kind declares its styling props (typed: `variant :: :default | :elevated | :outlined`, `tone :: :neutral | :info | :warning | :critical`, `density :: :compact | :comfortable | :spacious`). Styling props are patched and validated identically to structural props.
- **Kind-agnostic style namespace.** A shared vocabulary (spacing, emphasis, accent) that any kind can opt into — so "make this section feel urgent" works consistently across kinds.
- **Canvas-level theme.** Each canvas carries a theme: a map of design tokens (colors, typography scales, radii) that kinds resolve against at render time. Themes are patchable; agents and humans can both update them.
- **Class overrides escape hatch.** Every node accepts an optional `class_overrides` prop — freeform Tailwind class list applied after variant resolution. Gated by a per-space capability flag so casual canvases do not become CSS playgrounds, but the affordance exists where the use case demands it.

Adding a new variant to a kind is a kind-module edit plus (optionally) a theme-token addition. Agents see new options the next time tool schemas are compiled. No renderer-wide changes required.

### 4. Per-canvas GenServer and concurrency

A per-canvas GenServer (registered as `{:canvas, canvas_id}`) is the single writer for its canvas. All mutations go through it; Postgres is an async write-through sink, not the source of truth during an active session.

Every patch carries a `base_revision` — the revision the client last saw. On receipt the GenServer:

- **Applies** the patch if `base_revision == current_revision`, or if the patch targets a subtree unaffected by changes since.
- **Rebases** the patch if it can be applied safely against current state — props changes on a still-existing node, inserts into a still-existing parent, toggles on a still-existing checklist item.
- **Rejects** with a structured reason if rebase is not safe: target node deleted, schema violation, revision too stale to rebase confidently, illegal-child rule violated.

Rejection returns a machine-actionable payload including the reason enum, the offending operation index, the offending node id (where applicable), the expected schema for the violated kind, the current revision, and optionally the current tree (only when the caller is stale enough that re-reading is cheaper than rebase guidance).

For text editing specifically, clients debounce to field-level `set_props` patches on blur or idle rather than emitting one patch per keystroke. This avoids OT complexity entirely; the two-humans-typing-in-the-same-text-box case is not a first-order requirement and can be addressed later inside the `text` kind if it becomes one.

The canonical document's `revision` field is the monotonic write clock. The `version` field (already in the schema) is reserved for document-format version bumps — distinct concern, incremented only when the document grammar changes.

### 5. Agent-facing contract

Three tools:

- **`canvas.create(space_id, document)`** — creates a canvas with an initial canonical document. Schema-validated at tool-call time against the discriminated union over kinds.
- **`canvas.patch(canvas_id, base_revision, operations)`** — applies patches. Returns `{:ok, new_revision}` or a structured rejection.
- **`canvas.describe(canvas_id)`** — returns current document, revision, presence (who is viewing/editing, with focus nodes), and recent events. Idempotent, cheap, encouraged.

Tool JSON Schemas are **compiled from the kind registry at boot** and published through the agent tool registry. The `document` parameter of `canvas.create` is a recursive discriminated union over every node kind, with kind-specific prop schemas and children constraints. The `operations` parameter of `canvas.patch` is similarly typed per operation and per target-kind. Agents see the full contract at every call; malformed documents and patches fail at the tool-schema layer rather than at runtime.

Agent runtime integration:

- When an agent engages with a canvas, the runtime **subscribes it to the canvas's PubSub topic automatically** and surfaces state into the agent's context.
- Applied patches, node events (form submissions, toggles, clicks), and presence changes flow into the agent's next-turn observations. The agent is always reasoning against recent state.
- Subscription lifecycle is runtime-managed; the agent does not subscribe or unsubscribe explicitly.

This design eliminates the three standing failure modes:

- **Malformed initial state** is unrepresentable at the tool-schema layer.
- **Malformed patches** are unrepresentable at the tool-schema layer.
- **Stale targets** are handled by rebase-or-reject plus subscription-driven state freshness, with structured rejection when the agent is still stale.

### 6. Events and the collaboration loop

Node kinds emit structured events separately from patches. A `form` emits `{:submitted, values}`; a `checklist_item` emits `{:toggled, checked}`; an `action_row` button emits `{:action, id, payload}`. Events broadcast on the canvas's PubSub topic.

Events are signals, not mutations. A submitted form does not by itself mutate the document; it emits an event. Subscribers (agents, LiveView hooks, task-system integrations) observe events and decide how to respond — patch the canvas, create a task, reply in chat, or ignore. This keeps the document meaningful (a submitted form retains its values) and the event stream actionable.

### 7. Presence

Canvas presence is a **facet of space presence**, not a parallel channel. The existing `PlatformWeb.Presence` instance on `chat:space:<id>` carries an optional metadata bag keyed under `canvas`:

```elixir
%{
  canvas_id: "...",
  engagement: :viewing | :editing,
  focus_node_id: "...",      # only when :editing
  kind_state: %{...}          # kind-specific: mindmap cursor, selection, etc.
}
```

**Presence is opt-in by intentional interaction, not derived from viewport visibility.** A user registers canvas presence when they:

- Open the canvas in a detail panel, expanded view, or modal
- Enter a canvas-centric space view (the meeting/design-room case — the space itself renders the canvas as its primary surface, and entering the space registers the canvas engagement)
- Focus an editable node (clicking into a text field, dragging a mindmap node)

Passive scroll-past in a chat flow **does not** register presence. The embedded canvas still renders and subscribes to PubSub for live updates; it just does not contribute to the "who's here" signal. This keeps presence meaningful — "someone is on this canvas" implies deliberate engagement.

Agents participate in presence identically, with activity metadata (`drafting_node`, `analyzing`, `waiting`) so humans can see which agent is doing what.

The `focus_node_id` surfaces a soft-lock affordance: the UI shows a subtle indicator on a node another user is editing. Not a hard lock — no blocking — just an affordance so collaborators self-coordinate.

### 8. Message embedding

Messages reference canvases via a `canvas_id` column on `chat_messages`. One canvas per message; many messages may reference the same canvas. This is a column, not a join table; join-table scaffolding can be added later if multi-canvas messages become a real requirement.

Lifecycle:

- **Message deleted** → canvas untouched. Messages are references, not parents.
- **Canvas deleted (soft)** → messages referencing it render a "this canvas was removed" placeholder. The reference stays; the canvas row stays (soft-deleted via `deleted_at`); restoration is possible.

The API surface:

- `create_canvas(space_id, document)` — standalone canvas creation.
- `create_canvas_with_message(space_id, document, message_body)` — atomic create-and-announce in one transaction. Common agent flow.
- `send_message(space_id, body, canvas_id: existing_canvas_id)` — send a message referencing an existing canvas.

### 9. Cross-space clone

A canvas can be cloned into another space. It cannot be moved. Clone produces a new canvas with:

- New canvas id
- Fresh canvas-local node ids (regenerated for the cloned document)
- Document structure copied verbatim
- Revision history reset (clone starts at revision 1)
- `created_by` = the cloning actor
- `cloned_from` = source canvas id (provenance)
- Space-scoped bindings cleared (anything that references resources in the source space that do not exist in the target); universal bindings preserved
- Attachments referenced by URL remain pointing at the original; if the attachment system is space-scoped, target-space viewers may see broken refs (flagged as a downstream concern on the attachment system — not resolved in this ADR)

Permissions: read on source space, write on destination space. No "yanking across spaces" concerns because the source is untouched.

To surface a cloned canvas in the destination space's chat, the actor follows up with `send_message(target_space_id, body, canvas_id: cloned_canvas_id)`. Two operations; composable. If this pattern becomes common, `clone_and_announce` can be added as sugar.

### 10. Rendering surfaces

The canonical document renders in multiple contexts:

- **Standalone space view** — the canvas is the primary view; space opens directly on it. Meeting/design-room case.
- **Chat message embed** — inline in the message bubble with an "open full" affordance.
- **Task-system surfaces** — plans, review evidence rendered as canvas documents inside the task UI.
- **Pinned/notification references** — contextual chrome from those features.

The renderer is context-agnostic. The surrounding UI provides context-specific chrome. One document, many surfaces.

## Consequences

### Positive

- **One model to learn.** Agents, developers, and humans work against a single canvas concept. No type-switching, no parallel rendering paths, no ad-hoc shapes.
- **Published contract.** Tool JSON Schemas compiled from the kind registry mean agents see the exact valid shape at every call. The three headline agent failure modes collapse into schema violations caught at the model layer.
- **Kind registry is cheap to extend.** New kinds (mindmap, ui_preview, whatever comes next) are one module. No renderer edits, no validator edits, no agent-tool retrofits.
- **Styling is available from day one.** Variants, tokens, themes, and a gated escape hatch mean we never hit the "unstylable prebuilt components" dead end.
- **Canvases move with the use cases.** First-class space-scoping supports the meeting/design-room and prototype-POC use cases natively. The chat-embedded case reduces to "a message references a canvas."
- **Concurrency is leveraged, not fought.** Per-canvas GenServer + Phoenix.Presence + PubSub give us real-time collaboration without OT or CRDTs. Rebase-or-reject covers the realistic conflict space.
- **Clone is trivial.** The first-class canvas design makes "send a copy to another space" a two-line operation, which is a good validator that canvases really are portable.

### Negative / Trade-offs

- **One-shot migration is more work than a gradual rollout.** We are choosing cleave-and-replace over compat shims. Upside: no dead code ambiguity. Downside: the migration has to be done carefully.
- **The kind-registry pattern concentrates risk.** If the registry abstraction is wrong, every kind inherits the problem. Mitigation: the pattern is small and each kind is independently implementable; course correction happens by changing the kind module contract.
- **Field-level text patches (debounced on blur/idle) trade some liveness for a simpler concurrency model.** True per-keystroke collaborative text editing is not supported. If that becomes a product requirement, we localize it to the `text` kind rather than escalate it to the whole document.
- **Attachments remain a downstream concern.** Clone and rendering-in-other-spaces both depend on attachments behaving well across spaces. This ADR does not solve that; it flags it for a follow-up.
- **ADR 0012's phased rollout is replaced by a more aggressive cutover.** Teams that were planning against 0012's phases need to rebase on this plan.

## Alternatives Considered

### Adopt A2UI as the document format

A2UI is an emerging declarative UI grammar designed for agent emission. Adopting it would provide a broader primitive catalog out of the box and agent-familiarity benefits (models have seen A2UI-shaped formats during training).

Rejected because A2UI is a *UI shape* grammar, not a *collaboration semantics* model. Events on PubSub, bindings to the context plane, revision-aware patches, space-scoping, presence integration, and the agent-runtime loop are not A2UI concerns — they would all have to be bolted on. Owning the grammar keeps those semantics native. A2UI-compatibility at the node-prop level (so A2UI-trained agents produce near-valid documents) is pursued as a soft alignment target, but A2UI is not adopted as our format. Existing A2UI canvases are translated on ingress during migration.

### Keep built-in types as templates

An earlier draft of this ADR proposed keeping `table`, `form`, `dashboard` etc. as templates — pre-populated subtrees of generic kinds rather than kinds of their own. Rejected because `table` enforces "every row has the same columns" as an invariant, `form` owns a submission lifecycle, and these cannot be represented as a stack of simpler nodes without losing behavior. They are first-class kinds, not templates. Templates as a concept were dropped entirely: the only remaining candidate (`dashboard`) reduces to "a stack of cards with bindings," which is a one-off construction, not a first-class abstraction.

### Operational transformation / CRDT for collaborative editing

Rejected as a first-order mechanism. The per-canvas GenServer gives us serialization for free, and structural patches targeting stable node ids are coarse-grained enough that rebase-or-reject handles the realistic collision space. OT/CRDT is only on the table if per-keystroke collaborative text becomes a requirement, and it can be scoped to the `text` kind rather than the whole document.

### Many-to-many message ↔ canvas join table

Rejected as premature. A message embedding multiple canvases has no current use case. `canvas_id` as a column on messages is simpler, cheaper to query, and trivial to evolve to a join table later if the requirement emerges.

### Move semantics in addition to clone

Rejected as unnecessary complexity. Move requires cleanup of message embeds in the source space, revalidation of bindings, and a permissions model around who can yank whose canvas. Clone alone covers the user-facing intent ("I want a copy over there"), preserves source integrity, and has no cleanup. If move semantics become necessary later, the clone foundation supports adding them.

## Implementation Plan

Phased delivery. Each phase lands independently and leaves the tree in a working state.

### Phase 1 — Kind registry and canonical document (foundation)

- Define `Platform.Chat.Canvas.Kind` behaviour (the kind-module contract: `schema/0`, `styling/0`, `children/0`, `defaults/0`, `events/0`, `presence_shape/0`, `render/1`).
- Implement the initial ~14 kinds under `Platform.Chat.Canvas.Kinds.*`.
- Replace `Platform.Chat.CanvasDocument` with a version that reads kind definitions from the registry. Drop any logic that contradicts the registry.
- Replace `Platform.Chat.CanvasPatch` with a version that validates against the kind registry and returns structured errors.
- Delete `PlatformWeb.Chat.CanvasComponents`. `CanvasRenderer` becomes a thin dispatcher that calls `Kind.render/1` per node.

### Phase 2 — Schema migration

- Migration: add `canvas_id` to `chat_messages`, `deleted_at` and `cloned_from` to `chat_canvases`, make `chat_canvases.space_id` non-null.
- Data migration: convert existing canvases to canonical documents. Each legacy `canvas_type` gets a one-off converter (6 converters: `table`, `form`, `code`, `diagram`, `dashboard`, `custom`). URL canvases convert to single-node documents with an `iframe` kind. A2UI canvases translate to canonical via an ingress translator written once and then discarded. Any canvas that cannot be converted is dropped (this is an explicit choice, not an accident — we are treating prior data as prototype).
- Backfill `chat_messages.canvas_id` from the inverse of the old `chat_canvases.message_id`.
- Drop `chat_canvases.message_id`, `canvas_type`, `component_module`, and the ad-hoc `state` column.

### Phase 3 — Per-canvas GenServer and write surface

- Implement `Platform.Chat.Canvas.Server` as a per-canvas GenServer registered by id.
- All patch application routes through the server. `Platform.Chat.patch_canvas/2` becomes a thin call into the server.
- Delete per-type LiveView handlers (`canvas_save_form`, `canvas_save_code`, `canvas_save_diagram`, `canvas_refresh_dashboard`). UI interactions emit patches through the server like any other caller.
- Implement rebase-or-reject logic with structured rejection payloads.

### Phase 4 — Agent contract

- Compile tool JSON Schemas from the kind registry at boot. Register `canvas.create`, `canvas.patch`, `canvas.describe` as agent tools.
- Wire agent-runtime subscription: when an agent engages with a canvas, it auto-subscribes to the canvas PubSub topic and surfaces state/patches/events into context.
- Structured rejection payload shape is finalized and documented in the kind registry's public surface.

### Phase 5 — Presence, styling themes, events

- Extend `PlatformWeb.Presence` metadata to carry the canvas engagement bag. Two engagement levels (`:viewing`, `:editing`), opt-in by interaction.
- Implement canvas theme application at render time (tokens → Tailwind classes via the kind's variant resolution). Gate `class_overrides` behind a per-space capability flag.
- Wire kind event emissions to the canvas PubSub topic (`form` submissions, `checklist_item` toggles, `action_row` actions).

### Phase 6 — Cross-space clone and chat integration

- Implement `Chat.clone_canvas/3`.
- Finalize `Chat.create_canvas/2`, `Chat.create_canvas_with_message/3`, `Chat.send_message/3` with explicit `canvas_id` param support.

### Phase 7 — Specialized kinds (deferred per product need)

- `mindmap` kind: SVG/canvas-based graph surface with positioned nodes and edges, drag-to-reclassify, zoom/pan. Supports the workshop use case.
- `ui_preview` kind: sandboxed iframe for agent-generated UI code, deployment-local only, with hot-reload via patches. Supports the POC UI use case.
- Additional kinds are added on demand following the same module-per-kind pattern.

## Migration

No backward-compat shims. No dual-path rendering. No compat aliases. The old system was an ad-hoc prototype and we are replacing it wholesale. Explicit cleanup to be performed during Phases 1–3:

- Delete `PlatformWeb.Chat.CanvasComponents`.
- Delete per-type event handlers (`canvas_save_form`, `canvas_save_code`, `canvas_save_diagram`, `canvas_refresh_dashboard`).
- Delete the A2UI JSONL rendering path (after ingress translator converts existing A2UI canvases).
- Delete `default_state/1` per-type generators in `CanvasHooks`.
- Delete the `canvas_type`, `component_module`, and legacy `state` columns.
- Delete any helper functions keyed on `canvas_type` across the codebase.
- Delete `PlatformWeb.Chat.CanvasRenderer`'s URL and A2UI dispatch branches.
- Remove ADR 0012 from Proposed; mark superseded by this ADR.

Data that cannot be cleanly converted is dropped. This is a conscious choice: carrying dead shapes forward for the sake of a small amount of historical data undermines the design's coherence and reintroduces the agent-confusion failure modes we are trying to kill.

## Non-Goals

The following are intentionally out of scope for this ADR, to be addressed separately if and when the product demands them:

- **Per-keystroke collaborative text editing (OT/CRDT).** Current model is debounced field-level patches. Localized to the `text` kind if it becomes necessary.
- **Collaborative cursors for text selection.** Mindmap-style cursor positions are supported via kind presence metadata; text-selection cursors are not.
- **Attachment portability across spaces.** Clone and cross-space embed rely on the attachment system behaving correctly; this ADR does not resolve that. Downstream work on the attachment system.
- **Cross-space move semantics.** Clone only. Move can be added later if clone proves insufficient.
- **User-defined node kinds.** The kind registry pattern permits this architecturally, but it is not exposed as a first-class feature. Only code-declared kinds are supported.
- **Canvas import/export between deployments.** In-deployment cross-space clone only.
- **Versioned document format migrations.** The `version` field is reserved for this; no format migration is planned in the initial rollout.

## Related ADRs and successor context

- **ADR 0012** is superseded by this ADR. Its phased rollout is replaced by the plan above. The canonical document model and patch API it proposed are retained; the coexistence strategy is not.
- **ADR 0035** (ChatLive modularization) extracts `CanvasHooks` as a lifecycle hook. This ADR simplifies that hook substantially — the event surface shrinks (generic patch dispatch rather than per-type handlers) and the assigns narrow. The extraction work should anticipate this ADR's implementation.
- **ADR 0030** (Meetings) and the design-room use case interact: a meeting space may open directly on a canvas as its primary view. Presence and engagement flow naturally through the space-presence metadata defined here.
- **ADR 0020** (Chat Rich Content Rendering) governs inline message content; canvas embeds in messages compose cleanly with that system — the message bubble renders rich content, and if the message references a canvas, an embed block renders the canvas below/alongside.

## Open items tracked for follow-up

- Attachment cross-space portability (downstream ADR).
- Agent-side tool bindings for the three canvas tools — the ADR commits to the shape; wiring through agent provider adapters is a follow-up.
- Mindmap and ui_preview kind implementations (Phase 7; may land as separate small ADRs if their rendering stacks require architectural justification).
