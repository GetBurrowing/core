defmodule Platform.Chat.Space do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(channel dm group)
  @agent_attention_modes ~w(on_mention collaborative directed)

  schema "chat_spaces" do
    field(:workspace_id, :binary_id)
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:kind, :string, default: "channel")
    field(:topic, :string)
    field(:metadata, :map, default: %{})
    field(:agent_attention, :string)
    field(:attention_config, :map, default: %{})
    field(:is_direct, :boolean, default: false)
    field(:created_by, :binary_id)
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
      :agent_attention,
      :attention_config,
      :is_direct,
      :created_by,
      :archived_at
    ])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:agent_attention, @agent_attention_modes)
    |> validate_channel_fields()
    |> validate_is_direct()
    |> unique_constraint(:slug, name: :chat_spaces_unique_slug)
  end

  defp validate_channel_fields(changeset) do
    kind = get_field(changeset, :kind)

    if kind == "channel" do
      changeset
      |> validate_required([:name, :slug])
    else
      changeset
    end
  end

  defp validate_is_direct(changeset) do
    is_direct = get_field(changeset, :is_direct)
    kind = get_field(changeset, :kind)

    if is_direct && kind != "dm" do
      add_error(changeset, :is_direct, "can only be true when kind is dm")
    else
      changeset
    end
  end
end
