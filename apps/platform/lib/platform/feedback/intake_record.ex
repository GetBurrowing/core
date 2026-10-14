defmodule Platform.Feedback.IntakeRecord do
  @moduledoc """
  One row per external issue the feedback intake has seen (task 01a11ec3
  stage 3), keyed by normalized repository identity plus issue number.

  The unique index `feedback_intake_records_identity_unique` over
  `(lower(repository_identity), issue_number)` is what makes a webhook retry,
  a redelivery and a poll of the same issue land on ONE record. The record's
  row lock is what serialises two concurrent deliveries of that issue, and
  the tasks table's own `tasks_external_feedback_identity_unique` index is the
  backstop that keeps the issue to at most one task.

  The row stores NO issue text: only the identity, the bounded verdict and
  reason code, which classifier produced them, the task it filed (if any),
  the canned disposition applied, and `content_sha256`, a digest of the last
  delivered title + body.

  `status` is one of:

    * `"pending"` — no verdict yet. `note` names why with a bounded value
      (`unassigned`, `provider_failed`, `rejected_output`, `no_project`). A
      later delivery of the same issue tries again.
    * `"decided"` — terminal. A verdict is recorded and is never revised by
      a redelivery; an accepted verdict carries `task_id`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(pending decided)
  @notes ~w(unassigned provider_failed rejected_output no_project)
  @disposition_statuses ~w(applied skipped failed)

  schema "feedback_intake_records" do
    field(:repository_identity, :string)
    field(:issue_number, :integer)
    field(:status, :string, default: "pending")
    field(:verdict, :string)
    field(:reason_code, :string)
    field(:classifier, :string)
    field(:note, :string)
    field(:task_id, :binary_id)
    field(:disposition, :string)
    field(:disposition_status, :string)
    field(:deliveries, :integer, default: 1)
    field(:content_sha256, :string)
    field(:last_delivered_at, :utc_datetime_usec)
    field(:decided_at, :utc_datetime_usec)

    timestamps()
  end

  @doc "The accepted `status` values."
  def statuses, do: @statuses

  @doc "The bounded `note` values a pending record may carry."
  def notes, do: @notes

  @doc false
  def pending_changeset(record, note) when note in @notes do
    record
    |> change(status: "pending", note: note)
  end

  @doc false
  def decided_changeset(record, attrs) do
    record
    |> cast(attrs, [:verdict, :reason_code, :classifier, :task_id, :decided_at])
    |> put_change(:status, "decided")
    |> put_change(:note, nil)
    |> validate_required([:verdict, :classifier, :decided_at])
    |> validate_inclusion(:verdict, Platform.Feedback.Classifier.verdicts())
    |> validate_inclusion(:reason_code, Platform.Feedback.Classifier.reason_codes())
    |> check_constraint(:verdict, name: :feedback_intake_records_verdict_check)
  end

  @doc false
  def disposition_changeset(record, disposition, status) when status in @disposition_statuses do
    change(record, disposition: disposition, disposition_status: status)
  end
end
