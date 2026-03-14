defmodule Platform.Chat.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_attachments" do
    # message_id is an integer FK (chat_messages has bigserial PK).
    field(:message_id, :id)
    field(:filename, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:storage_key, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :message_id,
      :filename,
      :content_type,
      :byte_size,
      :storage_key,
      :metadata
    ])
    |> validate_required([:message_id, :filename, :content_type, :byte_size, :storage_key])
  end
end
