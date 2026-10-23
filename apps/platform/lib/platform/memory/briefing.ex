defmodule Platform.Memory.Briefing do
  @moduledoc """
  One delivered daily insight briefing. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 3.

  Since task `01a15ee1-48c8-7000-a8f1-33a5586cb458` (stage 1) a briefing is
  delivered as ONE Inbox row per person per day (`Platform.Inbox` kind
  `briefing`, `source_id` = this row's id) and has NO canvas: `canvas_id`
  and `space_id` are nil. Rows delivered before that keep the canvas
  `Platform.Memory.Insights.Disseminator` posted into the person's DM with
  the dreaming agent, and that canvas still renders and acts.

  DURABLE, unlike `Platform.Memory.Insight`: a briefing is a sent message,
  and the insights it rendered may be purged long before it is read.

    * `items` maps each canvas node key to the insight id it renders
      (`%{"i1a2b..." => "<insight uuid>"}`). Canvas actions carry the node
      key only, so a click resolves its insight through this row and the
      clicked canvas, never through an id the client supplied.
    * `(user_id, digest_date)` is unique: one digest per person per day.
    * `canvas_id` is unique: one row per canvas (nil for Inbox briefings).
    * `receipts` maps a node key to how that item was handled from the Inbox:
      `%{"verb", "at", "by", "ref", "undo"}`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "memory_briefings" do
    field(:user_id, :binary_id)
    field(:space_id, :binary_id)
    field(:canvas_id, :binary_id)
    field(:digest_date, :date)
    field(:items, :map, default: %{})
    field(:receipts, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(briefing, attrs) do
    briefing
    |> cast(attrs, [:user_id, :space_id, :canvas_id, :digest_date, :items, :receipts])
    |> validate_required([:user_id, :digest_date, :items])
    |> unique_constraint([:user_id, :digest_date],
      name: :memory_briefings_user_id_digest_date_index
    )
    |> unique_constraint(:canvas_id, name: :memory_briefings_canvas_id_index)
  end
end
