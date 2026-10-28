defmodule Platform.Meetings.CompletionRun do
  @moduledoc "Durable identity and item ledger for a meeting's final triage."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "meeting_completion_runs" do
    belongs_to(:meeting, Platform.Meetings.Meeting)
    field(:transcript_id, :binary_id)
    field(:canvas_id, :binary_id)
    field(:status, :string, default: "waiting")
    field(:snapshot, :map, default: %{})
    field(:snapshot_hash, :string)
    field(:item_results, :map, default: %{})
    field(:last_error, :string)
    field(:dispatched_at, :utc_datetime_usec)
    field(:capture_finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
