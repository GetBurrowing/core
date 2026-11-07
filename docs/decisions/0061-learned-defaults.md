# ADR 0061: Learned Defaults — Rooms Learn What You Do and Pre-fill It

- **Status:** Proposed
- **Date:** 2026-11-07
- **Owners:** Team
- **Task:** 01a1b6a1-c604-7000-8458-a462f1bf7025 (stage 1 this record, the signal store and the
  `habits.learned_defaults` experiment surface; stage 2 the `Platform.Habits` substrate; stage 3
  the attention-picker backend; stage 4 the picker and Settings UI).
- **Related:** [ADR 0048](0048-experimentation-substrate.md) and
  [ADR 0052](0052-experimentation-layer.md) (surfaces, variants as data, metric rules),
  [ADR 0060](0060-sharing-with-burrow-on-by-default-for-new-installs.md) (the sharing registry and
  its install-level switches, on task 01a1b678; not merged on 2026-11-07).

## Numbering

This record was planned as 0060. On 2026-11-07, before this file was committed, task 01a1b678
pushed `0060-sharing-with-burrow-on-by-default-for-new-installs.md` on its branch. 0059 is already
taken twice on open branches (tasks 01a199b2 and 01a1b362). 0061 was free on `main` and on every
`origin/task/*` branch when this file was committed, so this record is 0061. Cite it by filename.

## Context

The sponsor's intent (2026-11-07): rooms learn what a person does and pre-fill it, then act on
their behalf with undo, built into the bones of every install. The later steer, paraphrased: learn
as much as is useful, but only inside a person's own install; do it for ourselves too; people may
opt out, and the aggregate should still make the platform better.

Falsifier check, on `origin/main` 520d597d3 (2026-11-07):

- `PlatformWeb.Chat.MessageAttentionHooks.suggestions/3` pipes straight into
  `MentionsHooks.build_suggestions/3`. It carries no per-viewer history.
- `git grep -i -e habit -e learned -- apps/platform/lib` finds prose comments only. There is no
  store.

Both held, so this record is new rather than an amendment.

## Decision

### 1. One signal table for every surface

`habit_signals` holds every learnable choice on every surface. One row is one choice:

| column | meaning |
|---|---|
| `actor_user_id` | the person who chose (FK `users`, `on_delete: delete_all`) |
| `space_id` | the room, nullable for org-level actions such as opening a DM (FK `chat_spaces`, `delete_all`) |
| `action` | a registered key (§ 2) |
| `target_type`, `target_id` | the principal chosen or suggested (`user` or `agent`) |
| `outcome` | `accepted` (took the suggestion), `overridden` (said no, or undid it), `ignored` (closed without a pick), `chosen` (picked with no suggestion shown) |
| `rung` | the ladder rung in force when the choice was made: `none`, `rank`, `prefill`, `act` |
| `source_message_id` | the message the choice was about, nullable |
| `inserted_at` | when |

`outcome` and `rung` are closed sets enforced by CHECK constraints. A later consumer registers an
action key and needs no schema change.

`habit_patterns` is a cache over the signals plus the ladder state: one row per
`(user_id, space_id, action, target_type, target_id)`, unique `NULLS NOT DISTINCT` so an org-level
(`space_id` NULL) pattern is still one row (ADR 0052 decision 4; Postgres 15+). It carries
`accepted_prefills`, `rung` (`rank | prefill | act`), `stopped_at` and `updated_at`.

### 2. Actions are a registry

`Platform.Habits.Actions` lists every action key with its maximum rung and its reversibility rule.

- `chat.message_attention` is the one consumer now (max rung `act`).
- Reserved, capture-only (max rung `none`): `chat.mention`, `chat.dm_target`,
  `chat.channel_route`, `tasks.assign_agent`. Their consumers are child tasks 01a1b6a4-5483
  (mentions), 01a1b6a4-69a1 (DM targets), 01a1b6a4-7c31 (channel routing) and 01a1b6a4-8f69
  (agent assignment).

The signal and pattern changesets refuse an unregistered key.

### 3. Learning is ON by default, with a per-user opt-out

Every user in an install learns by default. The opt-out is
`users.preferences["learned_defaults"] = false`. When it is off, recording stores nothing and
suggesting returns no pattern. Turning it off does not delete history; forgetting a pattern does.

