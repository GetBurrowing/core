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

  ## Rich parts (task 01a1a933 stage 1)

  Optional `html_body` (an HTML alternative to `body`), `reply_to`, and a
  calendar invite: `calendar_method` (`REQUEST` | `CANCEL`) with its
  `calendar_ics` text. The two calendar fields are set together or not at
  all. `Platform.Mail.Deliverer` renders them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(draft dispatched discarded)
  @creator_types ~w(user agent system)
  @calendar_methods ~w(REQUEST CANCEL)

  @type t :: %__MODULE__{}

  schema "mail_drafts" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:account, Platform.Mail.Account)
    field(:sender_key, :string)
    field(:to_addresses, {:array, :string}, default: [])
    field(:to_user_ids, {:array, :binary_id}, default: [])
    field(:subject, :string)
    field(:body, :string)
    field(:html_body, :string)
    field(:reply_to, :string)
    field(:calendar_method, :string)
    field(:calendar_ics, :string)
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
      :html_body,
      :reply_to,
      :calendar_method,
      :calendar_ics,
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
    |> validate_inclusion(:calendar_method, @calendar_methods)
    |> validate_calendar_pair()
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:account_id)
    |> check_constraint(:status, name: :mail_drafts_status_check)
    |> check_constraint(:calendar_method, name: :mail_drafts_calendar_method_check)
  end

  @doc "Calendar methods a draft may carry (`calendar_method`)."
  @spec calendar_methods() :: [String.t()]
  def calendar_methods, do: @calendar_methods

  # `calendar_ics` is present exactly when `calendar_method` is: a method
  # with no calendar would render an empty invite, and a calendar with no
  # method would carry no Accept/Decline semantics.
  defp validate_calendar_pair(changeset) do
    case {present?(get_field(changeset, :calendar_method)),
          present?(get_field(changeset, :calendar_ics))} do
      {true, false} -> add_error(changeset, :calendar_ics, "is required with calendar_method")
      {false, true} -> add_error(changeset, :calendar_method, "is required with calendar_ics")
      _ -> changeset
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
