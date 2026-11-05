defmodule Platform.Chat.DuplicateGroups do
  @moduledoc """
  Finds live unnamed groups that duplicate each other (same current members)
  and, on request, folds each duplicate set into one group (task 01a1acea,
  stage 2). Since stage 1, `Platform.Chat.create_group_conversation/3`
  reopens the matching group instead of inserting a second one; this module
  cleans up the duplicates created before that.

  Driven by `mix platform.merge_duplicate_groups` (report by default,
  `--apply` to merge). It is an operator task and is never part of deploy:
  nothing in `Platform.Release`, a migration, a Dockerfile, an entrypoint
  script or a CI workflow calls it, and a test asserts that.

  ## Candidates and duplicate sets

  A candidate is a `chat_spaces` row with `kind: "group"`, `is_direct:
  false`, `archived_at: nil` and a nil or blank `name`. Its member set is
  its current `"user"` and `"agent"` participant rows (other participant
  types are ignored, as in stage 1), keyed with
  `Platform.Chat.group_member_set_lock_key/1`. A duplicate set is any key
  shared by two or more candidates. Named groups, archived groups, promoted
  groups (now `kind: "channel"`) and DMs are never candidates.

  ## Keeper

  The space with the latest message (max `chat_messages.inserted_at`), ties
  and empty spaces broken by the later space `inserted_at`, then the higher
  id. This is the order `create_group_conversation/3` uses to pick among
  existing duplicates, so a start after the merge lands on the keeper, and
  a start before it already did.

  ## Merge (`apply/0`)

  Each duplicate set is merged in its own transaction whose first statement
  is `pg_advisory_xact_lock(hashtextextended(key, 0))` on the same key
  `create_group_conversation/3` locks, so a group start for that set cannot
  interleave with the merge. Inside the lock the set is re-read, so a set
  that changed since the scan is merged as it now is (or skipped).

  For each loser, in order:

    * every loser participant referenced by a moved row is mapped to the
      keeper's participant row with the same `participant_type` /
      `participant_id`. That row exists for every user and agent, since the
      sets are equal; for any other type (system, broadcast) it is created
      on the keeper only if absent, copying the identity snapshot.
    * `chat_messages`: `space_id` moves to the keeper, `participant_id` and
      `frozen_by_participant_id` are remapped. `inserted_at` and the
      `author_*` snapshot columns are untouched, so the keeper's timeline
      interleaves both groups in their original order.
    * `chat_reactions` follow their message by `message_id`; their
      `participant_id` is remapped.
    * `chat_message_attentions` follow their message by `message_id`; their
      `participant_id` and `added_by_participant_id` are remapped.
    * `chat_threads`: `space_id` moves.
    * `chat_pins`: `space_id` moves and `pinned_by` is remapped. A pin whose
      message the keeper already has pinned is skipped and counted; it
      stays on the archived loser. (The table has no unique index beyond
      its primary key today, so this is the only collision that could
      duplicate a pin.)
    * `chat_attachments`: `space_id` moves.
    * `chat_canvases`: `space_id` moves and `created_by` is remapped. This
      goes beyond the ticket's list: moved messages reference canvases by
      `canvas_id`, and leaving the canvas behind would point the keeper's
      timeline into an archived space.
    * the loser is archived with `Platform.Chat.archive_space/1`.

  Nothing is deleted: no space, message or participant row. The loser
  keeps its participant rows, so it stays readable to its members as an
  archived space.

  A second `apply/0` finds no duplicate set (every loser is archived) and
  changes no row.

  ## Every table keyed to `chat_spaces`

  From `references(:chat_spaces` in `priv/repo/migrations` (and the live
  foreign keys):

    * `chat_messages.space_id` — moved
    * `chat_threads.space_id` — moved
    * `chat_pins.space_id` — moved (collisions skipped and counted)
    * `chat_attachments.space_id` — moved
    * `chat_canvases.space_id` — moved
    * `chat_participants.space_id` — left; the loser keeps its rows, and
      their read cursors (`last_read_message_id`) and attention settings
      stay with the archived loser
    * `chat_space_agents.space_id`, `chat_attention_state.space_id` — tables
      since dropped by the roster unification; nothing to do
    * `task_router_assignments.execution_space_id` — table since dropped
    * `review_requests.execution_space_id` — left (execution spaces are
      channels, never groups)
    * `meetings.chat_space_id`, `meeting_rooms.space_id`,
      `meeting_recordings.space_id`, `meeting_invites.delivery_space_id` —
      left; a meeting stays with the space it was held in
    * `memory_briefings.space_id` — left
    * `access_space_restrictions.space_id`, `access_change_proposals.space_id`
      — left; access state is not merged
    * `federation_shared_spaces.local_space_id` — left
    * `mail_accounts.inbound_space_id` — left
    * `prototypes.space_id` — left
    * `calendar_events.space_id` — left

  Rows keyed to a moved message or thread rather than to the space
  (`chat_message_versions`, `chat_thread_reads`, `federation_message_links`,
  `mail_inbound_messages`) follow it by id and are not rewritten;
  `chat_thread_reads.participant_id` and
  `chat_message_versions.edited_by_participant_id` keep pointing at the
  loser's (still existing) participant rows.
  """

  import Ecto.Query

  alias Platform.Chat

  alias Platform.Chat.{
    Attachment,
    Canvas,
    Message,
    MessageAttention,
    Participant,
    Pin,
    Reaction,
    Space,
    Thread
  }

  alias Platform.Repo

  @member_types ["user", "agent"]

  @type space_summary :: %{
          id: binary(),
          message_count: non_neg_integer(),
          latest_message_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  @type duplicate_set :: %{
          key: String.t(),
          size: pos_integer(),
          keeper_id: binary(),
          loser_ids: [binary()],
          spaces: [space_summary()]
        }

  @type merge_counts :: %{
          messages: non_neg_integer(),
          reactions: non_neg_integer(),
          attentions: non_neg_integer(),
          threads: non_neg_integer(),
          pins: non_neg_integer(),
          pins_skipped: non_neg_integer(),
          attachments: non_neg_integer(),
          canvases: non_neg_integer(),
          participants_created: non_neg_integer(),
          archived: non_neg_integer()
        }

  @doc """
  Every duplicate set, keeper first in `spaces`. Writes nothing.

  Returns `%{sets: [duplicate_set], total_sets: n, total_losers: n}`.
  """
  @spec report() :: %{
          sets: [duplicate_set()],
          total_sets: non_neg_integer(),
          total_losers: non_neg_integer()
        }
  def report do
    sets = duplicate_sets()

    %{
      sets: sets,
      total_sets: length(sets),
      total_losers: sets |> Enum.map(&length(&1.loser_ids)) |> Enum.sum()
    }
  end

  @doc """
  Merge every duplicate set into its keeper, one locked transaction per set.

  Returns `%{sets: [duplicate_set + %{counts: merge_counts}], total_sets: n,
  totals: merge_counts}`. A set whose transaction fails is reported with
  `error:` instead of `counts:` and leaves no partial merge.
  """
  @spec apply() :: %{
          sets: [map()],
          total_sets: non_neg_integer(),
          totals: merge_counts()
        }
  def apply do
    results =
      duplicate_sets()
      |> Enum.map(fn set -> {set.key, merge_set(set.key)} end)
      |> Enum.flat_map(fn
        {_key, {:ok, nil}} -> []
        {_key, {:ok, merged}} -> [merged]
        {key, {:error, reason}} -> [%{key: key, error: reason}]
      end)

    totals =
      results
      |> Enum.filter(&Map.has_key?(&1, :counts))
      |> Enum.reduce(zero_counts(), fn %{counts: c}, acc ->
        Map.merge(acc, c, fn _k, a, b -> a + b end)
      end)

    %{sets: results, total_sets: length(results), totals: totals}
  end

  # ── Scan ──────────────────────────────────────────────────────────────────

  defp duplicate_sets do
    candidate_query()
    |> spaces_by_key()
    |> Enum.filter(fn {_key, ids} -> length(ids) >= 2 end)
    |> Enum.map(fn {key, ids} -> describe_set(key, ids) end)
    |> Enum.sort_by(& &1.key)
  end

  defp candidate_query do
    from(s in Space,
      where:
        s.kind == "group" and s.is_direct == false and is_nil(s.archived_at) and
          (is_nil(s.name) or fragment("btrim(?)", s.name) == "")
    )
  end

  # %{key => [space_id]} for the candidate spaces in `space_query`.
  defp spaces_by_key(space_query) do
    from(p in Participant,
      join: s in subquery(space_query),
      on: s.id == p.space_id,
      where: p.participant_type in @member_types,
      select: {p.space_id, p.participant_type, p.participant_id}
    )
    |> Repo.all()
    |> Enum.group_by(fn {space_id, _, _} -> space_id end, fn {_, t, id} -> {t, id} end)
    |> Enum.group_by(
      fn {_space_id, members} -> Chat.group_member_set_lock_key(members) end,
      fn {space_id, _members} -> space_id end
    )
  end

  # Spaces of one set, keeper first, in the order stage 1 picks among
  # duplicates: latest message, then later inserted_at, then higher id.
  defp describe_set(key, space_ids) do
    spaces =
      from(s in Space,
        where: s.id in ^space_ids,
        left_join: m in Message,
        on: m.space_id == s.id,
        group_by: s.id,
        order_by: [
          desc_nulls_last: max(m.inserted_at),
          desc: s.inserted_at,
          desc: s.id
        ],
        select: %{
          id: s.id,
          message_count: count(m.id),
          latest_message_at: max(m.inserted_at),
          inserted_at: s.inserted_at
        }
      )
      |> Repo.all()

    [keeper | losers] = spaces

    %{
      key: key,
      size: key |> String.replace_prefix("chat:group_member_set:", "") |> member_count(),
      keeper_id: keeper.id,
      loser_ids: Enum.map(losers, & &1.id),
      spaces: spaces
    }
  end

  defp member_count(""), do: 0
  defp member_count(joined), do: joined |> String.split(",") |> length()

  # ── Merge ─────────────────────────────────────────────────────────────────

  defp merge_set(key) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])

      # Re-read under the lock: a start or a leave may have changed the set
      # since the scan.
      case Map.get(spaces_by_key(candidate_query()), key, []) do
        ids when length(ids) >= 2 ->
          set = describe_set(key, ids)
          counts = Enum.reduce(set.loser_ids, zero_counts(), &merge_loser(&1, set.keeper_id, &2))
          Map.put(set, :counts, counts)

        _ ->
          nil
      end
    end)
  end

  defp merge_loser(loser_id, keeper_id, acc) do
    {pmap, created} = participant_map(loser_id, keeper_id)
    loser_message_ids = from(m in Message, where: m.space_id == ^loser_id, select: m.id)

    # Child rows of the loser's messages first, while they are still
    # findable by space.
    reactions = remap(Reaction, :participant_id, pmap, message_id: loser_message_ids)

    attentions =
      remap(MessageAttention, :participant_id, pmap, message_id: loser_message_ids) +
        remap(MessageAttention, :added_by_participant_id, pmap, message_id: loser_message_ids)

    _ = remap(Message, :frozen_by_participant_id, pmap, space_id: loser_id)
    _ = remap(Message, :participant_id, pmap, space_id: loser_id)

    {messages, _} =
      from(m in Message, where: m.space_id == ^loser_id)
      |> Repo.update_all(set: [space_id: keeper_id])

    {threads, _} =
      from(t in Thread, where: t.space_id == ^loser_id)
      |> Repo.update_all(set: [space_id: keeper_id])

    {pins, pins_skipped} = move_pins(loser_id, keeper_id, pmap)

    {attachments, _} =
      from(a in Attachment, where: a.space_id == ^loser_id)
      |> Repo.update_all(set: [space_id: keeper_id])

    _ = remap(Canvas, :created_by, pmap, space_id: loser_id)

    {canvases, _} =
      from(c in Canvas, where: c.space_id == ^loser_id)
      |> Repo.update_all(set: [space_id: keeper_id])

    [loser] = Repo.all(from(s in Space, where: s.id == ^loser_id))

    case Chat.archive_space(loser) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback({:archive_failed, loser_id, reason})
    end

    Map.merge(
      acc,
      %{
        messages: messages,
        reactions: reactions,
        attentions: attentions,
        threads: threads,
        pins: pins,
        pins_skipped: pins_skipped,
        attachments: attachments,
        canvases: canvases,
        participants_created: created,
        archived: 1
      },
      fn _k, a, b -> a + b end
    )
  end

  # %{loser_participant_id => keeper_participant_id} for every loser row.
  # A keeper row is created only when none exists for that type and id.
  defp participant_map(loser_id, keeper_id) do
    keeper_rows =
      from(p in Participant, where: p.space_id == ^keeper_id)
      |> Repo.all()
      |> Map.new(&{{&1.participant_type, &1.participant_id}, &1.id})

    from(p in Participant, where: p.space_id == ^loser_id)
    |> Repo.all()
    |> Enum.reduce({%{}, 0}, fn loser_p, {map, created} ->
      case Map.fetch(keeper_rows, {loser_p.participant_type, loser_p.participant_id}) do
        {:ok, keeper_pid} ->
          {Map.put(map, loser_p.id, keeper_pid), created}

        :error ->
          keeper_p =
            %Participant{}
            |> Participant.changeset(%{
              space_id: keeper_id,
              participant_type: loser_p.participant_type,
              participant_id: loser_p.participant_id,
              role: loser_p.role,
              display_name: loser_p.display_name,
              avatar_url: loser_p.avatar_url,
              joined_at: loser_p.joined_at || DateTime.utc_now()
            })
            |> Repo.insert!()

          {Map.put(map, loser_p.id, keeper_p.id), created + 1}
      end
    end)
  end

  # Rewrite `column` from each loser participant id to its keeper id, on the
  # rows of `schema` matching `scope` (`message_id: subquery` or
  # `space_id: id`). Returns the number of rows changed.
  defp remap(schema, column, pmap, scope) do
    Enum.reduce(pmap, 0, fn {from_id, to_id}, total ->
      {n, _} =
        schema
        |> scoped(scope)
        |> where([r], field(r, ^column) == ^from_id)
        |> Repo.update_all(set: [{column, to_id}])

      total + n
    end)
  end

  defp scoped(schema, message_id: ids),
    do: from(r in schema, where: r.message_id in subquery(ids))

  defp scoped(schema, space_id: id), do: from(r in schema, where: r.space_id == ^id)

  defp move_pins(loser_id, keeper_id, pmap) do
    keeper_pinned =
      from(p in Pin, where: p.space_id == ^keeper_id, select: p.message_id)
      |> Repo.all()
      |> MapSet.new()

    loser_pins = Repo.all(from(p in Pin, where: p.space_id == ^loser_id))

    {movable, colliding} =
      Enum.split_with(loser_pins, &(not MapSet.member?(keeper_pinned, &1.message_id)))

    movable_ids = Enum.map(movable, & &1.id)

    Enum.each(pmap, fn {from_id, to_id} ->
      from(p in Pin, where: p.id in ^movable_ids and p.pinned_by == ^from_id)
      |> Repo.update_all(set: [pinned_by: to_id])
    end)

    {moved, _} =
      from(p in Pin, where: p.id in ^movable_ids)
      |> Repo.update_all(set: [space_id: keeper_id])

    {moved, length(colliding)}
  end

  defp zero_counts do
    %{
      messages: 0,
      reactions: 0,
      attentions: 0,
      threads: 0,
      pins: 0,
      pins_skipped: 0,
      attachments: 0,
      canvases: 0,
      participants_created: 0,
      archived: 0
    }
  end
end
