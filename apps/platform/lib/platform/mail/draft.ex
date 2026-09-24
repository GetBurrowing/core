defmodule Platform.Mail.Draft do
  @moduledoc """
  An email being written, by a person, an agent or the system (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 2).

  A draft names its account and sender key explicitly; `account_id` may stay
  nil until one is chosen, and `Platform.Mail.Dispatch.dispatch/3` refuses a
  draft that does not name both. Recipients are addresses (`to_addresses`)
  and/or users (`to_user_ids`, expanded to their emails at send time).

  `status` moves `draft -> dispatched` only when a send is ACCEPTED by the
  relay; a refused or failed send leaves the draft as a draft.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(draft dispatched discarded)
  @creator_types ~w(user agent system)

  @type t :: %__MODULE__{}

  schema "mail_drafts" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:account, Platform.Mail.Account)
    field(:sender_key, :string)
    field(:to_addresses, {:array, :string}, default: [])
    field(:to_user_ids, {:array, :binary_id}, default: [])
    field(:subject, :string)
    field(:body, :string)
    field(:created_by_type, :string)
    field(:created_by_id, :binary_id)
    field(:on_behalf_of_user_id, :binary_id)
    field(:responsibility, :string)
    field(:task_id, :binary_id)
    field(:stage_id, :binary_id)
    field(:status, :string, default: "draft")

    timestamps()
  end

  @doc "Statuses a draft may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Changeset for creating or editing a draft. `org_id` and the creator are
  cast here because the callers (the module UI, the agent draft tool, the
  deploy strategy) each set them from their own authenticated context.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = draft, attrs) do
    draft
    |> cast(attrs, [
      :org_id,
      :account_id,
      :sender_key,
      :to_addresses,
      :to_user_ids,
      :subject,
      :body,
      :created_by_type,
      :created_by_id,
      :on_behalf_of_user_id,
      :responsibility,
      :task_id,
      :stage_id,
      :status
    ])
    |> validate_required([:org_id, :created_by_type, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:created_by_type, @creator_types)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:account_id)
    |> check_constraint(:status, name: :mail_drafts_status_check)
  end
end
