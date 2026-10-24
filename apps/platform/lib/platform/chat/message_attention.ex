defmodule Platform.Chat.MessageAttention do
  @moduledoc """
  One participant a member asked to look at an already-sent message
  ("Get someone's attention", task 01a1557a-a30a stage 1).

  Written only by `Platform.Chat.add_message_attention/4`. The message row is
  never updated by that writer, so a row here never creates a message version
  and never renders "(edited)". Names are snapshotted (ADR 0038) so the line
  survives either participant leaving the space.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "chat_message_attentions" do
    field(:message_id, :binary_id)
    field(:participant_id, :binary_id)
    field(:participant_type, :string)
    field(:display_name, :string)
    field(:added_by_participant_id, :binary_id)
    field(:added_by_display_name, :string)
    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  @fields ~w(message_id participant_id participant_type display_name
             added_by_participant_id added_by_display_name)a

  def changeset(attention, attrs) do
    attention
    |> cast(attrs, @fields)
    |> validate_required([:message_id, :participant_id, :participant_type])
    |> unique_constraint([:message_id, :participant_id],
      name: :chat_message_attentions_message_participant_index
    )
  end

  @doc "The render shape attached to `Message.attention`."
  @spec to_view(t()) :: map()
  def to_view(%__MODULE__{} = a) do
    %{
      participant_id: a.participant_id,
      participant_type: a.participant_type,
      display_name: a.display_name,
      added_by_participant_id: a.added_by_participant_id,
      added_by_display_name: a.added_by_display_name,
      inserted_at: a.inserted_at
    }
  end
end
