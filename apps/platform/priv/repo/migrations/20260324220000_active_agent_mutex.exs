defmodule Platform.Repo.Migrations.ActiveAgentMutex do
  use Ecto.Migration

  def change do
    # ── Add new mutex columns to chat_spaces ─────────────────────────────────
    alter table(:chat_spaces) do
      add(:primary_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:watch_enabled, :boolean, default: false, null: false)
    end

    # ── Remove deprecated attention columns from chat_spaces ─────────────────
    alter table(:chat_spaces) do
      remove(:agent_attention, :string, default: nil)
      remove(:attention_config, :map, default: %{})
    end

    # ── Drop deprecated chat_attention_state table (Stage 6 cleanup) ─────────
    drop_if_exists(table(:chat_attention_state))

    # ── Remove 'dismissed' SpaceAgent entries and drop dismissed columns ──────
    # Delete any dismissed roster entries
    execute(
      "DELETE FROM chat_space_agents WHERE role = 'dismissed'",
      "SELECT 1"
    )

    # Remove dismissed_by and dismissed_at columns (no longer needed)
    alter table(:chat_space_agents) do
      remove(:dismissed_by, :binary_id)
      remove(:dismissed_at, :utc_datetime_usec)
    end

    # ── Data migration: set watch_enabled=true for agent DMs ─────────────────
    # Agent DMs: kind='dm' spaces where one of the participants is an agent
    execute(
      """
      UPDATE chat_spaces
      SET watch_enabled = true
      WHERE kind = 'dm'
        AND id IN (
          SELECT DISTINCT space_id
          FROM chat_participants
          WHERE participant_type = 'agent' AND left_at IS NULL
        )
      """,
      "SELECT 1"
    )
  end
end