### 4. The trust ladder

Per `(user, space, action, target)`: **rank → prefill (one tap) → act with undo.**

- **Rank:** learned targets sort first and carry a reason line.
- **Prefill:** the top target is pre-selected when its confidence clears `prefill_threshold` and
  the decayed signal count clears `min_signals`.
- **Act:** only after `act_after_accepts` accepted pre-fills, only when the action is reversible
  for that target, and never after the user said stop.

For `chat.message_attention`, reversible means the target is a **human** principal: undo deletes
the attention row and the `chat_mention` Inbox row the add created. **Agent targets cap at
prefill**, because `AttentionRouter.route_attention/3` wakes the agent and a wake cannot be
recalled.

### 5. Every automatic action is visible, undoable and stoppable

An automatic action leaves a persistent notice on the message, rendered from the signal row, never
a toast. It has Undo, and a stop control that drops that pattern to rank for that space. An undo is
an `overridden` signal at rung `act`, which demotes the pattern to prefill and resets its count.

### 6. Thresholds and decay are experiment variants

`prefill_threshold`, `min_signals`, `act_after_accepts` and `half_life_days` are the payload of the
experiment surface `habits.learned_defaults` (`Platform.Experiments.Surfaces.LearnedDefaults`,
subject `"user"`, path `:draft`, target `chat.message_attention`). The control is
`prefill_threshold 0.6, min_signals 3, act_after_accepts 5, half_life_days 30`. Readers resolve it
with `Surfaces.resolve/4` and `Subject.new("user", user_id)`; on any error the control applies.

The metric is `habits.prefill_accept_rate`: `accepted / (accepted + overridden)` over the
prefill-rung signals of the arm's assigned users. `ignored` pre-fills are in neither side. Per
ADR 0052 rule 7, `n` travels with every result, and no judged pre-fill is `:insufficient_data`,
never `0.0`. Assigned users who have not yet judged a pre-fill are reported as `pending`.

### 7. One emission seam: a telemetry event per interaction

Surfaces do not call two systems. Each learnable interaction emits **one** `:telemetry` event in
the family `[:platform, :interaction, :choice]`, with metadata `actor_user_id`, `space_id`,
`action`, `target_type`, `target_id`, `outcome`, `rung` and `source_message_id`. `Platform.Habits`
attaches a handler and records from it locally. The sharing registry's anonymous usage counts
(task 01a1b678 stage 2, `Platform.Sharing.UsageEvents`) count from the same event, without the
ids. There is no second emitter. The handler is wired in stage 2; the prefix follows the existing
`[:platform, ...]` events.

### 8. Retention: signals are pruned past a horizon tied to decay

`habit_signals` grows per user, per action. Signals older than **6 × `half_life_days`** are
pruned; at that age a signal's weight is 1/64 of a fresh one. The `habit_patterns` row (the ladder
state) is kept. The horizon follows the variant in force, so the control prunes at 180 days. The
prune job lands in stage 2; this record only makes the decision.

### 9. The cross-install boundary

**Decision:** raw signals and message content never leave a customer install.

**Reason:** they are customer data, and the customer's terms govern them. A pattern of who asks
whom, in which room, is as revealing as the messages themselves.

Only aggregate, anonymous **pattern shapes** may travel. They go only through the sharing
registry of `0060-sharing-with-burrow-on-by-default-for-new-installs.md`, as the entry
`learned_default_shapes`, ON by default for new installs, with the install-level off switch that
ADR provides (read with `Platform.Sharing.enabled?/1`; the install is identified only by
`Platform.Sharing.get().sharing_install_id`, a random id linked to no account). This task defines
the shape contract only (stage 2, `Platform.Habits.Shapes.aggregate/0`); transport is follow-on
task 01a1b6a5-2b52-7000-815d-28d6695a7dd7.

**No install gets a special code path.** The vendor's own install learns and shares through
exactly the same switches; it simply does not turn them off.

## Out of scope

- Autonomous actions that cannot be undone.
- Export of raw signals, from any install, for any reason.

## Consequences

- One table and one substrate serve every later consumer; adding one is an action key plus a call
  site.
- Every threshold is data. Tuning the ladder is an experiment row, not a deploy.
- The ladder can never act for an agent target on `chat.message_attention`.
- A person can see, undo and stop every automatic action, and can turn learning off entirely.
