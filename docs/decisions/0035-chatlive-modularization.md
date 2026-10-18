# ADR 0035: ChatLive Modularization

**Status:** Accepted (2026-08-17 — see "Status resolution and corrections")
**Date:** 2026-04-15
**Deciders:** the product owner
**Related:** ADR 0016 (Control Center LiveView Modularization), ADR 0020 (Chat Rich Content Rendering), ADR 0022 (DM Unread Badge), ADR 0030 (Meetings — LiveKit Voice/Video)

---

## Context

`PlatformWeb.ChatLive` has grown to **5,090 lines** — the largest hand-written source file in the repo, roughly 3× the next-largest LiveView (`TasksLive` at 1,578) and ~60% larger than `ControlCenterLive` was when it was modularized under ADR 0016.

An audit of the module identifies **13 distinct feature concerns** coexisting in one file:

| Concern | Assigns | Events | handle_info | Render region |
|---|---|---|---|---|
| MessageList | 5 (stream + maps) | 1 | 6 | L2534–3200 |
| SpaceNavigation | 10 | 9 | 0 | L1819–2000 |
| Threads | 6 | 4 | 3 | L2268–2890 |
| Meeting | 11 | 10 | 2 | L2050–3670 (multi-region) |
| Canvases | 4 | 9 | 3 | L2524–3578 (multi-region) |
| Uploads | 4 | 6 | 0 | L3273–3531 |
| Pins | 3 | 3 | 2 | L3695–3870 |
| AgentPicker | 2 | 3 | 0 | L2147–2247 |
| Settings | 2 | 5 | 0 | L3773–4068 |
| Search | 3 | 3 | 0 | L2278–2500 |
| Mentions | 3 | 3 | 1 | L3223–3271 |
| Presence | 8 | 0 | 4 | scattered |
| Drafts | 3 | 2 | 0 | inline |
| ActiveAgent | 2 | 2 | 1 | L1145–1160 |

> **Corrections, 2026-08-17 (task 01a008f6 stage 7).** Every line number in
> the table above refers to a file shape that no longer exists — `chat_live.ex`
> is 4,335 lines today and its template is a separate 3,890-line file, so the
> cited `L…` ranges cannot be resolved against anything. Read the table as a
> concern inventory, not as coordinates. Corrections to specific claims are
> collected under "Status resolution and corrections" at the end of this
> document.

Several concrete symptoms already follow from the scale:

- **Dual, shadowed `handle_event/3` clauses** for `join_meeting` (L608 and L974) and `leave_meeting` (L638 and L1008) — two meeting UI paths (`@in_meeting` vs `@meeting_active`) were merged without reconciliation. The commit message on `5976968` explicitly flags this as "dead code from a prior merge — cleanup is a separate follow-up."
- **`handle_params` sets `meeting_active` twice**: once from active-room state (L325), then unconditionally to `false` (L335). The second assignment is residue from a merge. The bug is invisible unless a reader reads both lines.
- **Open reconnect loop in meeting join**: the investigation ticket references unresolved interactions between `push_event("join-meeting", ...)` in `handle_event` and LiveView rejoin behavior. It is unclear whether the bug is in meeting code specifically or in how meeting concerns thread through the rest of the LiveView.

These are not bugs that appeared overnight; they are the symptom profile of an overloaded module. Every additional feature that lands in `chat_live.ex` makes the next bug harder to diagnose.

ADR 0016 modularized `ControlCenterLive` (3,219 → 719-line shell + 11 focused modules) and explicitly deferred `ChatLive`: "same patterns apply but was deliberately excluded from this effort to limit scope and risk." This ADR picks that work up.

## Decision

Apply the ADR 0016 decomposition approach to `ChatLive`, with two extensions reflecting ChatLive's greater interactivity:

1. Introduce **LiveComponent** as a first-class shape (alongside function component / handler module / data module) for self-contained interactive panels with their own state.
2. Introduce **LifecycleHook modules** (using `attach_hook/4`) for cross-cutting LV concerns that touch many assigns but have no panel — following the pattern already in use by `PlatformWeb.ShellLive`.

