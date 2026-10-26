defmodule Platform.Chat.ThreadActivity do
  @moduledoc """
  The per-thread read cursor and the thread-activity rule behind the main
  log's "↳ N new replies to …" row (task 01a174f5 stage 1). Reached through
  `Platform.Chat.mark_thread_read/3`, `Platform.Chat.thread_activity_for/2`
  and `Platform.Chat.thread_activity_entry/2`.

  ## The rule

  A thread is ACTIVE for a viewer when it has at least one reply that is:

    * newer than the viewer's cursor on that thread (`chat_thread_reads`), or,
      with no cursor, newer than the first UUIDv7 of the viewer's `joined_at`
      millisecond, so history from before the viewer joined never counts;
    * not the viewer's own (your own replies never create a row);
    * not deleted;
    * at or after the viewer's `history_visible_from`, when that is set;
    * in a space the `:scope` lets the caller read (the external gate
      `Chat.list_thread_summaries/2` uses).

  A thread whose parent message is deleted is never active.

  ## The cursor

  `mark_thread_read/3` only ever advances. Opening the thread marks its
  latest reply, which removes the thread from `thread_activity_for/2`; the
  next reply from someone else brings it back with a count of 1.

  An advancing write broadcasts `{:thread_read, %{participant_id, thread_id,
  last_read_message_id}}` on `Platform.Chat.PubSub.thread_reads_topic/1`, the
  viewer's own topic. Deliberately not `chat:space:*`: every viewer of a space
  subscribes that, and none of them needs another member's read state.
  """

  import Ecto.Query

  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Thread
  alias Platform.Chat.ThreadRead
  alias Platform.Repo

  @limit 50

  @type entry :: %{
          thread_id: binary(),
          parent_message_id: binary(),
          new_count: pos_integer(),
          latest_reply_id: binary(),
          latest_participant_id: binary() | nil
        }

  @doc """
  Advance `participant_id`'s cursor on `thread_id` to `message_id`.

  A no-op when the stored cursor is already at or past `message_id`; the
  guard is the `WHERE` on the upsert's conflict update, so it also holds
  against a concurrent writer. Broadcasts `{:thread_read, ...}` only after
  a write that moved the cursor.
  """
  @spec mark_thread_read(binary(), binary(), binary()) :: :ok | {:error, :invalid_id}
  def mark_thread_read(participant_id, thread_id, message_id) do
    with {:ok, participant_id} <- cast(participant_id),
         {:ok, thread_id} <- cast(thread_id),
         {:ok, message_id} <- cast(message_id) do
      now = DateTime.utc_now()

      conflict_update =
        from(tr in ThreadRead,
          where: is_nil(tr.last_read_message_id) or tr.last_read_message_id < ^message_id,
          update: [set: [last_read_message_id: ^message_id, updated_at: ^now]]
        )

      {written, _} =
        Repo.insert_all(
          ThreadRead,
          [
            %{
              id: Platform.Types.UUIDv7.generate(),
              participant_id: participant_id,
              thread_id: thread_id,
              last_read_message_id: message_id,
              inserted_at: now,
              updated_at: now
            }
          ],
          on_conflict: conflict_update,
          conflict_target: [:participant_id, :thread_id]
        )

      if written > 0 do
        ChatPubSub.broadcast_thread_read(participant_id, %{
          participant_id: participant_id,
          thread_id: thread_id,
          last_read_message_id: message_id
        })
      end

      :ok
    else
      :error -> {:error, :invalid_id}
    end
  end

  @doc """
  The viewer's active threads in the viewer's space, oldest latest-unseen
  reply first (newest last, the order the log shows them), at most #{@limit}
  (the newest #{@limit} when there are more).

  Options: `:scope`, an external or access scope, as `list_thread_summaries/2`.
  """
  @spec thread_activity_for(Participant.t(), keyword()) :: [entry()]
  def thread_activity_for(%Participant{} = viewer, opts \\ []) do
    viewer
    |> entries_query(Keyword.get(opts, :scope))
    |> order_by([a], desc: a.latest_reply_id)
    |> limit(@limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  The same rule as `thread_activity_for/2` for one thread: its entry, or
  `nil` when the thread is not active for the viewer.
  """
  @spec thread_activity_entry(Participant.t(), binary(), keyword()) :: entry() | nil
  def thread_activity_entry(%Participant{} = viewer, thread_id, opts \\ []) do
    case cast(thread_id) do
      {:ok, thread_id} ->
        viewer
        |> entries_query(Keyword.get(opts, :scope), thread_id)
        |> Repo.one()

      :error ->
        nil
    end
  end

  # One row per thread (GROUP BY), joined back to its latest unseen reply for
  # the replier. The aggregate is built over `unseen_replies/3`, the single
  # definition of "a reply this viewer has not seen".
  defp entries_query(viewer, scope, thread_id \\ nil) do
    aggregate =
      from(m in unseen_replies(viewer, scope, thread_id),
        group_by: m.thread_id,
        select: %{
          thread_id: m.thread_id,
          new_count: count(m.id),
          latest_reply_id: type(fragment("max(?::text)::uuid", m.id), Platform.Types.UUIDv7)
        }
      )

    from(a in subquery(aggregate),
      join: t in Thread,
      on: t.id == a.thread_id,
      join: lm in Message,
      on: lm.id == a.latest_reply_id,
      select: %{
        thread_id: a.thread_id,
        parent_message_id: t.parent_message_id,
        new_count: a.new_count,
        latest_reply_id: a.latest_reply_id,
        latest_participant_id: lm.participant_id
      }
    )
  end

  defp unseen_replies(%Participant{} = viewer, scope, thread_id) do
    baseline = baseline_id(viewer.joined_at)

    from(m in Message,
      join: t in Thread,
      on: t.id == m.thread_id,
      join: pm in Message,
      on: pm.id == t.parent_message_id and is_nil(pm.deleted_at),
      left_join: tr in ThreadRead,
      on: tr.thread_id == m.thread_id and tr.participant_id == ^viewer.id,
      # `m.space_id` alone: a reply takes its thread's space (`reply_to_thread/3`),
      # and chat_threads has no space_id index, so a second filter on
      # `t.space_id` turned the thread join into a seq scan (EXPLAIN, stage 1).
      where: m.space_id == ^viewer.space_id,
      where: not is_nil(m.thread_id) and is_nil(m.deleted_at),
      where: m.participant_id != ^viewer.id,
      where: m.id > coalesce(tr.last_read_message_id, type(^baseline, Platform.Types.UUIDv7))
    )
    |> only_thread(thread_id)
    |> bound_by_history(viewer.history_visible_from)
    |> ExternalScope.scope_by_space_id(scope)
  end

  defp only_thread(query, nil), do: query
  defp only_thread(query, thread_id), do: where(query, [m], m.thread_id == ^thread_id)

  defp bound_by_history(query, nil), do: query

  defp bound_by_history(query, %DateTime{} = from),
    do: where(query, [m], m.inserted_at >= ^from)

  # The smallest UUIDv7 in `joined_at`'s millisecond: every id minted at or
  # after the join sorts above it. A nil `joined_at` means no baseline.
  defp baseline_id(%DateTime{} = joined_at) do
    ms = DateTime.to_unix(joined_at, :millisecond)
    Ecto.UUID.load!(<<ms::unsigned-48, 7::4, 0::12, 2::2, 0::62>>)
  end

  defp baseline_id(nil), do: "00000000-0000-0000-0000-000000000000"

  # `Platform.UUID.cast/1`, not a bare `Ecto.UUID.cast/1`: the ids can come
  # from a LiveView event, and a bare cast accepts any 16-byte binary.
  defp cast(id) do
    case Platform.UUID.cast(id) do
      {:ok, uuid} -> {:ok, String.downcase(uuid)}
      :error -> :error
    end
  end
end
