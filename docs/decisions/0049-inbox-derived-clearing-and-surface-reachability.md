# ADR 0049 — Inbox clearing is derived from subject state, and the badge counts only what the viewer can reach

**Status:** Accepted

Date: 2026-08-14

## Context

`Platform.Inbox` holds durable, per-user attention rows. Five producers write
them, and every one funnels through a single write seam:

| Producer | Kinds emitted |
| --- | --- |
| `Platform.Chat` | `chat_mention` |
| `Platform.Tasks` (plan review) | `task_plan_review` |
| `Platform.Tasks` (sponsorship) | `task_sponsor_assigned` |
| `Platform.Tasks.ReviewRequests` | `review_request_pending` |
| `Platform.Meetings.MeetingNotifier` | `meeting_starting`, `meeting_invited` |

`Platform.Inbox.emit/1` is the only insert path. It writes exactly one row for
exactly one user and broadcasts on that user's topic; producers that notify
several people call it once per recipient. There is no fan-out inside the
context, and consequently no second place a row can be born.

Rows were durable but nothing reliably *cleared* them. Eager per-actor
dismissals existed (a meeting cleared its row when you joined; the review
rollup cleared when the last request resolved), but each was a separate path
that a future resolution route could forget. A forgotten path leaves a row that
looks live and is not — attention spent on something already done.

Two further defects sat next to that one. The clearing seam that did exist was
installed at a place a whole class of users cannot reach, and the badge counted
rows whose destination those same users have no route to.

## Decision

### 1. Cleared-ness is DERIVED from subject state. It is never stored.

There is no `resolved_at`, no `cleared_at`, no migration. `dismissed_at` records
a *user action*; it does not record "the world moved on". Whether a row is stale
is computed on read from the row's own subject — the task, the plan, the
message, the meeting.

A stored flag would be a second source of truth about a fact the subject already
holds, and two sources of truth can only disagree about *time*: the subject
settles, the flag lags, and the inbox asserts something the task list denies.
Deriving makes disagreement unrepresentable.

This is the same instinct as ADR 0023, which derives unread from a
`last_read_message_id` watermark compared against monotonic UUIDv7 ids rather
than storing a per-message read flag. `Platform.Chat.message_read_by_user?/2`,
added for this work, is literally that comparison reused. The badge's overflow
grammar (the `99+` cap, no badge at zero) is unchanged and continues to follow
ADR 0022; nothing here alters how the badge *looks*, only what it counts.

`Inbox.reconcile_for_user/1` is the reconciler. It is best-effort
(`rescue -> :ok`), idempotent, and clears through the existing
`mark_dismissed/2` so the established broadcast and the unified
`unread_scope/1` badge/list query are untouched.

### 2. The governing rule: never dismiss what cannot be positively confirmed dead

A surviving stale row is an annoyance. A dismissed live row is lost attention.
Every predicate is written so its *ambiguous* answer means "still live", and the
catch-all `row_stale?/1` head returns `false`, so an unknown kind survives by
construction — a new kind is safe without anyone remembering to make it safe.

### 3. Per-kind resolution predicates

* `review_request_pending` — stale iff the resolved task has no pending review
  requests. Rows key their source three ways historically (`task_review` rollup,
  plain `task`, legacy per-request `review_request`); an unresolvable task id is
  not stale.
* `chat_mention` — stale iff `Chat.message_read_by_user?/2` says the user's
  watermark has passed the message.
* `task_plan_review` — stale iff the task exists and holds no plan in
  `pending_review`. This covers both producers of the kind, including
  `Platform.Tasks.ArchitectureRejection`'s escalation row, whose subject is also
  a plan awaiting a human decision.
* `meeting_starting` — stale iff the meeting exists and is no longer live. This
  closes the gap where a meeting *ends* without you ever joining, which the
  join-time eager dismissal could never observe.
* `task_sponsor_assigned` — **no clause, deliberately.**

### 4. `task_sponsor_assigned` gets no reconciler clause

Sponsorship is an ongoing *state*, not an event with a resolution. There is
nothing for a reconciler to watch becoming true. The only candidate signal is
task completion, and it is exactly wrong: the row means "you now own this",
which becomes *more* relevant while the task runs, not less. Clearing on
completion would dismiss a row whose subject is still true — the governing rule
violated from the other direction. Sponsor rows are cleared by the human, by
hand.

`meeting_invited` and `lifecycle_step_failed` fall to the same catch-all for a
weaker version of the same reason: neither has a subject this context can
positively confirm dead today.

### 5. Absent and settled are different answers, and `false` conflates them

`Tasks.plan_pending_review?/1` and `Meetings.meeting_live?/1` each return `false`
for **two** different worlds: the subject settled, and *there is no such row*.
Only the first is a confirmation. The naive composition "stale iff not pending"
therefore dismisses rows whose subject merely vanished — an unresolvable
subject treated as a resolved one.

