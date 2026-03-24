defmodule Platform.Tasks.ReviewRequest do
  @moduledoc """
  A review request ties a `manual_approval` validation gate to a set of
  labelled review items that a human can independently approve or reject.

  The request stays `pending` until every item is dispositioned, at which point
  `maybe_resolve_request/1` marks it `resolved` and evaluates the validation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Tasks.{ReviewItem, Task, Validation}

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending resolved)

  schema "review_requests" do
    belongs_to(:validation, Validation)
    belongs_to(:task, Task)
    field(:execution_space_id, :binary_id)
    field(:status, :string, default: "pending")
    field(:submitted_by, :string)
    field(:resolved_at, :utc_datetime_usec)

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
      :resolved_at
    ])
    |> validate_required([:validation_id, :task_id])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:validation_id)
    |> foreign_key_constraint(:task_id)
  end
end
