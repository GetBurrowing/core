defmodule Platform.Inbox do
  @moduledoc """
  The Inbox context — durable, per-user attention rows and the single write
  seam every notification producer goes through.

  `emit/1` is THE write seam: it inserts exactly ONE `Inbox.Item` row for ONE
  user and broadcasts `{:inbox_item_added, item}` on that user's topic. There is
  no fan-out here — producers that want to notify several users call `emit/1`
  once per recipient.

  Semantics ("dismiss = gone; @mention = back", mirroring `Platform.Chat`):
  dismissal is per-ROW. Re-emitting for the same
  `(user_id, source_type, source_id)` triple ALWAYS inserts a fresh row even if
  a prior row for that triple was dismissed — there is no dedup or resurrection.

  **Dismissal is the ONLY clear** (task `01a00108` stage 4). Reading a row
  (`mark_read/2`, written when the user opens an item) records that it was seen
  and nothing more; it does not take the row off the list or out of the badge.
  Every scope in this module keys on `dismissed_at` alone — see
  `unread_scope/1`, which carries the full note. One kind is the exception to
  "opening only reads": opening a task you sponsor DISMISSES your
  `task_sponsor_assigned` row for it (`dismiss_sponsor_row_on_open/2`, called
  from `PlatformWeb.TasksLive.handle_params/3`, task `01a116ff`) — a dismissal,
  so dismissal is still the only clear.
  """
  import Ecto.Query

  require Logger

  alias Platform.Inbox.Item
  alias Platform.Push.Notification
  alias Platform.Repo
  alias Platform.Tenancy

  # The inbox kinds an EXTERNAL viewer has a destination for on their surface.
  # A new kind is excluded by default: the rule holds without anyone
  # remembering to exclude it.
  @external_reachable_kinds ["chat_mention"]

  @doc "PubSub topic for a user's inbox stream."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(user_id), do: "inbox:#{user_id}"

  @doc "Subscribe the calling process to a user's inbox topic."
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(Platform.PubSub, topic(user_id))
  end

  @doc """
  The write seam: insert ONE inbox item for ONE user and broadcast it.

  Accepts an attrs map with `:user_id`, `:kind`, `:source_type`, `:source_id`,
  `:title`, and optional `:body` / `:url`. On success inserts a single row,
  broadcasts `{:inbox_item_added, item}` on `topic(user_id)`, and returns
  `{:ok, item}`. On a changeset failure returns `{:error, changeset}`. No
  fan-out — call once per recipient.
  """
  @spec emit(map()) :: {:ok, Item.t()} | {:error, Ecto.Changeset.t()}
  def emit(attrs) do
    case %Item{} |> Item.changeset(attrs) |> Repo.insert() do
      {:ok, item} ->
        Phoenix.PubSub.broadcast(Platform.PubSub, topic(item.user_id), {:inbox_item_added, item})
        maybe_push(item)
        {:ok, item}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Kinds whose row is ALSO a push (task 01a10882). Approvals had no push
  # before: the row was the only signal. `chat_mention` is deliberately NOT
  # here: `Platform.Chat.AttentionRouter` already pushes every mention, so
  # pushing it again from its inbox row would double-notify.
  @push_kinds ~w(task_plan_review review_request_pending)

  @doc "The inbox kinds `emit/1` also pushes (both transports, one notification)."
  @spec push_kinds() :: [String.t()]
  def push_kinds, do: @push_kinds

  # A push failure never fails the emit: the row is the durable record and is
  # already written and broadcast.
  defp maybe_push(%Item{kind: kind, user_id: user_id} = item) when kind in @push_kinds do
    notifications_module().fan_out_to_user(user_id, Notification.from_inbox_item(item))
    :ok
  rescue
    e ->
      Logger.warning("[Inbox] push for item #{item.id} raised: #{inspect(e.__struct__)}")
      :ok
  end

  defp maybe_push(_item), do: :ok

  # Same indirection as `Platform.Tasks` and `MeetingNotifier`, so tests can
  # swap in a Recorder double (the real `fan_out_to_user/3` short-circuits in
  # :test env).
  defp notifications_module do
    Application.get_env(:platform, :notifications_module, Platform.Notifications)
  end

  @doc """
  List a user's non-dismissed inbox items, newest first. Pass `opts[:kind]` to
  filter to a single kind.

  > #### Dead in production, and now a duplicate {: .warning}
  >
  > This has ZERO production call sites — the `/inbox` list is
  > `InboxLive.load_items/1`, built on `unread_scope/1`. Its only callers are
  > tests using it as a "did a row get emitted" helper.
  >
  > Since stage 4 of task `01a00108` it also returns exactly what
  > `unread_scope/1` selects (both key on `dismissed_at` alone), so it is a
  > second spelling of the canonical scope with an ordering baked in. It is
  > kept, unrenamed, only because rewriting its test call sites would inflate a
  > diff whose risk lives elsewhere. Do not reach for it in new production
  > code: compose `unread_scope/1` instead, so there stays exactly one query
  > the badge and the list can be read off.
  """
  @spec list_unread_for_user(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_unread_for_user(user_id, opts \\ []) do
    Item
    |> where([i], i.user_id == ^user_id and is_nil(i.dismissed_at))
    |> maybe_filter_kind(opts[:kind])
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [i], i.kind == ^kind)

  @doc """
  The single canonical "live" scope — the Ecto query the badge COUNT and the
  `/inbox` list both build on, so the two can never diverge (the #589/#592
  badge-vs-list drift). A row is live iff it is not dismissed (`dismissed_at`),
  scoped to `user_id`.

  ## Reading is not clearing (task `01a00108` stage 4)

  This predicate used to be `is_nil(dismissed_at) and is_nil(read_at)`, which
  made OPENING a row the way you cleared it. The inbox is a to-do list, so
  reading and doing are two different acts: opening an item is now just having
  seen it, and only an explicit dismissal takes it off the list.

  `mark_read/2` still writes `read_at` and it still means something — "has been
  seen" — it simply no longer means "done". Nothing reads it as a filter any
  more; do not reintroduce it here without reopening the decision.

  Migration `20260817120000_backfill_read_as_dismissed_inbox_items.exs` copied
  `read_at` into `dismissed_at` for every historical row, so the rows users
  cleared under the old meaning stayed cleared through the change rather than
  resurfacing in a heap.

  The name is kept. `unread_scope/1` is referenced from `shell_live.ex`,
  `inbox_live.ex` and four functions below, and renaming it would touch far
  more than the meaning change warrants — but read it as "not cleared", not as
  "never opened".

  Returns a composable query (no `order_by`, no execution) — callers add their
  own ordering/aggregation:

    * `unread_count/1` → `Repo.aggregate(unread_scope(user_id), :count)`
    * `InboxLive.load_items/1` →
      `unread_scope(user_id) |> order_by(desc: :inserted_at) |> Repo.all()`
  """
  @spec unread_scope(Ecto.UUID.t()) :: Ecto.Query.t()
  def unread_scope(user_id) do
    from(i in Item,
      where: i.user_id == ^user_id and is_nil(i.dismissed_at)
    )
  end

  @doc """
  The reachability-aware form of `unread_scope/1`: the SAME canonical scope,
  narrowed to kinds whose destination the viewer can actually reach.

  The rule, from the design canvas "Design direction — the inbox badge an
  external user cannot act on" (rev 1): A COUNT NEVER INCLUDES SOMETHING THE
  VIEWER HAS NO WAY TO ACT ON. If nothing reachable remains the count is 0, and
  the rail's `badge_text/1` already returns nil at 0 — so no badge renders at
  all, not a zero and not a dot. Nothing in the badge's LOOK changes here
  (same treatment, same `99+` cap); only what the number counts changes.

  * external viewer → `#{inspect(@external_reachable_kinds)}` only. An external
    user is fenced off `/inbox` by `PlatformWeb.Plugs.ExternalUserScope`, so
    every other kind is a promise their surface cannot keep. `chat_mention`
    survives because a mention's home is the conversation, which their chat
    rail already renders (and marks unread) on the host they are on.
  * internal viewer → `unread_scope/1` VERBATIM. No filter, no behaviour change.

  This composes ON `unread_scope/1` rather than restating it, so the badge and
  the `/inbox` list keep building on one query (the #589/#592 drift). The
  externality branch keys off `Platform.Tenancy.external_user?/1`, the existing
  shared predicate — there is deliberately no second externality test.

  Arity 2 takes the already-known externality so a caller that has it does not
  re-query; arity 1 answers it once via `Tenancy.external_user?/1`.

  Note this is the COUNT-side rule, not a template rule. At the time of writing
  the badge is painted only by `PlatformWeb.Components.IconRail`'s
  `badge_text/1` from `layouts/shell.html.heex`, and the external surface
  (`Layouts.external/1`) renders NO icon rail — so for an external user the
  count is COMPUTED but not currently PAINTED. Enforcing at the count makes the
  rule hold for every present and future renderer instead of one template.
  """
  @spec reachable_unread_scope(Ecto.UUID.t(), boolean()) :: Ecto.Query.t()
  def reachable_unread_scope(user_id, external?)

  def reachable_unread_scope(user_id, true) do
    where(unread_scope(user_id), [i], i.kind in @external_reachable_kinds)
  end

  def reachable_unread_scope(user_id, false), do: unread_scope(user_id)

  @spec reachable_unread_scope(Ecto.UUID.t()) :: Ecto.Query.t()
  def reachable_unread_scope(user_id) do
    reachable_unread_scope(user_id, Tenancy.external_user?(%{id: user_id}))
  end

  @doc """
  `unread_count/1` narrowed to what this viewer can reach — the badge number.

  One aggregate over `reachable_unread_scope/1`. For an internal user this is
  `unread_count/1` exactly; for an external user it counts reachable kinds only,
  and 0 means the badge node leaves the DOM.
  """
  @spec reachable_unread_count(Ecto.UUID.t()) :: non_neg_integer()
  def reachable_unread_count(user_id) do
    Repo.aggregate(reachable_unread_scope(user_id), :count)
  end

  @doc """
  Whether a live (non-dismissed) inbox row already exists for a source triple.

  The producer-side dedup seam: before emitting a rolled-up review row a
  producer checks this so a task with N review gates yields exactly ONE
  `(user, source_type, source_id)` inbox row instead of N. Read status is
  irrelevant — a read-but-not-dismissed rollup row still represents the live
  attention, so it blocks a duplicate insert.
  """
  @spec active_source_row?(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) :: boolean()
  def active_source_row?(user_id, source_type, source_id) do
    Repo.exists?(
      from(i in Item,
        where:
          i.user_id == ^user_id and i.source_type == ^source_type and
            i.source_id == ^source_id and is_nil(i.dismissed_at)
      )
    )
  end

  @doc """
  Count a user's non-dismissed inbox items — the live-badge number.

  A single aggregate query, cheaper than materializing rows just to take a
  length. It counts exactly what the Inbox surface renders, because it is the
  SAME query: one `Repo.aggregate` over `unread_scope/1`, which is what
  `InboxLive.load_items/1` selects rows from. That shared predicate is the
  standing fix for #589/#592 (a read item inflating the badge while the list
  showed nothing), and it is why stage 4 of task `01a00108` could change the
  meaning of "cleared" in one place: move the scope and the badge and the list
  move together, or they drift apart again in the opposite direction.

  Scoping is inherent: only rows whose `user_id` matches are counted, so an
  external user's count is naturally limited to their own (allowlisted) rows
  without an extra scope filter.
  """
  @spec unread_count(Ecto.UUID.t()) :: non_neg_integer()
  def unread_count(user_id) do
    Repo.aggregate(unread_scope(user_id), :count)
  end

  @doc """
  Mark an item read for `user_id` — "the user has seen this", and nothing more.

  Reading does NOT clear a row. Since stage 4 of task `01a00108` the row stays
  on `/inbox` and in the badge until it is explicitly dismissed; only
  `dismissed_at` takes it off. `read_at` is kept, and kept written, because
  "seen" is a real fact worth having — it is what migration `20260817120000`
  read to preserve historical clears, and it is the natural input to any future
  seen/unseen affordance.

  Be clear-eyed about what that leaves, though: as of this stage `read_at` is a
  column with a writer and NO reader. Nothing filters on it and nothing renders
  it (the row's dot is unconditional — see `PlatformWeb.Components.InboxItem`).
  It is retained on purpose, not by oversight, and a later stage that adds a
  seen/unseen affordance is where it earns its keep again.

  The `user_id` is a defensive cross-user guard: the update is scoped by both
  `id` and `user_id`, so a mismatched user mutates nothing and gets
  `{:error, :not_found}`.
  """
  @spec mark_read(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def mark_read(item_id, user_id) do
    case set_timestamp(item_id, user_id, :read_at) do
      {:ok, item} = ok ->
        # Kept deliberately, and deliberately NOT load-bearing today. Reading
        # used to drop a row from `unread_scope/1` without any add/dismiss event
        # to announce it — a silent mutation the live badge missed, which is
        # what this broadcast was added to fix. Now that reading clears nothing,
        # the coarse `{:inbox_changed, user_id}` moves neither the count nor the
        # rendered set: shells recompute to the same number and InboxLive
        # re-derives the same rows.
        #
        # It stays because every other writer here signals the same way, and the
        # uniform "a row changed, re-derive" rule is what keeps surfaces from
        # drifting; a writer that stays quiet is the shape of the original bug.
        # Do not read this as proof that a read is observable — it is not, until
        # something renders `read_at`. A cross-user guard miss
        # (`{:error, :not_found}`) broadcasts nothing.
        broadcast_changed(item.user_id)
        ok

      other ->
        other
    end
  end

  defp broadcast_changed(user_id) do
    Phoenix.PubSub.broadcast(Platform.PubSub, topic(user_id), {:inbox_changed, user_id})
  end

  @doc """
  Mark an item dismissed for `user_id` (removes it from the unread list).

  Same cross-user guard as `mark_read/2`. Dismissal is per-ROW — a later
  `emit/1` for the same source triple still inserts a fresh row.

  On success broadcasts `{:inbox_item_dismissed, item}` on `topic(user_id)`
  (mirroring `emit/1`'s add broadcast) so live consumers — e.g. the icon-rail
  unread badge — can decrement without a re-query. A cross-user guard miss
  (`{:error, :not_found}`) broadcasts nothing.
  """
  @spec mark_dismissed(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def mark_dismissed(item_id, user_id) do
    case set_timestamp(item_id, user_id, :dismissed_at) do
      {:ok, item} ->
        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          topic(item.user_id),
          {:inbox_item_dismissed, item}
        )

        {:ok, item}

      other ->
        other
    end
  end

  @doc """
  Dismiss every non-dismissed inbox row for `user_id` keyed to a source triple.

  Source-keyed dismissal seam: when the attention condition a
  `(source_type, source_id)` row points at resolves for a user (e.g. they join
  the meeting a `meeting_starting` row references), the producer calls this to
  clear all live rows for that source. Uses the
  `(user_id, source_type, source_id)` index M1 ships.

  Cross-user guarded (scoped by `user_id`, like `mark_dismissed/2`) and
  idempotent — already-dismissed or absent rows are a safe no-op. Returns
  `{:ok, count}` with the number of rows dismissed.

  ## `kind:` — clear only the kind you own

  A source triple is NOT unique per kind. `task_sponsor_assigned` and
  `task_plan_review` both carry `source_type: "task"` and the same task id, so
  an unfiltered sweep from a plan-settle path dismisses the sponsor row too —
  in the same write, with the same `dismissed_at`. That contradicts
  `row_stale?/1`'s documented decision that sponsor rows are cleared by hand
  OR when the sponsor opens the task (`dismiss_sponsor_row_on_open/2`, task
  `01a116ff`, which itself calls this with `kind: "task_sponsor_assigned"`),
  and it silently undoes a choice this system made on purpose.

  So a caller that owns ONE kind passes `kind: "task_plan_review"` and touches
  nothing else. Callers whose resolution genuinely retires every row for the
  source — joining the meeting a `meeting_starting` row points at — keep the
  unfiltered form deliberately.
  """
  @spec dismiss_by_source(Ecto.UUID.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, non_neg_integer()}
  def dismiss_by_source(user_id, source_type, source_id, opts \\ []) do
    now = DateTime.utc_now()

    {count, _} =
      Item
      |> where(
        [i],
        i.user_id == ^user_id and i.source_type == ^source_type and
          i.source_id == ^source_id and is_nil(i.dismissed_at)
      )
      |> filter_kind(Keyword.get(opts, :kind))
      |> Repo.update_all(set: [dismissed_at: now])

    # Source-keyed dismissal is another silent mutation the live badge used to
    # miss (it broadcast NOTHING). When it actually cleared rows, broadcast the
    # coarse `{:inbox_changed, user_id}` so shells recompute the badge and
    # InboxLive re-derives. A no-op (count 0) stays quiet.
    if count > 0, do: broadcast_changed(user_id)

    {:ok, count}
  end

  @doc """
  Dismiss `user_id`'s live `task_sponsor_assigned` row for `task_id`: the
  sponsor opened the task (task `01a116ff`).

  Called from `PlatformWeb.TasksLive.handle_params/3` for `/tasks/:task_id`,
  the one clause both open paths run: the board pane (`select_task` ->
  `push_patch`) and the inbox deep link (`InboxLive` "open" ->
  `push_navigate` -> mount). A call in `InboxLive` alone would miss the pane.

  Scoped to the CURRENT user, so a non-sponsor's visit clears nothing of the
  sponsor's (a former sponsor whose old row is still live clears their own
  row, which is intended). `kind:` is REQUIRED here: `task_plan_review` rows
  carry the same `source_type: "task"` and task id, and an unfiltered sweep
  would clear the plan-review row too. `handle_params/3` runs on both the
  dead and the connected render; the second call is a count-0 no-op that
  does not broadcast. A non-binary `user_id` (no session user) is a no-op.
  """
  @spec dismiss_sponsor_row_on_open(term(), Ecto.UUID.t()) :: :ok
  def dismiss_sponsor_row_on_open(user_id, task_id) when is_binary(user_id) do
    {:ok, _} = dismiss_by_source(user_id, "task", task_id, kind: "task_sponsor_assigned")
    :ok
  end

  def dismiss_sponsor_row_on_open(_user_id, _task_id), do: :ok

  # nil kind means "every kind for this source" — the pre-existing behaviour,
  # kept as the default so no current caller changes shape.
  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind) when is_binary(kind), do: where(query, [i], i.kind == ^kind)

  @doc """
  Dismiss many rows by id for `user_id`. Returns `{:ok, changed_ids}` — EXACTLY
  the ids this call transitioned, never merely the ids it was handed.

  The inbox is a to-do list, so ticking several things off is one gesture. This
  is `dismiss_by_source/4`'s write-then-single-broadcast shape keyed on a
  caller-supplied id list instead of a source triple: ONE `update_all`, then ONE
  coarse `{:inbox_changed, user_id}` — not N per-row events for an N-row sweep.

  ## Why the returned list is the point

  The `is_nil(i.dismissed_at)` filter does double duty. It keeps the write
  idempotent, and — because `RETURNING` reports only rows the statement actually
  touched — it makes the returned list precisely "what this call changed". A row
  the user dismissed an hour ago is silently skipped and is ABSENT from the
  result even when its id is passed.

  That absence is the contract an undo depends on: an undo built from this list
  can only ever restore rows this call dismissed, so it cannot resurrect
  something the user dismissed deliberately and earlier. Dropping the filter
  would still dismiss the right rows, and would still look correct — the damage
  would surface only later, as an undo reviving rows nobody asked back.

  Ordering is Postgres's and is not guaranteed; callers that compare should sort.

  Cross-user guarded like `mark_dismissed/2`: the `user_id` scope is part of the
  WHERE, so ids belonging to another user match nothing, mutate nothing, and are
  absent from the returned list.
  """
  @spec dismiss_many(Ecto.UUID.t(), [Ecto.UUID.t()]) :: {:ok, [Ecto.UUID.t()]}
  def dismiss_many(user_id, ids) do
    now = DateTime.utc_now()

    {_count, changed_ids} =
      Item
      |> where([i], i.user_id == ^user_id and i.id in ^ids and is_nil(i.dismissed_at))
      |> select([i], i.id)
      |> Repo.update_all(set: [dismissed_at: now])

    # One coarse broadcast for the whole sweep, mirroring `dismiss_by_source/4`:
    # shells recompute the badge and InboxLive re-derives its list once. A sweep
    # that changed nothing stays quiet.
    if changed_ids != [], do: broadcast_changed(user_id)

    {:ok, changed_ids}
  end

  @doc """
  Dismiss EVERY row the user's inbox surface is showing — the "Clear all" sweep.
  Returns `{:ok, changed_ids}` under exactly `dismiss_many/2`'s contract: the ids
  this call transitioned, and only those.

  ## Why this takes no id list

  "Clear all" must not be a clear-what-is-drawn. Handing the LiveView's rendered
  ids to `dismiss_many/2` would read the set in one query and write it in
  another, so a row that arrived in between survives a gesture that said "all" —
  and the surface would then re-derive and show it, which reads as the button
  having failed. Selecting and updating in ONE statement removes the gap: the
  scope is evaluated by Postgres at write time.

  ## The scope is `unread_scope/1`, and the rule is "clear what you can see"

  The governing rule is that the count on the button and the set this writes
  must be the SAME set, or the button lies — and an undo built from the write
  would restore rows into invisibility.

  `unread_scope/1` is what satisfies that: the badge counts it, `/inbox`
  renders it, and this clears it. One scope, so no call site has to guess.

  This paragraph used to argue something narrower — that the sweep must skip
  read-but-not-dismissed rows, because such a row was absent from the surface
  and the button's count could not name it. Stage 4 of task `01a00108` retired
  read-as-cleared, so that case no longer exists: a row you opened is on the
  list, is in the count, and is therefore swept, which is correct under the
  same rule that previously excluded it. The rule did not change; what counts
  as visible did. Keep deriving both from `unread_scope/1` and this stays true
  through whatever the predicate becomes next.

  One `update_all`, then ONE coarse `{:inbox_changed, user_id}` — shells recompute
  the badge (rail, Dock icon and title prefix all hang off that one number) and
  `InboxLive` re-derives. A sweep that changed nothing stays quiet.
  """
  @spec dismiss_all_unread(Ecto.UUID.t()) :: {:ok, [Ecto.UUID.t()]}
  def dismiss_all_unread(user_id) do
    now = DateTime.utc_now()

    {_count, changed_ids} =
      user_id
      |> unread_scope()
      |> select([i], i.id)
      |> Repo.update_all(set: [dismissed_at: now])

    if changed_ids != [], do: broadcast_changed(user_id)

    {:ok, changed_ids}
  end

  @doc """
  The inverse of `dismiss_many/2`: clear `dismissed_at` for the given ids,
  returning `{:ok, restored_ids}`. Same single-write, single-broadcast shape and
  the same non-optional `user_id` scope.

  Note the deliberate asymmetry with `dismiss_many/2`: there is NO
  `not is_nil(i.dismissed_at)` guard here, so the returned list is every row the
  scope matched rather than only rows that changed state. Restoring an
  already-live row is a no-op on that row's value, and the caller that needs
  exactness — an undo — gets it from `dismiss_many/2`'s list, which is the one
  that has to be precise.
  """
  @spec restore_many(Ecto.UUID.t(), [Ecto.UUID.t()]) :: {:ok, [Ecto.UUID.t()]}
  def restore_many(user_id, ids) do
    {_count, restored_ids} =
      Item
      |> where([i], i.user_id == ^user_id and i.id in ^ids)
      |> select([i], i.id)
      |> Repo.update_all(set: [dismissed_at: nil])

    if restored_ids != [], do: broadcast_changed(user_id)

    {:ok, restored_ids}
  end

  @doc """
  Lazy reconciler: dismiss every live inbox row for `user_id` whose underlying
  subject can be POSITIVELY confirmed resolved.

  Rowan's "simple & reliable" self-healing seam (no push coupling): rather than
  chase every resolution path to dismiss the row it produced, callers run this
  at load so a stale row drops off on next view. Eager per-actor clearing
  (`Meetings.maybe_dismiss_meeting_inbox/2`, the rollup dismiss on the last
  resolved review) stays in place as an OPTIMISATION beside this reconciler —
  never as the primary mechanism. If actors were the only mechanism then every
  future resolution path would have to remember, and the one that forgets
  leaves a stale row that looks live.

  ## The governing rule

  NEVER dismiss a row that cannot be positively confirmed dead. An unresolvable
  subject, a MISSING SOURCE ROW, or an unknown kind is NOT stale and survives —
  the catch-all `row_stale?/1` head returns `false`, and each predicate is
  written so its ambiguous answer means "still live". There is no optimistic
  reconciliation here: a surviving stale row is a small annoyance, a dismissed
  live row is lost attention.

  This is why the `task_plan_review` and `meeting_starting` clauses each pair
  their staleness predicate with an existence check. Stage 1's
  `Tasks.plan_pending_review?/1` and `Meetings.meeting_live?/1` answer `false`
  for two different worlds — the subject settled, and no such row — and only
  the first is a confirmation. The reconciler, not those predicates, is where
  the missing-row rule belongs, so they are unchanged.

  Nothing is stored to record the outcome — no `resolved_at` / `cleared_at`
  column, no migration. Staleness is DERIVED on read from the subject's own
  state, so it cannot disagree with that state the way a denormalised column
  could. Clearing goes through `mark_dismissed/2`, so the existing
  `{:inbox_item_dismissed, item}` broadcast and the `unread_scope/1` badge/list
  unification are unchanged.

  ## Per-kind clauses

    * `review_request_pending` — stale iff the resolved task has no pending
      review requests. Rows key their source three ways historically:
      `task_review` (the per-task rollup, `source_id` = task id), plain `task`,
      or the legacy per-request `review_request` (`source_id` = request id).
    * `chat_mention` (`source_type: "chat_message"`) — stale iff the user has
      read the message, per `Platform.Chat.message_read_by_user?/2`.
    * `task_plan_review` (`source_type: "task"`, `source_id` = TASK id) — stale
      iff the task has no plan in `pending_review`. This covers BOTH producers
      of the kind: the plan-settled emit and
      `Platform.Tasks.ArchitectureRejection`'s escalation row, whose subject is
      also a plan left sitting in `pending_review` for a human decision.
    * `meeting_starting` (`source_type: "meeting"`) — stale iff the meeting is
      no longer live. This closes the gap where a meeting ENDS without you ever
      joining: `Meetings.maybe_dismiss_meeting_inbox/2` fires at join time only,
      so nothing else would ever clear that row.
    * `task_sponsor_assigned` — deliberately NO clause; see `row_stale?/1`.

  Cost: one indexed load of the user's live rows (indexed on `user_id`), then a
  single indexed EXISTS or id comparison per row. No preloads, no aggregates,
  no N+1 joins — this runs on a shell-mount path.

  Best-effort by design (`rescue -> :ok`): reconciliation is a convenience over
  the durable rows, and a reconciler that raises must never take down the mount
  that called it.
  """
  @spec reconcile_for_user(Ecto.UUID.t()) :: :ok
  def reconcile_for_user(user_id) when is_binary(user_id) do
    Repo.all(from(i in Item, where: i.user_id == ^user_id and is_nil(i.dismissed_at)))
    |> Enum.each(fn item ->
      if row_stale?(item), do: mark_dismissed(item.id, user_id)
    end)

    :ok
  rescue
    _ -> :ok
  end

  def reconcile_for_user(_), do: :ok

  # Whether a live row's subject is positively confirmed resolved. One head per
  # reconcilable kind; everything else falls to the catch-all and SURVIVES.
  defp row_stale?(%Item{kind: "review_request_pending"} = item), do: review_row_stale?(item)

  defp row_stale?(%Item{kind: "chat_mention", source_type: "chat_message"} = item) do
    Platform.Chat.message_read_by_user?(item.source_id, item.user_id)
  end

  # The existence check is not redundant. `plan_pending_review?/1` and
  # `meeting_live?/1` each answer `false` for TWO different worlds — the subject
  # settled, and no such row — and only the first is a positive confirmation.
  # Without the `_exists?` conjunct a row whose task or meeting cannot be found
  # would be dismissed on an unresolvable subject, which is the governing rule
  # violated exactly. It costs one extra primary-key EXISTS on these two kinds.
  defp row_stale?(%Item{kind: "task_plan_review", source_type: "task", source_id: task_id}) do
    Platform.Tasks.task_exists?(task_id) and not Platform.Tasks.plan_pending_review?(task_id)
  end

  defp row_stale?(%Item{kind: "meeting_starting", source_type: "meeting", source_id: meeting_id}) do
    Platform.Meetings.meeting_exists?(meeting_id) and
      not Platform.Meetings.meeting_live?(meeting_id)
  end

  # DELIBERATE DECISION — do not add a `task_sponsor_assigned` clause without
  # reopening it. Sponsorship has no resolution EVENT; it is an ongoing state,
  # so there is nothing for a reconciler to observe becoming true. Task
  # completion is the only candidate and it is exactly wrong: a sponsor's row
  # means "you now own this", which becomes MORE relevant while the task runs,
  # not less. Clearing on completion would dismiss a row whose subject is still
  # true — the never-dismiss-what-you-cannot-confirm-dead rule violated from the
  # other direction. Sponsor rows are cleared by hand OR when the sponsor opens
  # the task (`dismiss_sponsor_row_on_open/2`, task 01a116ff). That reverses #811's
  # "open only marks read" rule for this one kind only; it is a user action,
  # not a reconciler clause, so the decision here is unchanged.
  # `inbox_test.exs` pins this: a sponsor row survives reconciliation even after
  # its task completes. If that test detonates, the decision is being changed
  # and must be reopened rather than patched.
  #
  # `meeting_invited` and `lifecycle_step_failed` land here too, for the same
  # reason in a weaker form: neither has a subject this module can positively
  # confirm dead today.
  defp row_stale?(%Item{}), do: false

  # Stale iff the resolved task has no pending review requests. Unresolvable
  # task ids (nil) are treated as NOT stale — we never dismiss a row we cannot
  # positively confirm is dead.
  defp review_row_stale?(item) do
    case review_row_task_id(item) do
      task_id when is_binary(task_id) ->
        not Platform.Tasks.ReviewRequests.task_has_pending_reviews?(task_id)

      _ ->
        false
    end
  end

  defp review_row_task_id(%Item{source_type: st, source_id: sid})
       when st in ["task", "task_review"],
       do: sid

  defp review_row_task_id(%Item{source_type: "review_request", source_id: sid}),
    do: Platform.Tasks.ReviewRequests.task_id_for_request(sid)

  defp review_row_task_id(_), do: nil

  defp set_timestamp(item_id, user_id, field) do
    query = from(i in Item, where: i.id == ^item_id and i.user_id == ^user_id)

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %Item{} = item ->
        item
        |> Ecto.Changeset.change(%{field => DateTime.utc_now()})
        |> Repo.update()
    end
  end
end
