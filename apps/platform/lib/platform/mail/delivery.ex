defmodule Platform.Mail.Delivery do
  @moduledoc """
  One send attempt, and its audit record (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 2).

  Inserted by `Platform.Mail.Dispatch` in the committed transaction that
  evaluated the send policy — as `sending` (allowed) or `refused` (with a
  `refusal_reason`) — BEFORE anything reaches SMTP. It snapshots the From
  address, the expanded recipients, subject and body, and who was
  responsible: the actor who sent it, who drafted it, on whose behalf.

  ## Immutable snapshot

  `insert_changeset/1` is the only changeset that writes snapshot columns.
  After insert, `status_changeset/2` casts exactly `status`, `error`,
  `smtp_response` and `accepted_at`; every other attribute handed to it is
  ignored. The database backs this with the
  `mail_deliveries_snapshot_immutable` trigger, which refuses any UPDATE that
  changes a snapshot column however it was issued.

  ## Status words

  `queued | sending | accepted | failed | refused`. `accepted` is what an SMTP
  250 means and all it means; it is never called "sent" or "delivered".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(queued sending accepted failed refused)
  @mutable_fields [:status, :error, :smtp_response, :accepted_at]
  @snapshot_fields [
    :id,
    :org_id,
    :account_id,
    :sender_key,
    :from_address,
    :recipients,
    :subject,
    :body,
    :actor_type,
    :actor_id,
    :drafted_by_type,
    :drafted_by_id,
    :on_behalf_of_user_id,
    :responsibility,
    :draft_id,
    :task_id,
    :stage_id,
    :message_id_header,
    :refusal_reason
  ]

  @type t :: %__MODULE__{}

  schema "mail_deliveries" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:account, Platform.Mail.Account)
    field(:sender_key, :string)
    field(:from_address, :string)
    field(:recipients, {:array, :string}, default: [])
    field(:subject, :string)
    field(:body, :string)
    field(:actor_type, :string)
    field(:actor_id, :binary_id)
    field(:drafted_by_type, :string)
    field(:drafted_by_id, :binary_id)
    field(:on_behalf_of_user_id, :binary_id)
    field(:responsibility, :string)
    belongs_to(:draft, Platform.Mail.Draft)
    field(:task_id, :binary_id)
    field(:stage_id, :binary_id)
    field(:message_id_header, :string)
    field(:status, :string)
    field(:refusal_reason, :map)
    field(:error, :string)
    field(:smtp_response, :string)
    field(:accepted_at, :utc_datetime_usec)

    timestamps()
  end

  @doc "Statuses a delivery may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The fields `status_changeset/2` may change after insert."
  @spec mutable_fields() :: [atom()]
  def mutable_fields, do: @mutable_fields

  @doc "The snapshot fields written once, at insert."
  @spec snapshot_fields() :: [atom()]
  def snapshot_fields, do: @snapshot_fields

  @doc "The one changeset that writes snapshot columns. Insert only."
  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @snapshot_fields ++ @mutable_fields)
    |> validate_required([
      :id,
      :org_id,
      :account_id,
      :sender_key,
      :from_address,
      :actor_type,
      :message_id_header,
      :status
    ])
    |> validate_inclusion(:status, ["queued", "sending", "refused"])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:draft_id)
    |> check_constraint(:status, name: :mail_deliveries_status_check)
  end

  @doc """
  The only post-insert changeset: casts `status`, `error`, `smtp_response`
  and `accepted_at`, and silently ignores every other key in `attrs`.
  """
  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = delivery, attrs) do
    delivery
    |> cast(attrs, @mutable_fields)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :mail_deliveries_status_check)
  end
end
