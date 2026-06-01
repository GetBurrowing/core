# 03 — Voice

**Phase 2 deliverable.** Copy guidance, button verbs, error messages, and Suite's agent-native empty-state pattern. Anchored to the naming drifts resolved by Marlowe (2026-05-08) + the empty-state direction Marlowe pinned during Phase 2 drafting (2026-05-09).

---

## 1. Voice descriptors

Suite's voice is **direct, specific, agent-aware, and warm-but-not-cute**. Three operating descriptors:

| Descriptor                        | What it means                                                                                       | Anti-pattern                                                |
|----------------------------------|-----------------------------------------------------------------------------------------------------|-------------------------------------------------------------|
| **Direct**                        | One verb per call-to-action. Fewer adverbs and qualifiers.                                           | "Click here to potentially set up your first agent if you'd like." |
| **Specific**                      | Use the actor + the action by name. Don't hide behind passive voice.                                  | "An action will be performed."                                |
| **Agent-aware**                   | When an agent is the subject of an action, name the agent role; when the human is, address them directly. | "Your task will be processed by an automated system."         |

What Suite **avoids**: superlatives ("amazing!"), emoji-stuffing in copy, breezy banter that hides functionality, jargon without on-the-spot definition.

---

## 2. Canonical-term map (resolves 1A-IA-DRIFT-1 to DRIFT-4)

The terms below are the source-of-truth for every user-facing string. Copy that diverges from this table is a bug; Phase 4 IMPLEMENTATION.md sequences the rename.

### 2.1 Resolved: chat-entity primitive (`1A-IA-DRIFT-1`)

| Surface area              | Canonical noun (use this)         | Aliases (do NOT use in user-facing copy)                       |
|--------------------------|-----------------------------------|-----------------------------------------------------------------|
| The container for a chat conversation | **`space`**                       | ~~conversation~~, ~~room~~, ~~thread (no — thread = sub-conversation inside a space)~~ |
| Section labels on sidebar  | "Channels" + "Direct messages"   | (Sidebar **labels** stay as kinds-of-space; the underlying noun is `space`.) |
| Verbs                      | "Open a space", "Create a space", "Leave the space" | ~~"Open a conversation"~~, ~~"Join a room"~~                  |

**Recap:** "Channels" and "DMs" remain as section labels in the sidebar (kinds-of-space). The underlying noun in body copy + button labels + error messages is `space`. Slack-vocabulary users get a beat to translate; mitigation = the sidebar label "Channels" preserves familiar shape.

### 2.2 Resolved: humans + agents in spaces (`1A-IA-DRIFT-2`)

| Concept                                              | Canonical term       | Aliases (avoid)                                |
|------------------------------------------------------|----------------------|------------------------------------------------|
| Anyone who can read/post in a space (human or agent) | **`participant`**     | ~~member~~, ~~user~~, ~~attendee~~              |
| Specifically a human participant                     | "person" or "you"    | ~~user~~ (only OK in admin/internal contexts)   |
| Specifically an agent participant                    | "agent" / agent name | ~~bot~~, ~~assistant~~                          |

UI copy: "12 participants" (mixed). "3 people, 9 agents" (when the split matters). Settings UI / admin contexts may still say `user` since those surfaces map to the data model's `User` entity.

### 2.3 Resolved: task lifecycle (`1A-IA-DRIFT-3`)

| Lifecycle entity                                  | Canonical term     | Aliases (avoid)                                  |
|---------------------------------------------------|--------------------|-------------------------------------------------|
| The unit of work                                   | **`task`**         | ~~ticket~~, ~~item~~, ~~card~~                  |
| The agent's proposed approach to executing it       | **`plan`**         | (kept; specific to its role)                    |
| The human-gated approval of the plan or its output  | **`review`**       | (kept; specific to its role)                    |

UI copy frames `plan` and `review` as **states-of-task** rather than peer entities:
- "This task is in planning."
- "This task is awaiting review."
- "Open the task's plan." (not "Open the plan.")
- "Review this task." (not "Review the review.")

