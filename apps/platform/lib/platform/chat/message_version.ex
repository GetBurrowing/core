defmodule Platform.Chat.MessageVersion do
  @moduledoc """
  Append-only edit history for `Platform.Chat.Message`.

  Implements section (a.2) of `docs/contracts/editable-messages-contract.md`.

  Version 1 is the original content — inserted at the same time as the
  message itself (in a transaction with the initial message insert for new
  messages; backfilled by `20260511170000_add_message_edit_history` for
  pre-existing rows). Each successful edit appends a new row with
  `version_number = previous + 1`.

  The current `chat_messages.content` always matches the highest-version
  row's `content` for that message — soft-redundant but cheaper than
  joining for every render.

  `edited_by_display_name` is denormalized so version history survives
  participant deletion (ADR 0038 author-snapshot pattern).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "chat_message_versions" do
    field(:message_id, :binary_id)
    field(:version_number, :integer)
    field(:content, :string)
    field(:edited_at, :utc_datetime_usec)

    field(:edited_by_participant_id, :binary_id)
    field(:edited_by_display_name, :string)

    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  @doc """
  Build a changeset for a new version row. All fields are required; there is
  no update path (this is an append-only table).
  """
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    version
    # `empty_values: []` keeps empty-string `content` from being silently
    # coerced to nil — empty content is a legitimate (if rare) state and
    # the column is NOT NULL, so we want it to round-trip as "".
    |> cast(
      attrs,
      [
        :message_id,
        :version_number,
        :content,
        :edited_at,
        :edited_by_participant_id,
        :edited_by_display_name
      ],
      empty_values: []
    )
    # `content` is not in validate_required because Ecto's required check
    # rejects empty strings, but the contract says nil/empty content is
    # legal (a message that was sent as a no-op or whose body was later
    # cleared should still get a v1 row for history continuity). DB-level
    # NOT NULL on the column is the safety net against actual NULL writes.
    |> validate_required([
      :message_id,
      :version_number,
      :edited_at,
      :edited_by_display_name
    ])
    |> validate_number(:version_number, greater_than: 0)
    |> unique_constraint([:message_id, :version_number],
      name: :chat_message_versions_message_id_version_number_index,
      message: "version already exists for this message"
    )
  end
end
