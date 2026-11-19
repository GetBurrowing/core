defmodule Platform.Mail.Triage.Item do
  @moduledoc """
  One reader's triage of one inbound email (task 01a1f426 stage 1),
  `mail_triage_items`. Unique per (inbound message, reader), which is what
  makes `Platform.Mail.Triage.run_for_reader/2` idempotent.

  `why` is a model-written line (at most 160 characters) about the email:
  it carries mail content, so it is shown only to a reader of the mailbox
  and written only with `Repo` opts that keep it out of the query log and
  telemetry (`Platform.Mail.Triage.quiet_opts/0`). `signals` is a list of
  `%{"kind" => ..., <id or count keys>}` maps and never holds text.

  The draft columns are written by `Platform.Mail.Triage.Drafter` (stage
  4): `drafted_at` (when the drafter took the item), and either `draft_id`
  + `draft_original_body` (the model's reply as first written, inside the
  mailbox boundary like the draft itself) or `plan_summary` +
  `plan_steps`. All of them carry model text and are written with
  `Platform.Mail.Triage.quiet_opts/0`. `draft_original_body` is cleared by
  a database trigger when the draft is discarded or deleted. `edit_ratio`
  is stage 5's.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @tiers ~w(top action routine promo)
  @needs ~w(reply decision plan none)
  @statuses ~w(open acted dismissed)
  @why_cap 160

  @type t :: %__MODULE__{}

  schema "mail_triage_items" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:account, Platform.Mail.Account)
    belongs_to(:inbound_message, Platform.Mail.InboundMessage)
    belongs_to(:user, Platform.Accounts.User)
    field(:tier, :string)
    field(:needs, :string, default: "none")
    field(:why, :string)
    field(:signals, {:array, :map}, default: [])
    field(:classifier, :string)
    field(:status, :string, default: "open")
    field(:acted_at, :utc_datetime_usec)
    field(:acted_how, :string)
    field(:notified_at, :utc_datetime_usec)
    field(:draft_id, :binary_id)
    field(:draft_original_body, :string)
    field(:plan_steps, {:array, :string})
    field(:plan_summary, :string)
    field(:drafted_at, :utc_datetime_usec)
    field(:edit_ratio, :float)

    timestamps()
  end

  @doc "The tiers, most important first."
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc "What a called-out email can need from its reader."
  @spec needs() :: [String.t()]
  def needs, do: @needs

  @doc "Item statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Maximum length of `why`, in characters."
  @spec why_cap() :: pos_integer()
  def why_cap, do: @why_cap

  @doc "Changeset for a new item."
  def create_changeset(item \\ %__MODULE__{}, attrs) do
    item
    |> cast(attrs, [
      :org_id,
      :account_id,
      :inbound_message_id,
      :user_id,
      :tier,
      :needs,
      :why,
      :signals,
      :classifier
    ])
    |> validate_required([
      :org_id,
      :account_id,
      :inbound_message_id,
      :user_id,
      :tier,
      :classifier
    ])
    |> common_validations()
  end

  @doc "Changeset for the reader-facing fields: status, acted, tier."
  def update_changeset(%__MODULE__{} = item, attrs) do
    item
    |> cast(attrs, [:status, :acted_at, :acted_how, :tier])
    |> common_validations()
  end

  @max_plan_steps 8

  @doc "At most this many plan steps."
  @spec max_plan_steps() :: pos_integer()
  def max_plan_steps, do: @max_plan_steps

  @doc "Changeset for the drafter's columns (task 01a1f426 stage 4)."
  def drafter_changeset(%__MODULE__{} = item, attrs) do
    item
    |> cast(attrs, [:draft_id, :draft_original_body, :plan_summary, :plan_steps, :drafted_at])
    |> validate_length(:plan_steps, max: @max_plan_steps)
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_inclusion(:tier, @tiers)
    |> validate_inclusion(:needs, @needs)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:why, max: @why_cap)
    |> check_constraint(:tier, name: :mail_triage_items_tier_check)
    |> check_constraint(:needs, name: :mail_triage_items_needs_check)
    |> check_constraint(:status, name: :mail_triage_items_status_check)
    |> check_constraint(:why, name: :mail_triage_items_why_length_check)
    |> unique_constraint([:inbound_message_id, :user_id])
    |> foreign_key_constraint(:inbound_message_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
  end
end
