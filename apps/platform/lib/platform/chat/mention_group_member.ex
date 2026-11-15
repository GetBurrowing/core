defmodule Platform.Chat.MentionGroupMember do
  use Ecto.Schema
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  schema "mention_group_members" do
    field(:group_id, :binary_id)
    field(:user_id, :binary_id)
    field(:agent_id, :binary_id)
  end

  def to_view(%{user_id: id}) when is_binary(id), do: %{type: "user", id: id}
  def to_view(%{agent_id: id}) when is_binary(id), do: %{type: "agent", id: id}
end
