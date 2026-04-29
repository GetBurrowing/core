defmodule Platform.Chat.Reaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_reactions" do
    field(:message_id, :binary_id)
    field(:participant_id, :binary_id)
    field(:emoji, :string)

    # Reactor identity snapshot — captured at write time so the reactor's
    # name survives the participant being hard-deleted from the space.
    # Mirrors ADR 0038's author snapshots on chat_messages.
    field(:reactor_display_name, :string)
    field(:reactor_avatar_url, :string)
    field(:reactor_participant_type, :string)

    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})

    # Soft-delete timestamp. NULL = active. Set by `Chat.remove_reaction/3`.
    # The unique index on (message_id, participant_id, emoji) is partial
    # (WHERE deleted_at IS NULL), so a re-reaction after soft-delete is
    # allowed at the storage layer; `Chat.add_reaction/1` prefers
    # resurrection over inserting a duplicate.
    field(:deleted_at, :utc_datetime_usec)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [
      :message_id,
      :participant_id,
      :emoji,
      :reactor_display_name,
      :reactor_avatar_url,
      :reactor_participant_type
    ])
    |> validate_required([:message_id, :participant_id, :emoji])
    |> unique_constraint(:emoji, name: :chat_reactions_unique)
  end

  @doc """
  Soft-delete-only changeset. Casts only `deleted_at` (set to a timestamp to
  hide, or `nil` to restore). Mirrors `Canvas.delete_changeset/2`.
  """
  def delete_changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:deleted_at])
  end
end
