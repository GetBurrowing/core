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

    # Editable-messages contract (docs/contracts/editable-messages-contract.md).
    # `frozen_at` non-null means PATCH /api/messages/:id returns 409. The
    # `frozen_by_participant_id` records who froze it (whose action triggered
    # the freeze) for the 409 payload's `freezing_action` context. Per the
    # check constraint, the two are both-or-neither.
    field(:frozen_at, :utc_datetime_usec)
    field(:frozen_by_participant_id, :binary_id)

    # Non-null only on agent correction messages (Policy 3 — agents correct
    # via a NEW message with `corrects_message_id` set, not by editing).
    field(:corrects_message_id, :binary_id)

    # Virtual: count of rows in chat_message_versions for this message. UI
    # renders the "(edited)" affix when this is > 1.
    field(:versions_count, :integer, virtual: true)

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

    # Day-bucket label (YYYY-MM-DD) attached at stream-insert time when
    # this message is the first of its calendar day in the visible list
    # (task 019e21c7 Stage 5). Render the date separator inline above the
    # message row when this is non-nil. Computed server-side because
    # `#message-list` carries `phx-update="stream"` — JS-injected
    # separator siblings get stripped by morphdom on every reconcile,
    # so the separator must live INSIDE the stream item to survive.
    field(:day_label, :string, virtual: true, default: nil)

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
      :author_user_id,
      :frozen_at,
      :frozen_by_participant_id,
      :corrects_message_id
    ])
    |> validate_required([:space_id, :participant_id, :content_type])
    |> validate_inclusion(:content_type, @content_types)
    |> validate_frozen_both_or_neither()
  end

  # Mirrors the DB-level check constraint `frozen_both_or_neither`. Catching
  # it in the changeset gives a clean validation error before the database
  # raises, and lets callers display a field-level message in the UI.
  defp validate_frozen_both_or_neither(changeset) do
    frozen_at = get_field(changeset, :frozen_at)
    frozen_by = get_field(changeset, :frozen_by_participant_id)

    case {frozen_at, frozen_by} do
      {nil, nil} ->
        changeset

      {%DateTime{}, <<_::binary>>} ->
        changeset

      {%DateTime{}, nil} ->
        add_error(changeset, :frozen_by_participant_id, "is required when frozen_at is set")

      {nil, <<_::binary>>} ->
        add_error(changeset, :frozen_at, "is required when frozen_by_participant_id is set")
    end
  end
end
