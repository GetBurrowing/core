defmodule Platform.Repo.Migrations.UnifyParticipantRoster do
  @moduledoc """
  ADR 0038 Phase 5. Collapse `chat_space_agents` into `chat_participants`.

  The two tables were parallel models of "is this agent in this space?"
  (ADR 0019 added the roster table to represent principals, but it
  quietly became load-bearing for mention gating). The split-brain
  already cost us the dismissal bug the other phases fixed; eliminating
  the second table is the last step that makes the single-source model
  stick.

  `chat_participants.role` already holds member/admin/observer for user
  participants. Extend it with `principal` and backfill from
  `chat_space_agents.role` for agent rows. Drop the `chat_space_agents`
  table.

  `chat_spaces.primary_agent_id` already exists (added 20260324220000)
  and is the canonical reference to the space's principal agent, so
  rebuilding a roster is trivial if ever needed.
  """
  use Ecto.Migration

  def up do
    # Backfill participant.role = 'principal' for agents whose roster
    # entry marked them principal. The roster table has a unique
    # (space_id, role=principal) so at most one per space.
    execute("""
    UPDATE chat_participants p
    SET role = sa.role
    FROM chat_space_agents sa
    WHERE sa.space_id = p.space_id
      AND sa.agent_id = p.participant_id
      AND p.participant_type = 'agent'
      AND sa.role IN ('principal', 'member')
    """)

    drop(table(:chat_space_agents))
  end

  def down do
    create table(:chat_space_agents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:space_id, :binary_id, null: false)
      add(:agent_id, :binary_id, null: false)
      add(:role, :text, null: false, default: "member")
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:chat_space_agents, [:space_id, :agent_id],
        name: :chat_space_agents_space_agent_unique
      )
    )

    create(
      unique_index(:chat_space_agents, [:space_id],
        where: "role = 'principal'",
        name: :chat_space_agents_principal_unique
      )
    )

    # Repopulate the roster from the participants table. Anything not
    # present as an agent participant is gone for good.
    execute("""
    INSERT INTO chat_space_agents (id, space_id, agent_id, role, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      p.space_id,
      p.participant_id,
      p.role,
      NOW(),
      NOW()
    FROM chat_participants p
    WHERE p.participant_type = 'agent'
    """)
  end
end
