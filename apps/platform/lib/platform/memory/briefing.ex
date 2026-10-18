defmodule Platform.Memory.Briefing do
  @moduledoc """
  One delivered daily insight briefing: the receipt of the canvas
  `Platform.Memory.Insights.Disseminator` posted into a person's DM with the
  dreaming agent. Task `01a13867-3213-7001-a128-6b4c6b34283f`, stage 3.

  DURABLE, unlike `Platform.Memory.Insight`: a briefing is a sent message,
  and the insights it rendered may be purged long before it is read.

    * `items` maps each canvas node key to the insight id it renders
      (`%{"i1a2b..." => "<insight uuid>"}`). Canvas actions carry the node
      key only, so a click resolves its insight through this row and the
      clicked canvas, never through an id the client supplied.
    * `(user_id, digest_date)` is unique: one digest per person per day.
    * `canvas_id` is unique: one row per canvas.
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

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(briefing, attrs) do
    briefing
    |> cast(attrs, [:user_id, :space_id, :canvas_id, :digest_date, :items])
    |> validate_required([:user_id, :space_id, :canvas_id, :digest_date, :items])
    |> unique_constraint([:user_id, :digest_date],
      name: :memory_briefings_user_id_digest_date_index
    )
    |> unique_constraint(:canvas_id, name: :memory_briefings_canvas_id_index)
  end
end
