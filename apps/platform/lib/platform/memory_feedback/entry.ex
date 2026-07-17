defmodule Platform.MemoryFeedback.Entry do
  @moduledoc """
  Append-only feedback row capturing a mutation against org memory.

  See `Platform.MemoryFeedback` for the write API and the layer-1 rationale
  documented in the training-corpus plan.

  Rows are immutable. There is no `updated_at` on the schema and the
  underlying table has no update path — callers only ever `record_edit/1`,
  `record_delete/1`, or (future) `record_retention/1`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @feedback_kinds ~w(edit delete retention)

  @type t :: %__MODULE__{}

  schema "org_memory_feedback" do
    field(:original_content, :string)
    field(:edited_content, :string)
    field(:original_author_id, :binary_id)
    field(:editor_id, :binary_id)
    field(:path, :string)
    field(:namespace, :string)
    field(:workspace_id, :binary_id)
    field(:feedback_kind, :string)
    field(:reason_text, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(original_content path namespace feedback_kind)a
  @optional ~w(edited_content original_author_id editor_id workspace_id reason_text)a

  @doc "Returns the list of accepted `feedback_kind` values."
  def feedback_kinds, do: @feedback_kinds

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:feedback_kind, @feedback_kinds)
  end
end
