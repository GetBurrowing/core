defmodule Platform.Chat.Participant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  # "system" types the synthetic per-space TaskRouter participant minted by
  # `Platform.Orchestration.ExecutionSpace.ensure_system_participant/1`. It is
  # a distinct kind, not an agent: no `agents` row resolves it, so counting it
  # in an agent roster inflates every space health denominator. Rejected
  # alternative: a metadata flag or id prefix — every consumer would have to
  # remember a filter, and the ones that forget fail silently.
  @participant_types ~w(user agent system)
  @roles ~w(member admin observer principal)
  @attention_modes ~w(mention heartbeat active all)

  schema "chat_participants" do
    field(:space_id, :binary_id)
    field(:participant_type, :string)
    field(:participant_id, :binary_id)
    field(:role, :string, default: "member")
    field(:display_name, :string)
    field(:avatar_url, :string)
    field(:last_read_message_id, :binary_id)
    field(:attention_mode, :string, default: "mention")
    field(:attention_config, :map, default: %{})
    field(:joined_at, :utc_datetime_usec)
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
      :joined_at
    ])
    |> validate_required([:space_id, :participant_type, :participant_id, :role, :joined_at])
    |> validate_inclusion(:participant_type, @participant_types)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:attention_mode, @attention_modes)
    |> unique_constraint(:participant_id, name: :chat_participants_unique)
  end
end
