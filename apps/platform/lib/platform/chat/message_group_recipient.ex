defmodule Platform.Chat.MessageGroupRecipient do
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  schema "chat_message_group_recipients" do
    field(:message_id, :binary_id)
    field(:principal_type, :string)
    field(:principal_id, :binary_id)
    field(:participant_id, :binary_id)
    field(:group_ids, {:array, :binary_id}, default: [])
  end
end