### The three-shape rule

Every feature concern lives in **exactly one** of these three shapes:

| Shape | When to use | Location |
|---|---|---|
| **LiveComponent** | Self-contained interactive UI panel — all of its UI fits within one contiguous render region that the parent can hand off (canvas editor, thread panel, upload dialog, settings modal, agent picker, search overlay, mentions dropdown) | `lib/platform_web/live/chat/<feature>_component.ex` |
| **LifecycleHook module** | Cross-cutting LV concern: either has no panel (presence, drafts, active-agent indicator), **or** has distributed UI whose elements are interleaved into other features' render regions (pins — topbar + panel + inline per-message button; meeting — topbar + panel + mini-bar in ShellLive). Owns assigns/events/handle_info/handle_params; the render stays in the parent template (or moves to function components) and reads the hook's assigns. | `lib/platform_web/live/chat/<feature>_hooks.ex` — exposes `attach(socket)` that wires `attach_hook/4` for `handle_event`, `handle_info`, `handle_params` |
| **Context module** | Pure business logic, queries, data shaping — no socket, no LV | `lib/platform/chat/*` or `lib/platform/<domain>/*` |

Function components (`Phoenix.Component`) are fine for pure-render helpers inside a LiveComponent's own template — they are not a feature shape.

### Event namespacing

Every event originating from a feature is prefixed with the feature's domain name, separated by `_`:

```
thread_open, thread_close, thread_send_message
pin_toggle, pin_panel_toggle
canvas_create, canvas_open, canvas_save
meeting_join, meeting_leave, meeting_toggle_mic
upload_show_dialog, upload_send, upload_cancel
```

LifecycleHook modules pattern-match only on their prefix. A hook that sees an event outside its prefix returns `{:cont, socket}` unchanged.

**Migration note:** existing unprefixed events (`toggle_pin`, `join_meeting`, etc.) are renamed during extraction. Templates and tests update together. No backward-compat aliases — clean cutover per feature.

### No cross-feature assigns

A feature module may only write to assigns it owns. If Feature A needs something from Feature B:

- **Read-only access:** pass as an attr to the LiveComponent from the parent's render.
- **Notify:** broadcast via PubSub (`Phoenix.PubSub.broadcast(Platform.PubSub, "chat:<topic>", msg)`). The interested feature subscribes in its hook.
- **Command:** call `send_update(OtherComponent, id: ..., assigns)` from the parent.

Features do **not** reach into each other's assigns via the shared socket. The parent LiveView mediates; or PubSub does.

### `chat_live.ex` shell budget

The main LiveView retains only:

- `mount/3` — initial assigns, PubSub subscriptions for things the shell owns (spaces list, unread counts), call `attach/1` on each LifecycleHook module.
- `handle_params/3` — URL → active space resolution, calls into `Chat` context for initial load, emits feature-hook events via `send/2` or PubSub so features can react.
- `render/1` — composes components; minimal inline markup.
- Delegation clauses for feature events where extraction to a LiveComponent is not yet complete.

**Target: `chat_live.ex` ≤ 500 lines.** (Baseline today: 5,090. ADR 0016 hit 719 on ControlCenter starting from 3,219.)

### What does **not** go in the shell

