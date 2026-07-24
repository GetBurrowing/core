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
  Count a user's non-dismissed inbox items.

  A single aggregate query — the live-badge counterpart to
  `list_unread_for_user/2`, cheaper than materializing rows just to take a
  length. Scoping is inherent: only rows whose `user_id` matches are counted,
  so an external user's count is naturally limited to their own (allowlisted)
  rows without an extra scope filter.
  """
  @spec unread_count(Ecto.UUID.t()) :: non_neg_integer()
  def unread_count(user_id) do
    Repo.aggregate(
      from(i in Item, where: i.user_id == ^user_id and is_nil(i.dismissed_at)),
      :count
    )
  end

  @doc """
  Mark an item read for `user_id`.

  The `user_id` is a defensive cross-user guard: the update is scoped by both
  `id` and `user_id`, so a mismatched user mutates nothing and gets
  `{:error, :not_found}`.
  """
  @spec mark_read(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def mark_read(item_id, user_id), do: set_timestamp(item_id, user_id, :read_at)

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

    {:ok, count}
  end

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
