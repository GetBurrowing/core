defmodule Platform.Mail.Triage.Feedback do
  @moduledoc """
  A reader's verdict on how the triage treated a sender (task 01a1f426
  stage 1), `mail_triage_feedback`: `"not_important"` (it called out
  something that did not need them) or `"missed"` (it left out something
  that did). Read back by `Platform.Mail.Triage.Context` as priors for the
  same reader and sender domain. Carries an address and a domain, never
  subject or body text.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @verdicts ~w(not_important missed)

  @type t :: %__MODULE__{}

  schema "mail_triage_feedback" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:account, Platform.Mail.Account)
    belongs_to(:inbound_message, Platform.Mail.InboundMessage)
    field(:sender_address, :string)
    field(:sender_domain, :string)
    field(:verdict, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The verdicts a reader can give."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc "Changeset for a new feedback row."
  def changeset(feedback \\ %__MODULE__{}, attrs) do
    feedback
    |> cast(attrs, [
      :org_id,
      :user_id,
      :account_id,
      :inbound_message_id,
      :sender_address,
      :sender_domain,
      :verdict
    ])
    |> validate_required([
      :org_id,
      :user_id,
      :account_id,
      :sender_address,
      :sender_domain,
      :verdict
    ])
    |> validate_inclusion(:verdict, @verdicts)
    |> check_constraint(:verdict, name: :mail_triage_feedback_verdict_check)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:user_id)
  end
end
