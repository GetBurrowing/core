defmodule Platform.Repo.Migrations.AddAttentionRouting do
  use Ecto.Migration

  def change do
    alter table(:chat_spaces) do
      add(:agent_attention, :string, default: nil)
      add(:attention_config, :map, default: %{})
    end

    create table(:chat_attention_state, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :agent_participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:state, :string, null: false, default: "idle")
      add(:engaged_since, :utc_datetime_usec)
      add(:engaged_context, :text)
      add(:silenced_until, :utc_datetime_usec)
      add(:last_triage_at, :utc_datetime_usec)
      add(:triage_buffer_start_id, :binary_id)
      add(:metadata, :map, default: %{})
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      unique_index(:chat_attention_state, [:space_id, :agent_participant_id],
        name: :chat_attention_state_space_agent
      )
    )
  end
end
