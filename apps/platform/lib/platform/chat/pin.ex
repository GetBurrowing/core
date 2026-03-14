defmodule Platform.Chat.Pin do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_pins" do
    field(:space_id, :binary_id)
    # message_id is an integer FK (chat_messages has bigserial PK).
    field(:message_id, :id)
    field(:pinned_by, :binary_id)

    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [:space_id, :message_id, :pinned_by])
    |> validate_required([:space_id, :message_id, :pinned_by])
  end
end
