defmodule Platform.Repo.Migrations.CreateDispatchToolCalls do
  @moduledoc """
  Task 01a114a8 stage 1: one row per federated tool call, written by
  `Platform.Federation.ToolCallLedger`.

  No foreign keys on purpose. The ledger is observational: a row must not
  block deleting a task, stage or runtime, and a call naming an id that does
  not exist is still a call that happened. There is no column for arguments,
  results or script text.
  """
  use Ecto.Migration

  def change do
    create table(:dispatch_tool_calls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:runtime_id, :text, null: false)
      add(:agent_id, :binary_id)
      add(:tool, :text, null: false)
      add(:status, :text, null: false)
      add(:duration_ms, :integer)
      add(:result_bytes, :bigint)
      add(:task_id, :binary_id)
      add(:stage_id, :binary_id)
      add(:lease_id, :binary_id)
      add(:attribution, :text, null: false)
      add(:parent_run_id, :binary_id)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:dispatch_tool_calls, [:task_id, :stage_id]))
    create(index(:dispatch_tool_calls, [:runtime_id, :inserted_at]))
    create(index(:dispatch_tool_calls, [:parent_run_id]))
  end
end
