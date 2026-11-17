defmodule Platform.Chat.MessageGroupSnapshot do
  use Ecto.Schema
  @primary_key {:message_id, :binary_id, autogenerate: false}
  schema "chat_message_group_snapshots" do
  end
end
