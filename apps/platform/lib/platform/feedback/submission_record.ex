defmodule Platform.Feedback.SubmissionRecord do
  @moduledoc """
  One row per distinct `feedback_submit` fingerprint (task 01a11ec3 stage 2):
  the idempotency key, the rate-limit ledger, and the bounded external
  identity of the issue it produced.

  The row deliberately stores NO submission text. The sanitized fields exist
  only long enough to build the issue; what persists is the fingerprint, the
  category, which agent submitted it, the publication status, and the
  repository + issue number the publisher returned. A leak of this table
  discloses that a submission happened, not what it said.

  `status` is one of:

    * `"pending"` — reserved before the external call. The unique index on
      `fingerprint` is what makes two concurrent identical submissions
      produce one external call: the second insert conflicts.
    * `"published"` — the publisher returned a validated identity.
    * `"failed"` — the publisher refused or was unreachable; `error_code` is
      the bounded atom, never a response body. A later identical submission
      retries the same row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(pending published failed)

  schema "feedback_submissions" do
    field(:fingerprint, :string)
    field(:category, :string)
    field(:actor_agent_id, :binary_id)
    field(:status, :string, default: "pending")
    field(:external_repository, :string)
    field(:external_issue_number, :integer)
    field(:error_code, :string)
    field(:published_at, :utc_datetime_usec)
    field(:attempted_at, :utc_datetime_usec)

    timestamps()
  end

  @doc "The accepted `status` values."
  def statuses, do: @statuses

  @doc false
  def reserve_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:fingerprint, :category, :actor_agent_id, :attempted_at])
    |> validate_required([:fingerprint, :category, :attempted_at])
    |> put_change(:status, "pending")
    |> unique_constraint(:fingerprint)
  end

  @doc false
  def status_changeset(record, attrs) do
    record
    |> cast(attrs, [
      :status,
      :external_repository,
      :external_issue_number,
      :error_code,
      :published_at,
      :attempted_at,
      :actor_agent_id
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
