defmodule Platform.Tasks.ReviewItem do
  @moduledoc """
  An individual item within a `ReviewRequest`.

  Each item has an independent disposition: `pending`, `approved`, or
  `needs_revision`.  When a human provides feedback on a `needs_revision`
  item, the `feedback` field stores the text and `reviewed_by` / `reviewed_at`
  capture who and when.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Tasks.ReviewRequest

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending approved needs_revision)

  schema "review_items" do
    belongs_to(:review_request, ReviewRequest)
    field(:label, :string)
    field(:canvas_id, :string)
    field(:content, :string)
    field(:status, :string, default: "pending")
    field(:feedback, :string)
    field(:reviewed_by, :string)
    field(:reviewed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(review_item, attrs) do
    review_item
    |> cast(attrs, [
      :review_request_id,
      :label,
      :canvas_id,
      :content,
      :status,
      :feedback,
      :reviewed_by,
      :reviewed_at
    ])
    |> validate_required([:review_request_id, :label])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:review_request_id)
  end
end
