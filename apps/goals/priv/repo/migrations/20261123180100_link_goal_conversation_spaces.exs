defmodule Platform.Repo.Migrations.LinkGoalConversationSpaces do
  @moduledoc """
  Task 01a20939 stage 1: links every goal confirmed from a New goal
  conversation before this release to that conversation's space, so the
  goal's onboarding is the first history in its own conversation
  (`Platform.Goals.Conversation`). From this release on,
  `Platform.Goals.Proposals.confirm_proposal/3` links it in the confirm's
  own transaction.

  For each `goal_proposals` row with status `confirmed` and `goal_id` set,
  whose goal has no `conversation_space_id` yet:

    1. `goals.conversation_space_id` is set to the proposal's `space_id`;
    2. `{"goal_id": <goal id>}` is merged into that space's `metadata`.

  A space already linked to another goal is skipped (the unique index would
  refuse it). Goals with no proposal (seeded, handed off, or created with
  `Platform.Goals.create_goal/2` directly) are left alone: they get their
  space lazily, through `Platform.Goals.Conversation.ensure_space/1`.

  The space's participants are not touched: a proposal's space already holds
  exactly the person and the agent, who became the goal's owner and coach at
  confirm. No goal_grants row is written for the space, ever.

  Plain SQL only (no application schema, no `Platform.Chat` call), so
  nothing is broadcast, no telemetry fires and nothing routes to an agent.

  Idempotent: a linked goal no longer has a NULL `conversation_space_id`, so
  a second run matches nothing. `down/0` is a documented no-op: the column
  itself is dropped by rolling back 20261123180000.

  `link_all/1` is the whole of `up/0` taking the repo as an argument, so the
  test can drive it inside the SQL sandbox.
  """
  use Ecto.Migration

  # old-code-compatible: sets goals.conversation_space_id (added by 20261123180000) and merges one key into chat_spaces.metadata; no column, constraint or type changes, and the previous release reads neither
  def up, do: link_all(repo())

  # Deliberate no-op: see the moduledoc.
  def down, do: :ok

  @doc "Links every confirmed proposal's space to its goal. Returns how many goals were linked."
  def link_all(repo) do
    %{rows: rows} =
      repo.query!(
        """
        WITH linked AS (
          UPDATE goals g
          SET conversation_space_id = p.space_id
          FROM goal_proposals p
          WHERE p.goal_id = g.id
            AND p.status = 'confirmed'
            AND p.space_id IS NOT NULL
            AND g.conversation_space_id IS NULL
            AND NOT EXISTS (
              SELECT 1 FROM goals other WHERE other.conversation_space_id = p.space_id
            )
          RETURNING g.id AS goal_id, p.space_id AS space_id
        ),
        tagged AS (
          UPDATE chat_spaces s
          SET metadata = COALESCE(s.metadata, '{}'::jsonb)
                           || jsonb_build_object('goal_id', l.goal_id::text)
          FROM linked l
          WHERE s.id = l.space_id
          RETURNING s.id
        )
        SELECT l.goal_id FROM linked l
        """,
        [],
        log: false
      )

    length(rows)
  end
end