### 2.4 Resolved: agent / principal / workspace / runtime (`1A-IA-DRIFT-4`)

| User-facing context           | Canonical term  | Aliases (avoid in user copy)                                   |
|-------------------------------|-----------------|----------------------------------------------------------------|
| The autonomous actor           | **`agent`**     | ~~principal~~, ~~workspace~~, ~~runtime~~, ~~bot~~              |
| Agent's connection state        | "online" / "offline" / "active in `space-name`" | ~~"runtime up"~~, ~~"workspace healthy"~~                       |
| Agent's role in your space     | use the role name (e.g. "engineer", "PM")  | ~~"principal"~~                                                  |

`principal`, `workspace`, and `runtime` survive in **internal / admin / debug** surfaces (they map to architecture concepts that aren't user-relevant). Settings panels for engineers may keep them. End-user-facing copy uses `agent`.

---

## 3. Button verb conventions

Action verbs follow a consistent shape across surfaces.

| Action category                | Verb                           | Examples                                   |
|--------------------------------|--------------------------------|--------------------------------------------|
| Create a new entity             | "Create a `<noun>`"             | "Create a space", "Create a task"           |
| Connect/add an existing entity  | "Add `<noun>`" or "Connect `<noun>`" | "Add an agent", "Connect your agent"     |
| Send / submit                    | "Send" (for messages), "Save" (for edits) | "Send", "Save", "Save changes"        |
| Confirm a destructive action     | The destructive verb itself, never the polite "OK" | "Delete task", "Leave space", "Remove agent" |
| Cancel / dismiss                  | "Cancel" / "Close"               | "Cancel" (in modals with action), "Close" (in informational dialogs) |
| Steer / redirect an in-flight task | "Steer", "Pause", "Stop", "Resume" | "Pause this task"                         |
| Approve / reject a review         | "Approve" / "Request changes"   | "Approve plan", "Request changes"          |

**Avoid:** "Submit", "OK", "Yes" / "No" buttons. Verbs name the action; affirmation buttons hide it.

---

## 4. Error messages

Format: **what failed → why (one phrase) → next action (if any)**.

| Bad                               | Good                                                                                          |
|-----------------------------------|-----------------------------------------------------------------------------------------------|
| "Error 500."                      | "Couldn't save the task — the connection dropped. Retry?"                                       |
| "Invalid input."                  | "The task title can't be blank. Add a title and try again."                                       |
| "Unauthorized."                   | "Only the task author can edit this task. Ask `<author-name>` to make changes, or post a comment." |
| "Permission denied."              | "Agents can't edit their own messages — post a follow-up message instead."                      |

When the error involves an agent action: name the agent. "`<agent>` couldn't post in `<space>` — agent disconnected. Reconnecting..." beats "An agent action failed."

When the error is a transient network condition that the user will recover from: tell them what happens next. "Retrying..." or "Reconnecting..." or "Waiting for `<agent>` to come back online."

---

## 5. Empty state pattern (anchored to `1B-USE-3` + Marlowe's 2026-05-09 direction)

Every empty state has **three components**: what's empty, why it's empty in context, one **agent-mediated action** the user can take. Suite is agent-native — the empty state is precisely where an agent could fill the gap, and copy should reflect that.

### 5.1 Brand-new user (no spaces yet)

```
You don't have any spaces yet.

Connect your agent and add them to a space, or
[Create a space]   [Connect an agent]
```

The two CTAs cover the two paths a new user takes: bring an agent in to an existing thing, or set up a thing for the agent to live in.

### 5.2 Brand-new space / channel (Marlowe's pin: in a brand-new created channel)

```
This space is quiet.

Connect your agent and @ them to plan and work in this space.
[Add an agent]
```

The CTA "Add an agent" is the single primary action. After that's done, the user mentions the agent and the space comes alive. The phrase "@ them" in the body teaches the syntax inline.

### 5.3 Tasks (Marlowe's pin: the task surface)

```
No tasks here yet.

Create a task and assign to an agent to plan and execute.
[Create a task]
```

Single CTA. The body sentence sets the workflow expectation: the agent does the planning + execution; the human creates the task and reviews.

### 5.4 Activity feed (no agent actions in range) — **stays minimal** (Marlowe 2026-05-09)

```
When your agents start working, what they do appears here. Try a wider date range, or connect an agent to start.
```

No CTA buttons, no chips. The time-range filter pills already visible at the top of the Activity surface ARE the "wider date range" path referenced in the copy — no separate button needed. The "connect an agent" path is upstream (handled in chat/sidebar empty state); on this surface, the prose mention is sufficient.

This deviates from the V3-conversational pattern used on the other empty states (chat sidebar, chat space, tasks). Activity is a read-only audit feed; over-styling its empty state with a Saru bubble + chips would push the user to "do something" when the user might just be a passive viewer waiting for events. Kept minimal on Marlowe's pin.

### 5.5 Search (no results)

```
No messages match "<query>".

Try a shorter query, or [Clear search]
```

Search empty states stay simple — no agent CTA. Adding one would be noise on a typing-driven flow.

---

## 6. Microcopy patterns

### 6.1 Loading

- **Generic:** "Loading…" (last resort).
- **Specific:** "Loading messages…", "Saving task…", "Connecting `<agent>`…", "Sending…".
- **Agent in flight:** "`<agent>` is working on it…" (when the agent is actively executing). Stronger trust signal than "Processing…".

### 6.2 Confirmation

After a successful action, brief acknowledgment in the same surface (toast or inline):

| Action                | Confirmation copy                              |
|-----------------------|------------------------------------------------|
| Saved task             | "Task saved."                                  |
| Sent message           | (None — the message appearing in the stream IS the confirmation.) |
| Created space          | "Space created. Invite participants to start." |
| Connected an agent     | "`<agent>` connected. @ them to start a task."  |
| Approved a plan        | "Plan approved. `<agent>` is starting work."    |

### 6.3 Destructive confirmation

Two-step: a button labelled with the destructive verb, then a modal that names the consequence.

> **Delete task**
>
> "Delete this task? Its plan and review history go with it. Comments and chat references stay where they are."
>
> [Cancel]   [Delete task]

The cancel button comes first (left-aligned on desktop, top on mobile-stacked) so accidental confirms are harder.

### 6.4 Agent-correction message rendering (anchored to editable-messages contract Section d)

When an agent posts a correction message (`corrects_message_id` set), the bubble renders with a top affix:

> ↑ Correction to earlier message

Click/tap scrolls to and highlights the original. Tense is matter-of-fact; agents don't apologize unless the underlying action did harm worth apologizing for.

---

## 7. What this voice doc does NOT cover

- **Marketing site / landing-page copy** — separate concern, not refined here.
- **Email + push-notification copy** — Phase 4 follow-up; the patterns in this doc are starting templates for them.
- **Copy localization / i18n** — out of scope. Suite ships English-only as of this audit; future i18n work consumes this doc as the source-of-truth for English then maps to localized voice docs per locale.
- **Internal admin / debug surfaces** — Settings panels mapped to architecture concepts (`principal`, `workspace`, `runtime`) keep their domain terms. This doc covers user-facing copy.

---

## 8. Cross-references

- Empty-state component spec: `02-components.md` §2.13.
- Button verb pattern is enforced via Button component (`02-components.md` §2.1).
- Error rendering pattern is enforced via Input error slot (`02-components.md` §2.3) and Toast variants (`02-components.md` §2.9).
- Entity relationships visualized: [`_entity-relationships.md`](./_entity-relationships.md).
- Agent-correction bubble UI: anchored to editable-messages contract (`audit/2026-05-08-ui-ux/01-inventory.md` references it).
