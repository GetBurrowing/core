defmodule Platform.Repo.Migrations.CreateAgentUsageEvents do
  use Ecto.Migration

  def change do
    create table(:agent_usage_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:space_id, :binary_id)
      add(:agent_id, :binary_id)
      add(:participant_id, :binary_id)
      add(:triggered_by, :binary_id)
      add(:model, :string)
      add(:provider, :string)
      add(:input_tokens, :integer, default: 0)
      add(:output_tokens, :integer, default: 0)
      add(:cache_read_tokens, :integer, default: 0)
      add(:cache_write_tokens, :integer, default: 0)
      add(:total_tokens, :integer, default: 0)
      add(:cost_usd, :float)
      add(:latency_ms, :integer)
      add(:tool_calls, {:array, :string}, default: [])
      add(:task_id, :string)
      add(:session_key, :string)
      add(:metadata, :map, default: %{})
      add(:inserted_at, :utc_datetime_usec)
    end

    create(index(:agent_usage_events, [:space_id, :inserted_at]))
    create(index(:agent_usage_events, [:agent_id, :inserted_at]))
    create(index(:agent_usage_events, [:inserted_at]))
  end
end
