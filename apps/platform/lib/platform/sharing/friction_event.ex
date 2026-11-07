defmodule Platform.Sharing.FrictionEvent do
  @moduledoc """
  One occurrence of a friction fingerprint (task 01a1b678 stage 3); see
  `Platform.Sharing.Friction`. Holds the fingerprint, its kind and a bounded
  subject (a tool name plus an error code, or a question hash), never message
  text.
  """

  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "sharing_friction_events" do
    field(:fingerprint, :string)
    field(:kind, :string)
    field(:subject, :string)
    field(:agent_id, Ecto.UUID)
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
