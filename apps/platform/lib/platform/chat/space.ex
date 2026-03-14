defmodule Platform.Chat.Space do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(channel dm group)

  schema "chat_spaces" do
    field(:workspace_id, :binary_id)
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:kind, :string, default: "channel")
    field(:topic, :string)
    field(:metadata, :map, default: %{})
    field(:archived_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(space, attrs) do
    space
    |> cast(attrs, [
      :workspace_id,
      :name,
      :slug,
      :description,
      :kind,
      :topic,
      :metadata,
      :archived_at
    ])
    |> validate_required([:name, :slug, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:slug, name: :chat_spaces_unique_slug)
  end
end
