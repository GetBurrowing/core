defmodule Platform.Tasks.ReviewRequest do
  @moduledoc """
  A review request ties a `manual_approval` validation gate to a set of
  labelled review items that a human can independently approve or reject.

  The request stays `pending` until every item is dispositioned, at which point
  `maybe_resolve_request/1` marks it `resolved` and evaluates the validation.

  ## `superseded` is a third terminal status, and it is not `resolved`

  When a newer request is filed against the same validation, the earlier
  pending one becomes `"superseded"` (task `019fed8d` stage 3). It is spelled
  differently from `"resolved"` because no human dispositioned it: a
  `resolved` request is the record of a verdict, a `superseded` one is the
  record of evidence that was replaced before anyone acted on it. Collapsing
  the two would make an unreviewed submission indistinguishable from a
  reviewed one in every audit that reads this column.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Tasks.{ReviewItem, Task, Validation}

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending resolved superseded)

  schema "review_requests" do
    belongs_to(:validation, Validation)
    belongs_to(:task, Task)
    field(:execution_space_id, :binary_id)
    field(:status, :string, default: "pending")
    field(:submitted_by, :string)
    field(:resolved_at, :utc_datetime_usec)
    field(:superseded_at, :utc_datetime_usec)

    has_many(:items, ReviewItem)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(review_request, attrs) do
    review_request
    |> cast(attrs, [
      :validation_id,
      :task_id,
      :execution_space_id,
      :status,
      :submitted_by,
      :resolved_at,
      :superseded_at
    ])
    |> validate_required([:validation_id, :task_id])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:validation_id)
    |> foreign_key_constraint(:task_id)
  end
end