The fix is a conjunction at the reconciler, not a change to the predicates:
`Tasks.task_exists?/1` and `Meetings.meeting_exists?/1` are ANDed in, so
"cannot positively confirm dead ⇒ survives" holds. The predicates are left
answering their own question; the missing-row rule belongs to the caller that
depends on the distinction. Committed tests pin it — `Platform.InboxTest`'s
"an absent task or meeting is NOT the same answer as a settled one", plus the
existence-predicate cases in `Platform.TasksTest` and `Platform.MeetingsTest`.
Those are the cases that caught the conflation, and they fail against the naive
composition.

### 6. The reconciler must sit on a path EVERY badge-rendering surface crosses

The reconciler was first installed in `InboxLive.load_items/1`. That placement
is unreachable for precisely the users who most need the healing: external
users are fenced off `/inbox` entirely, so they can accumulate stale rows and
never cross the seam that would clear them.

The fence is `PlatformWeb.Plugs.ExternalUserScope`, whose allowlist admits only
`[]`, `["chat"]` and `["chat", slug]`. (Earlier prose about this work named a
`:require_app_surface` pipeline and a `HostSurface` module — neither exists.
The allowlist above is the whole mechanism.)

The reconcile call therefore moved to `ShellLive`'s mount `on_mount`, which runs
on every surface including the external host's `:external_chat` live_session,
immediately before the first badge count is computed. Mount-only is deliberate:
reconciling inside the `:inbox_count_refresh` hook would turn one badge
broadcast into a scan-and-write storm that can re-enter itself through
`{:inbox_changed, …}`.

### 7. Reachability is enforced at the COUNT, not at the template

**A count never includes something the viewer has no way to act on.**
`Inbox.reachable_unread_scope/2` composes on the canonical `unread_scope/1`
(preserving the badge/list unification) and, for an external viewer, narrows to
`@external_reachable_kinds` — currently `["chat_mention"]`, because a mention's
home is the conversation their chat rail already renders. A new kind is excluded
by default.

The finding that qualifies this, recorded because it changes what the rule is
*for*: the badge is painted only by `IconRail.badge_text/1` from
`layouts/shell.html.heex`, and the external surface renders `Layouts.external/1`,
which has **no icon rail**. So for an external user today the count is
*computed* but not *painted*. Enforcing at the count rather than at the template
makes the rule renderer-independent — it holds for the next surface that decides
to paint a badge, without that surface having to know about it.

### 8. Blast radius of the eager plan-settle clear — stated, not smoothed over

`Inbox.dismiss_by_source/3` is keyed `(user_id, source_type, source_id)` and
**not** on `kind`. The eager clear fired at `approve_plan` / `reject_plan`
therefore also clears a `task_sponsor_assigned` row the same sponsor holds for
the same task — a row decision 4 says the reconciler must never touch.

This is a real tension, not a wrinkle. It is accepted here on two grounds:

* It only ever clears **more** than the reconciler, never less, so it cannot
  strand a stale row. The reconciler remains the correctness floor.
* At the moment it fires the sponsor's outstanding action on that task *has*
  settled.

But it means the sponsor decision is enforced by the reconciler and quietly
undercut by an optimisation beside it, which is the sort of inconsistency that
reads as a bug later. **Open question, deliberately not implemented here:**
whether `dismiss_by_source/3` should grow a `kind` filter (or a sibling
`dismiss_by_source_and_kind/4`) so the eager path can clear exactly the review
row. That is a change with its own callers to audit and belongs to its own
ticket.

### 9. Boundary — blockers, stage transitions and heartbeats are NOT inbox rows

They write no `inbox_items` rows at all. They live in
`Platform.Chat.AttentionRouter`, the disjoint attention system of ADR 0013 and
ADR 0017. The inbox is durable per-user rows with a dismissal lifecycle; the
attention router is ephemeral routing of live signal. They share vocabulary and
nothing else.

Moving any of them into the inbox is a **new producer** question — a sixth
caller of `emit/1`, with its own kind, its own resolution predicate and its own
reachability answer. Explicitly out of scope here.

## Consequences

* Stale rows self-heal on next shell mount for every user on every surface, and
  no future resolution path has to remember to clear anything for correctness to
  hold. Eager dismissals remain, as optimisations only.
* Cost is one indexed load of a user's live rows plus one indexed `EXISTS` or id
  comparison per row, on a mount path. No preloads, no aggregates, no N+1.
* Adding a kind is safe by default in two independent ways: it is not stale
  (catch-all `false`) and it is not externally reachable (allowlist).
* The tension in decision 8 is live until a `kind`-aware dismissal lands or the
  sponsor decision is reopened.
