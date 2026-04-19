defmodule Platform.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  # UUID primary key — repo config sets migration_primary_key: [type: :binary_id].
  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @content_types ~w(text system agent_action canvas)

  schema "chat_messages" do
    field(:space_id, :binary_id)
    field(:thread_id, :binary_id)
    field(:participant_id, :binary_id)
    field(:canvas_id, :binary_id)
    field(:content_type, :string, default: "text")
    field(:content, :string)
    field(:structured_content, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    field(:log_only, :boolean, default: false)

    # Author identity snapshot (ADR 0038). Populated at write time from the
    # authoring participant and treated as source of truth for rendering. A
    # participant leaving or being dismissed does not mutate these fields, so
    # historical messages keep the name + avatar they had when they spoke.
    field(:author_display_name, :string)
    field(:author_avatar_url, :string)
    field(:author_participant_type, :string)
    field(:author_agent_id, :binary_id)
    field(:author_user_id, :binary_id)

    field(:search_rank, :float, virtual: true)
    field(:search_headline, :string, virtual: true)

    # Reactions are grouped per message and attached as a virtual field at
    # render time so LiveView streams can carry them as part of the item.
    # Shape: [%{emoji: "👍", count: 2, reacted_by_me: true}, ...].
    field(:reactions, {:array, :map}, virtual: true, default: [])

    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :space_id,
      :thread_id,
      :participant_id,
      :canvas_id,
      :content_type,
      :content,
      :structured_content,
      :metadata,
      :edited_at,
      :deleted_at,
      :log_only,
      :author_display_name,
      :author_avatar_url,
      :author_participant_type,
      :author_agent_id,
      :author_user_id
    ])
    |> validate_required([:space_id, :participant_id, :content_type])
    |> validate_inclusion(:content_type, @content_types)
  end
end
