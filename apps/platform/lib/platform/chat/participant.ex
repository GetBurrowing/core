defmodule Platform.Chat.Participant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @participant_types ~w(user agent)
  @roles ~w(member admin observer)
  @attention_modes ~w(mention heartbeat active)

  schema "chat_participants" do
    field(:space_id, :binary_id)
    field(:participant_type, :string)
    field(:participant_id, :binary_id)
    field(:role, :string, default: "member")
    field(:display_name, :string)
    field(:avatar_url, :string)
    field(:last_read_message_id, :integer)
    field(:attention_mode, :string, default: "mention")
    field(:attention_config, :map, default: %{})
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :space_id,
      :participant_type,
      :participant_id,
      :role,
      :display_name,
      :avatar_url,
      :last_read_message_id,
      :attention_mode,
      :attention_config,
      :joined_at,
      :left_at
    ])
    |> validate_required([:space_id, :participant_type, :participant_id, :role, :joined_at])
    |> validate_inclusion(:participant_type, @participant_types)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:attention_mode, @attention_modes)
    |> unique_constraint(:participant_id, name: :chat_participants_unique)
  end
end
