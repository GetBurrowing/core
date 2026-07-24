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
  Read status is orthogonal to dismissal: `list_unread_for_user/2` surfaces both
  read and unread rows, excluding only dismissed ones.
  """
  import Ecto.Query

  alias Platform.Inbox.Item
  alias Platform.Repo

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
        {:ok, item}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  List a user's non-dismissed inbox items, newest first.

  Read status is orthogonal to dismissal — read-but-not-dismissed rows are
  included. Pass `opts[:kind]` to filter to a single kind.
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
  The single canonical "unread" scope — the Ecto query the badge COUNT and the
  `/inbox` list both build on, so the two can never diverge again (the
  #589/#592 badge-vs-list drift). A row is unread iff it is neither dismissed
  (`dismissed_at`) nor read (`read_at`), scoped to `user_id`.

  Returns a composable query (no `order_by`, no execution) — callers add their
  own ordering/aggregation:

    * `unread_count/1` → `Repo.aggregate(unread_scope(user_id), :count)`
    * `InboxLive.load_items/1` →
      `unread_scope(user_id) |> order_by(desc: :inserted_at) |> Repo.all()`
  """
  @spec unread_scope(Ecto.UUID.t()) :: Ecto.Query.t()
  def unread_scope(user_id) do
    from(i in Item,
      where: i.user_id == ^user_id and is_nil(i.dismissed_at) and is_nil(i.read_at)
    )
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
  Count a user's unread, non-dismissed inbox items — the live-badge number.

  A single aggregate query, cheaper than materializing rows just to take a
  length. It counts exactly what the Inbox surface renders: rows that are
  neither read (`read_at`) nor dismissed (`dismissed_at`). Read-but-not-dismissed
  rows are excluded here just as `InboxLive` drops them from the list, so the
  badge and the list can never diverge (a read item inflating the badge while
  showing nothing was the #589/#592 badge/list bug). This is intentionally
  narrower than `list_unread_for_user/2`, which still surfaces read rows.

  Scoping is inherent: only rows whose `user_id` matches are counted, so an
  external user's count is naturally limited to their own (allowlisted) rows
  without an extra scope filter.
  """
  @spec unread_count(Ecto.UUID.t()) :: non_neg_integer()
  def unread_count(user_id) do
    Repo.aggregate(unread_scope(user_id), :count)
  end

  @doc """
  Mark an item read for `user_id`.

  The `user_id` is a defensive cross-user guard: the update is scoped by both
  `id` and `user_id`, so a mismatched user mutates nothing and gets
  `{:error, :not_found}`.
  """
  @spec mark_read(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def mark_read(item_id, user_id) do
    case set_timestamp(item_id, user_id, :read_at) do
      {:ok, item} = ok ->
        # Reading drops a row from `unread_scope/1` (the badge count and the
        # `/inbox` list), yet it mutates neither via an add/dismiss event —
        # this used to be a SILENT mutation the live badge missed. Broadcast a
        # coarse `{:inbox_changed, user_id}` so every mounted shell recomputes
        # the badge from the DB and InboxLive re-derives its list. A cross-user
        # guard miss (`{:error, :not_found}`) broadcasts nothing.
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
  """
  @spec dismiss_by_source(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()}
  def dismiss_by_source(user_id, source_type, source_id) do
    now = DateTime.utc_now()

    {count, _} =
      Item
      |> where(
        [i],
        i.user_id == ^user_id and i.source_type == ^source_type and
          i.source_id == ^source_id and is_nil(i.dismissed_at)
      )
      |> Repo.update_all(set: [dismissed_at: now])

    # Source-keyed dismissal is another silent mutation the live badge used to
    # miss (it broadcast NOTHING). When it actually cleared rows, broadcast the
    # coarse `{:inbox_changed, user_id}` so shells recompute the badge and
    # InboxLive re-derives. A no-op (count 0) stays quiet.
    if count > 0, do: broadcast_changed(user_id)

    {:ok, count}
  end

  @doc """
  Lazy reconciler: dismiss any live review-attention row whose underlying task
  no longer has a pending review request for this user.

  Rowan's "simple & reliable" self-healing seam (no push coupling): rather than
  chase every resolution path to dismiss the rolled-up row, InboxLive calls
  this at load so a stale `review_request_pending` row (e.g. the last review
  resolved without the rollup dismiss firing, or an out-of-band resolution)
  drops off on next view. Only review-kind rows are considered — mentions,
  meetings and sponsor-assignment rows are untouched.

  Review rows key their source three ways historically: `task_review`
  (the per-task rollup, `source_id` = task id), plain `task`, or the legacy
  per-request `review_request` (`source_id` = request id). The task is resolved
  from each, then `Platform.Tasks.ReviewRequests.task_has_pending_reviews?/1`
  decides. Unresolvable rows (source row already gone) are left alone.
  """
  @spec reconcile_for_user(Ecto.UUID.t()) :: :ok
  def reconcile_for_user(user_id) when is_binary(user_id) do
    Repo.all(
      from(i in Item,
        where:
          i.user_id == ^user_id and is_nil(i.dismissed_at) and
            i.kind == "review_request_pending"
      )
    )
    |> Enum.each(fn item ->
      if review_row_stale?(item), do: mark_dismissed(item.id, user_id)
    end)

    :ok
  rescue
    _ -> :ok
  end

  def reconcile_for_user(_), do: :ok

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
