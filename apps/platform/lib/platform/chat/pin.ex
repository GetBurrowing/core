defmodule Platform.Chat.Pin do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_pins" do
    field(:space_id, :binary_id)
    field(:message_id, :binary_id)
    field(:pinned_by, :binary_id)

    # Pinner identity snapshot (ADR 0038). Survives dismissal of the pinner.
    field(:pinned_by_display_name, :string)
    field(:pinned_by_participant_type, :string)

    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [
      :space_id,
      :message_id,
      :pinned_by,
      :pinned_by_display_name,
      :pinned_by_participant_type
    ])
    |> validate_required([:space_id, :message_id, :pinned_by])
  end
end
