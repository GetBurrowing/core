defmodule Platform.Chat.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(pending ready)

  schema "chat_attachments" do
    field(:space_id, :binary_id)
    field(:message_id, :binary_id)
    field(:canvas_id, :binary_id)
    field(:uploaded_by_agent_id, :binary_id)
    field(:filename, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:storage_key, :string)
    field(:content_hash, :string)
    field(:state, :string, default: "ready")
    field(:upload_expires_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :space_id,
      :message_id,
      :canvas_id,
      :uploaded_by_agent_id,
      :filename,
      :content_type,
      :byte_size,
      :storage_key,
      :content_hash,
      :state,
      :upload_expires_at,
      :metadata
    ])
    |> validate_required([:filename, :content_type, :byte_size, :storage_key])
    |> validate_inclusion(:state, @states)
  end
end