- `handle_event` clauses for specific features (move to LiveComponents or, during migration, to handler modules with one-line delegation as in ADR 0016).
- `handle_info` clauses for feature PubSub topics (move to LifecycleHooks via `attach_hook/4`).
- Feature-specific HEEx blocks longer than ~20 lines (move into a LiveComponent's template).
- Helper functions used by only one feature.

## Migration Strategy

### Sequence

1. **Land this ADR** as `Proposed`.
2. **Extract Pins** as the reference LifecycleHook (smallest self-contained concern: 3 assigns, 3 events, 2 handle_info, no cross-deps — but distributed UI, so not a LiveComponent). Move to `Accepted` after Pins ships and the convention has survived code review.
3. **Extract Search, Settings, Mentions, AgentPicker** — each a straightforward LiveComponent. Parallelizable.
4. **Extract Uploads, Canvases** — larger but self-contained. Uploads owns the `allow_upload` plumbing; that moves to the LiveComponent.
5. **Extract Drafts, Presence, ActiveAgent** as LifecycleHook modules. These are cross-cutting and are best done after several LiveComponents exist to clarify the read/write boundaries.
6. **Extract Meeting** after the current reconnect-loop bug is fixed (extracting while debugging a live bug invites compounding risk). This extraction also resolves the `@in_meeting`/`@meeting_active` duality as a forced side effect.
7. **Extract Threads, MessageList** last — these are the most entangled with each other. By the time they come up, the surrounding features are out of the way and the boundary between "list of messages" and "threaded reply panel" is clearer.

### Per-feature checklist

Each extraction PR must:

1. Move all assigns owned by the feature into the new module.
2. Rename events to the feature namespace (`pin_toggle` not `toggle_pin`).
3. Move PubSub subscriptions into the new module.
4. Move render regions into the new module's template.
5. Add or update tests — every extracted feature has at least one `Phoenix.LiveViewTest` assertion exercising its primary user flow.
6. Run `mix compile --warnings-as-errors` and `mix test apps/platform --only chat` clean.
7. Verify `chat_live.ex` line count has dropped by a plausible amount (extractions that grow the shell are a smell).

### Tests as the safety net

ADR 0016 succeeded because it expanded coverage before refactoring (14 baseline tests → 35 after coverage pass). `chat_live_test.exs` today is 882 lines of LiveViewTest-style integration tests; we treat that as the **baseline**, not the ceiling. Before each extraction, verify the feature has at least one passing test that would catch a regression in its primary flow. If it does not, add one first.

## Consequences

### Positive

- **Blast radius:** Changing pins touches `pins_component.ex`. The shell, threads, canvases, meeting — untouched.
- **Navigability:** "Where does meeting join work?" → `meeting_component.ex` + `meeting_hooks.ex`. Not "grep for 'join' across 5k lines."
- **Reviewability:** Feature PRs show focused diffs. Cross-feature PRs are visible as such (they touch the shell).
- **Testability:** LiveComponents can be tested in isolation via `Phoenix.LiveViewTest.render_component/2`.
- **Forcing function for bugs:** extracting Meeting will force resolution of the dual-UI residue and almost certainly surface (or fix) the reconnect loop.
- **Namespace discipline prevents future sprawl:** the prefix rule makes it mechanical to see which feature owns an event.

### Negative

- **Indirection:** Event flow becomes non-local. The namespace rule keeps it tractable, but "click → which module handles this?" now requires one hop.
- **LiveComponent boilerplate:** `use Phoenix.LiveComponent`, `update/2` splits, `send_update/2` calls. ~30–50 lines of overhead per component.
- **Migration churn:** 13 features, landing one at a time, will keep ChatLive in a mixed state for weeks. The ADR-0016 precedent (11 modules, one surface) suggests this is survivable.
- **PubSub sprawl risk:** features talking via PubSub rather than direct assigns can create invisible coupling. Mitigation: namespaced topics (`chat:pins:*`, `chat:meeting:*`) and a central registry of chat-internal topics.

### Not addressed

- **Template splitting:** we keep HEEx inline in each LiveComponent (ADR 0016's position — and we reaffirm it).
- **LiveView → LiveView split:** we do not split ChatLive into multiple LiveViews. Thread panel and meeting panel stay as components of the one chat surface.
- **Frontend JS hook organization:** `apps/platform/assets/js/hooks/` has its own organizational debt (meeting_client.js, meeting_bar.js, meeting_room.js all related). Out of scope here; follow-up ADR if warranted.

## Alternatives Considered

1. **Leave it alone** — the file is navigable with grep, and every extraction has a cost. Rejected: the dual meeting handlers and the reconnect loop are the kind of bugs that grow in files this size. The cost of another year of this is higher than the cost of splitting.
2. **Function components only (ADR 0016 approach literally)** — works for pure render, insufficient for stateful widgets. The thread panel, canvas editor, upload dialog, meeting panel have their own local state; LiveComponent is the correct abstraction for them.
3. **One mega-LiveComponent per feature region** — would reduce file count but not navigability within each mega-component. Rejected.
4. **Handler modules (ADR 0016 pattern) for events, no LiveComponents** — keeps all state on the parent socket, which is exactly the problem we are trying to solve. Rejected.
5. **Split ChatLive into multiple LiveViews** (e.g., `ChatLive` + `ThreadLive`) — too invasive; loses the shared socket state that makes the chat UX feel coherent (a thread opens next to its parent message). Rejected.
6. **Component library in an umbrella app** — premature; start by splitting within one app, then promote if reuse emerges.

---

## Status resolution and corrections (2026-08-17)

Recorded by task 01a008f6 stage 7, which applied this ADR's conventions to
`TasksLive` and had to read this document as a specification. Six things in it
were no longer true.

**1. Status.** This ADR's own migration sequence says "move to `Accepted`
after Pins ships and the convention has survived code review." Pins shipped
2026-04-15 (`PlatformWeb.ChatLive.PinHooks`), and the LifecycleHook /
LiveComponent convention it established has since been applied across
`chat/` (14 modules) and the whole of `tasks/` (16 modules). The status is
**Accepted**, and was in fact accepted by practice for four months while the
document still said Proposed.

**2. "Not addressed: template splitting" is contradicted by the tree.**
Commit `af5cb8f6` externalized the shell template — `chat_live.html.heex`,
3,890 lines. The position stated here ("we keep HEEx inline in each
LiveComponent, and we reaffirm ADR 0016") still holds for COMPONENTS, whose
templates are inline. It does not hold for the SHELL, whose template is a
separate file on both this surface and Tasks. The ADR should be read as: the
shell's template is external; a component's is inline.

**3. The shadowed `join_meeting` / `leave_meeting` clauses are FIXED.** This
ADR lists them as a live symptom, and step 6 of the migration predicted the
Meeting extraction would resolve "the `@in_meeting`/`@meeting_active` duality
as a forced side effect." It did: `chat_live.ex` contains zero
`join_meeting` or `leave_meeting` clauses today — they live in
`chat/meeting_hooks.ex`, singly. The prediction held; the symptom list
outlived it.

**4. Three concerns in the table were never extracted.** `SpaceNavigation`
(10 assigns, 9 events — the LARGEST assign count in the inventory), `Drafts`
and `AgentPicker` have no module under `chat/`. They are still in the shell.
That is most of the reason `chat_live.ex` is 4,335 lines after eleven
extractions.

**5. The "3× the next-largest LiveView" claim is now INVERTED, and then
inverted back.** At the time of writing, ChatLive was 5,090 and TasksLive
1,578. By 2026-08-16 TasksLive had reached 6,027 `.ex` + 4,906 `.heex` —
larger than ChatLive on both halves. As of this stage TasksLive is 641 + 398
and ChatLive is 4,335 + 3,890, so ChatLive is the largest surface again by a
factor of eight. The point is not the ranking but that the ranking moved
twice in sixteen months with nothing tracking it.

**6. Measuring the module and not its template understates the surface.**
This ADR's per-feature checklist says "verify `chat_live.ex` line count has
dropped by a plausible amount." That check is satisfiable by moving markup
from the module into the shell TEMPLATE, which is exactly what a shell of
4,335 + 3,890 = 8,225 lines looks like. ADR 0050 replaces it with a
sum-of-both budget under machine check. Applying that rule here would put the
ChatLive surface at 8,225 lines — a number this document has never stated.
