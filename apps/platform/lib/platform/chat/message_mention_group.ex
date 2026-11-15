defmodule Platform.Chat.MessageMentionGroup do
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  schema "chat_message_mention_groups" do
    field(:message_id, :binary_id)
    field(:group_id, :binary_id)
    field(:name, :string)
  end
end
