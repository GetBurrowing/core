defmodule Platform.Repo.Migrations.MoveGoalProposalsOutOfDms do
  @moduledoc """
  Task 01a1eab6 stage 4: every `goal_proposals` row written before stage 2
  points `space_id` at the person's real DM with the lead agent
  (`chat_spaces.kind = 'dm' AND is_direct = true`), so the New goal
  conversation showed the DM's turns and the DM showed the goal's. Stage 2
  gives each new proposal its own space; this moves the existing rows.

  For each proposal on such a DM, whatever its status:

    1. a new `chat_spaces` row: kind `dm`, `is_direct` false, name
       "New goal", the DM's org_id and workspace_id, `created_by` the
       proposal's user, metadata
       `{"surface": "goals", "migrated_from_space_id": <dm id>}` (core's
       generic "owned by another surface" marker; no `goals_*` key);
    2. two `chat_participants` rows, the person and the agent, copying
       display_name, participant_type, participant_id, attention_mode and
       joined_at from the DM's rows;
    3. a COPY of the opening message (`first_message_id`) in the new space:
       content, content_type, structured_content, the author snapshot
       columns and inserted_at (chat_messages has no updated_at), authored by
       the new person participant, metadata the original's plus
       `"copied_from_message_id"`; plus its `chat_message_versions` v1 row,
       as `Platform.Chat.MessageVersions.record_v1!/1` writes for every post;
    4. the proposal's `space_id` and `first_message_id` repointed at the
       copies.

  ONLY the opening message is copied. Messages written before the fix carry
  no marker separating a Goals turn from a DM turn, and copying DM turns
  into the goal's space is the very leak this task closes. The person's and
  the agent's later goal turns stay in the DM, where they already were.

  The DM is never written: no DM space, participant or message row is
  updated or deleted. Plain SQL only (no application schema, no
  `Platform.Chat.post_message/2`), so nothing is broadcast, no telemetry
  fires and nothing routes to the agent. The agent is re-signalled once,
  separately, by `Platform.Goals.Proposals.resend_start_signal/1`.

  Idempotent: a moved proposal points at a space that is not `is_direct`, so
  a second run matches nothing. `down/0` is a documented no-op: undoing it
  would point the proposals back at the DM, which is the bug.

  `move_all/1` is the whole of `up/0` taking the repo as an argument, so the
  test can drive it inside the SQL sandbox.
  """
  use Ecto.Migration

  # old-code-compatible: inserts new chat rows and repoints goal_proposals.space_id/first_message_id at them; no column, constraint or type changes, and the previous release reads a proposal's space the same way
  def up, do: move_all(repo())

  # Deliberate no-op: see the moduledoc.
  def down, do: :ok

  @doc "Moves every proposal still on a direct DM. Returns how many moved."
  def move_all(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT p.id, p.user_id, p.agent_id, p.first_message_id, s.id
        FROM goal_proposals p
        JOIN chat_spaces s ON s.id = p.space_id
        WHERE s.kind = 'dm' AND s.is_direct = true
        ORDER BY p.inserted_at, p.id
        """,
        [],
        log: false
      )

    Enum.each(rows, &move(repo, &1))
    length(rows)
  end

  defp move(repo, [proposal_id, user_id, agent_id, first_message_id, dm_id]) do
    space_id = one(repo, "SELECT #{uuidv7()}")

    repo.query!(
      """
      INSERT INTO chat_spaces
        (id, workspace_id, name, kind, is_direct, org_id, created_by, metadata,
         inserted_at, updated_at)
      SELECT $1::uuid, d.workspace_id, 'New goal', 'dm', false, d.org_id, $2::uuid,
             jsonb_build_object('surface', 'goals', 'migrated_from_space_id', d.id::text),
             now(), now()
      FROM chat_spaces d
      WHERE d.id = $3::uuid
      """,
      [space_id, user_id, dm_id],
      log: false
    )

    user_participant = copy_participant(repo, space_id, dm_id, "user", user_id)
    _agent_participant = copy_participant(repo, space_id, dm_id, "agent", agent_id)

    message_id = copy_opening(repo, space_id, user_participant, first_message_id)

    repo.query!(
      "UPDATE goal_proposals SET space_id = $1::uuid, first_message_id = $2::uuid, " <>
        "updated_at = now() WHERE id = $3::uuid",
      [space_id, message_id || first_message_id, proposal_id],
      log: false
    )
  end

  # The DM's own row is copied when it exists; a DM missing one of the two
  # (it never should) still gets a participant, named from the user or agent.
  defp copy_participant(repo, space_id, dm_id, type, id) do
    one(
      repo,
      """
      INSERT INTO chat_participants
        (id, space_id, participant_type, participant_id, display_name,
         attention_mode, joined_at)
      SELECT #{uuidv7()}, $1::uuid, $3::text, $4::uuid,
             COALESCE(dp.display_name,
                      CASE WHEN $3::text = 'user'
                           THEN (SELECT COALESCE(u.name, u.email) FROM users u WHERE u.id = $4::uuid)
                           ELSE (SELECT a.name FROM agents a WHERE a.id = $4::uuid) END),
             COALESCE(dp.attention_mode, 'mention'),
             COALESCE(dp.joined_at, now())
      FROM (SELECT 1) one
      LEFT JOIN chat_participants dp
        ON dp.space_id = $2::uuid AND dp.participant_type = $3::text
       AND dp.participant_id = $4::uuid
      RETURNING id
      """,
      [space_id, dm_id, type, id]
    )
  end

  # nil when the opening message row is gone: the proposal still moves, with
  # an empty conversation, rather than staying on the DM.
  defp copy_opening(repo, space_id, participant_id, first_message_id) do
    message_id =
      one(
        repo,
        """
        INSERT INTO chat_messages
          (id, space_id, participant_id, content_type, content, structured_content,
           metadata, author_display_name, author_avatar_url, author_participant_type,
           author_agent_id, author_user_id, inserted_at)
        SELECT #{uuidv7()}, $1::uuid, $2::uuid, m.content_type, m.content, m.structured_content,
               COALESCE(m.metadata, '{}'::jsonb)
                 || jsonb_build_object('copied_from_message_id', m.id::text),
               m.author_display_name, m.author_avatar_url, m.author_participant_type,
               m.author_agent_id, m.author_user_id, m.inserted_at
        FROM chat_messages m
        WHERE m.id = $3::uuid
        RETURNING id
        """,
        [space_id, participant_id, first_message_id]
      )

    if message_id do
      repo.query!(
        """
        INSERT INTO chat_message_versions
          (id, message_id, version_number, content, edited_at,
           edited_by_participant_id, edited_by_display_name, inserted_at)
        SELECT #{uuidv7()}, m.id, 1, COALESCE(m.content, ''), m.inserted_at,
               m.participant_id, COALESCE(m.author_display_name, '(unknown)'), now()
        FROM chat_messages m
        WHERE m.id = $1::uuid
        ON CONFLICT (message_id, version_number) DO NOTHING
        """,
        [message_id],
        log: false
      )
    end

    message_id
  end

  defp one(repo, sql, params \\ []) do
    case repo.query!(sql, params, log: false) do
      %{rows: [[value]]} -> value
      %{rows: []} -> nil
    end
  end

  # A UUIDv7 minted in SQL (millisecond clock in the first 48 bits, version
  # nibble 7), as 20261026010000_create_chat_thread_reads does: PostgreSQL 16
  # has no uuidv7(), and core's chat ids are UUIDv7.
  defp uuidv7 do
    """
    encode(set_bit(set_bit(overlay(uuid_send(gen_random_uuid())
      placing substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
      FROM 1 FOR 6), 52, 1), 53, 1), 'hex')::uuid
    """
  end
end
