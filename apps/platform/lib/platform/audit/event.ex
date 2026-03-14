defmodule Platform.Audit.Event do
  @moduledoc """
  An immutable audit event. Append-only — never updated or deleted.

  Events are the primary data in the audit stream. Current state is
  always derivable by folding (`Enum.reduce/3`) over a sequence of events.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "audit_events" do
    field(:event_type, :string)
    field(:actor_id, Ecto.UUID)
    field(:actor_type, :string, default: "system")
    field(:resource_type, :string)
    field(:resource_id, :string)
    field(:action, :string)
    field(:metadata, :map, default: %{})
    field(:session_id, :string)
    field(:ip_address, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields ~w(event_type actor_type action)a
  @optional_fields ~w(actor_id resource_type resource_id metadata session_id ip_address)a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
