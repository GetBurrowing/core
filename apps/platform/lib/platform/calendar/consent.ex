defmodule Platform.Calendar.Consent do
  @moduledoc "Durable Calendar intent, tentative reservation and versioned inverse."
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "calendar_consents" do
    field(:owner_id, :binary_id)
    field(:agent_id, :binary_id)
    field(:grant_id, :binary_id)
    field(:briefing_id, :binary_id)
    field(:event_id, :binary_id)
    field(:hold_id, :binary_id)
    field(:request_key, :string)
    field(:operation, :string)
    field(:state, :string, default: "pending")
    field(:prior, :map, default: %{})
    field(:target_sequence, :integer)
    field(:committed_sequence, :integer)
    timestamps(type: :utc_datetime_usec)
  end
end
