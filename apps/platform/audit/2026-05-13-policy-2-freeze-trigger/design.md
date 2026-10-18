# Policy 2 freeze trigger — Stage 1 design doc

**Task:** `019e1e80-4230-7a79-ac73-c157975b3999` — Implement Policy 2 freeze trigger for editable messages (task-scoped + ad-hoc)
**Plan:** v2, approved 2026-05-13T14:34Z
**Branch:** `task/019e1e80-4230-7a79-ac73-c157975b3999`
**Stage:** 1 / 6 (recon + design — no source-code changes)

This document captures the static recon findings, the deviations from the v2 plan
that surfaced during recon, and the resulting design that the remaining stages
will implement. It supersedes the v2 plan wording where the two disagree; the
deviations are listed explicitly with reasons.

---

## 1. Recon findings

### 1.1 `Tasks.transition_task/2` (`apps/platform/lib/platform/tasks.ex:937`)

Current shape:

```elixir
def transition_task(%Task{} = task, new_status) do
  with :ok <- require_approved_plan_for(task, new_status),
       :ok <- maybe_prepare_transition(task, new_status),
       {:ok, updated} <- transition_task_status(task, new_status) do
    updated = Repo.preload(updated, [:project, :epic, plans: :stages])
    broadcast_board({:task_updated, updated})
    maybe_finalize_transition(task, updated, new_status)
    {:ok, updated}
  else
    error -> error
  end
end
```

The status flip (`transition_task_status/2`) is a bare `Repo.update/1` — **not
wrapped in `Repo.transaction`**. The post-flip hooks (`broadcast_board`,
`maybe_finalize_transition`) run after the row is already persisted, outside
any transaction.

Implication for atomicity: Stage 3 must open the `Repo.transaction` itself so
the status flip and the freeze loop commit together (or roll back together).
We cannot just "add a freeze call after `transition_task_status`" — that would
leave the door open to a partial-freeze-after-flip failure, the exact silent
state divergence Policy 2 was designed to prevent.

### 1.2 `MessageVersions.freeze/2` (`apps/platform/lib/platform/chat/message_versions.ex:147`)

The v2 plan refers to `MessageVersions.freeze!/2`. **No bang version exists.**
The actual public surface is:

```elixir
@spec freeze(Message.t(), binary()) ::
        {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
def freeze(%Message{frozen_at: %DateTime{}} = message, _participant_id), do: {:ok, message}

def freeze(%Message{} = message, participant_id) when is_binary(participant_id) do
  message
  |> Message.changeset(%{
    frozen_at: DateTime.utc_now(),
    frozen_by_participant_id: participant_id
  })
  |> Repo.update()
end
```

Behaviour observed:
- Tuple-returning, **not bang**.
- Idempotent on already-frozen messages (returns `{:ok, message}` with the
  original `frozen_at` preserved — important for audit: the first freezer wins).
- Requires `participant_id` to be a non-nil binary (changeset rejects nil per
  the `frozen_both_or_neither` validator).

**Design decision:** Stage 3 and Stage 4 will use `freeze/2` directly and
pattern-match `{:ok, _}` vs. `{:error, changeset}` to drive the
`Repo.rollback` path on the error arm. This is preferred to adding a `freeze!/2`
bang wrapper because (a) the call sites are inside transactions where rollback
on changeset error is the precise behaviour we want, and (b) the bang wrapper
would add a new public surface item that no caller outside this task needs.

### 1.3 `chat_messages.task_id` does NOT exist (predicate redesign)

The v2 plan and the original task description both refer to:

> chat_messages.task_id pointing at any task whose assignee_id is this agent
> AND status IN (planning, in_progress)

**This column does not exist in the schema.** Confirmed by:

- `apps/platform/lib/platform/chat/message.ex` — full field list, no `:task_id`.
- `apps/platform/priv/repo/migrations/20260314080000_create_chat_tables.exs`
  and `20260511170000_add_message_edit_history.exs` — no `add :task_id` on
  the `chat_messages` table.
- `rg "task_id" apps/platform/lib/platform/chat/message.ex` — empty.

How message-task linkage **actually** works today:

- `chat_spaces.kind = "execution"` rows carry the task id in
  `metadata->>'task_id'` (see
  `apps/platform/lib/platform/orchestration/execution_space.ex:40` and
  `:152`). This is the documented Suite pattern — one execution space per task.
- `Platform.Chat.AttentionRouter.execution_space_task_id/1`
  (`attention_router.ex:414`) is the canonical reader for that linkage.
- The `Tasks.Task` row has `assignee_id`, so "agent assigned to the task whose
  execution space holds this message" is computable via a single join.

**Design decision (deviates from v2 plan, Stage 2 description):**

The Stage 2 query function `Platform.Chat.in_context_message_ids_for_agent/2`
will compute the union over:

- **Mention arm.** Messages in the given space whose
  `content` contains `@[DisplayName]` (or legacy `@name`) resolving to the
  agent's participant `display_name` in that space. We reuse the existing
  `AttentionRouter.extract_bracketed_tokens/1` parser to stay consistent with
  routing semantics.

- **Task arm (redesigned).** Messages whose `space_id` is an execution
  space (`chat_spaces.kind = "execution"`) whose
  `metadata->>'task_id'` resolves to a task with `assignee_id` == this agent
  AND status in (`planning`, `in_progress`). Closed/done tasks excluded so
  historical task linkage doesn't eternally freeze old messages.

**Why this redesign over adding a column:** the alternative — adding a
`chat_messages.task_id` column via migration — is a schema change that affects
write-path code in `Chat.post_message/1` (every message would need to be
populated with the column at insert), backfills, replication, and the
editable-messages contract canvas. It is at least an order of magnitude more
expensive than reusing the existing execution-space binding, with no
observable difference in the freeze behaviour from the user's point of view.

