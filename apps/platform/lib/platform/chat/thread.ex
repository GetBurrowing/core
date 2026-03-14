defmodule Platform.Chat.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_threads" do
    field(:space_id, :binary_id)
    field(:parent_message_id, :integer)
    field(:title, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:space_id, :parent_message_id, :title, :metadata])
    |> validate_required([:space_id])
  end
end