**Cross-space leakage:** the function takes `space_id` as an argument and
scopes both arms by it, so an agent assigned to a task in space A receives an
empty set when queried about space B (covered by a dedicated test).

**Note for the editable-messages contract canvas:** the canvas references
`chat_messages.task_id` in section (f) Policy 2. We are not editing the
canvas as part of this task, but the contract is technically referring to a
column that doesn't exist. A future contract-maintenance task should update
that line to describe the actual mechanism (execution-space binding). Filed
informally for follow-up; not blocking this implementation.

### 1.4 Other observations (no plan deviation)

- `Tasks.transition_task` already preloads `[:project, :epic, plans: :stages]`
  after the flip. Stage 3's broadcast can re-use the same preloaded struct.
- `chat_messages.frozen_at` plus `frozen_by_participant_id` are governed by
  the `frozen_both_or_neither` check constraint at the DB level AND the
  matching validator in `Message.changeset/2`. Either both or neither — the
  freeze call already complies (sets both).
- The board topic broadcast (`broadcast_board({:task_updated, ...})`) fires
  unconditionally on a successful transition. The new
  `{:messages_frozen, ...}` broadcast Stage 3 adds will fire on the space
  topic (not the board topic) so chat LiveViews — which subscribe per-space —
  pick it up to flip the (edited) affordance tooltips to disabled state
  without a full reload.

---

## 2. Atomicity contract (reaffirmed from v2 plan)

- **Task-scoped freeze (Stage 3).** The status flip and the freeze loop MUST
  share one `Repo.transaction/1`. On any freeze failure (changeset error from
  `MessageVersions.freeze/2`), the entire transaction rolls back: task status
  stays at the original value, no messages get frozen. The
  `:messages_frozen` broadcast fires only after the transaction commits.
- **Ad-hoc freeze (Stage 4).** The listener wraps its freeze loop in its own
  `Repo.transaction/1`. On any freeze failure, the entire loop rolls back —
  no messages are partially frozen. The listener has no task-status flip to
  guard, but the all-or-nothing invariant still holds.

The atomicity test from the v2 plan (Stage 3 test_pass: "mock freeze to raise
on the second call → status flip rolls back, neither frozen, task stays
:planning") becomes "mock freeze/2 to return `{:error, changeset}` on the
second call" — adjusted for the tuple-returning API but logically identical.

---

## 3. D-6 scope split (reaffirmed from v2 plan)

This task implements the **chat-side consumer** of the
`{:agent_first_state_op, agent_participant_id, space_id}` signal.

**Out of scope for this task:** the **emitter side** — state-changing-tool
interception inside the Suite MCP runtime that detects when an agent has
performed its first state-changing op this session and broadcasts the signal.
That work is filed as a separate Suite-side task and will be implemented in
the Suite repo, not in core. Without the emitter wired up, the listener will
sit idle in production. It can be unit-tested by directly broadcasting the
PubSub message from the test process, which proves the consumer correctness
contract; that's what Stage 4's test does.

---

## 4. Stage map (final shape for this branch)

| Stage | Surface | Validations |
|---|---|---|
| 1 | This design doc — recon + design. No code changes. | (none) |
| 2 | `Platform.Chat.in_context_message_ids_for_agent/2` query function in `apps/platform/lib/platform/chat.ex` + new test file. Two-arm union (mention + execution-space-task-link). | test_pass, lint_pass |
| 3 | `Tasks.transition_task` wraps in `Repo.transaction`; freezes messages of the task's execution space on `:in_progress`; emits `{:messages_frozen, ...}` on the space topic; chat LiveView hook handles it. | test_pass, lint_pass, **manual_approval** (UI affordance state) |
| 4 | New `Platform.Chat.AdHocFreezeListener` GenServer/PubSub subscriber, added to `Platform.Application` children. Consumes `{:agent_first_state_op, ...}` from the `chat:agent_runtime` topic, calls Stage 2's query, freezes the result in a `Repo.transaction`. | test_pass, lint_pass |
| 5 | Un-skip `edit_permissions_test.exs` Case 6 (planning-time signal does NOT freeze); update audit docs `03-stage3-permission-coverage.md` and `99-final-report.md` Section (e)/(f). | test_pass, lint_pass |
| 6 | Synthetic task-level review gate (5 `e2e_behavior` cases). | e2e_behavior (the design lead) |

---

## 5. Risks + open questions

- **The execution-space-binding redesign** (§ 1.3) is the only material
  deviation from the v2 plan wording. It preserves the user-visible freeze
  semantics with no schema migration. If the editable-messages contract
  canvas explicitly required `chat_messages.task_id` for reasons other than
  "linkage" (e.g. messages outside execution spaces that nevertheless want
  task scoping), this redesign drops that use case. Flagged to the design lead via
  #design-playspace; default assumption is that execution-space binding is
  sufficient.
- **`(edited)` affordance tooltip refresh** on the broadcast. The chat
  LiveView `messages_hooks.ex` currently has a `{:message_edited, _}` handler
  at `:542`. We add a sibling `{:messages_frozen, ids, reason}` handler that
  re-stream-inserts the affected message rows so the bubble's "edit pencil"
  switches to its disabled-with-tooltip state without a full LV reload. This
  is the only UI touch (and hence the only `manual_approval` validation).
- **Stage 3 atomicity test** uses `Mox` or similar to make
  `MessageVersions.freeze/2` return `{:error, changeset}` on the second call.
  We'll wire it through a behaviour shim that defaults to the real module so
  production code is unaffected.

End of Stage 1 design.
