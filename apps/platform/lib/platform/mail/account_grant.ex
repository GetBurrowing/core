defmodule Platform.Mail.AccountGrant do
  @moduledoc """
  One person's or agent's right to read one mail account (task 01a1ea5b
  stage 1). Written and deleted ONLY by `Platform.Mail.Ownership`.

  A grant is a permission, not data: revoking deletes the row (the audit row
  keeps the history). `principal_id` is polymorphic (a `users.id` or an
  `agents.id`), so it has no FK; DB triggers delete a principal's grants when
  the principal row is deleted (see the `AddMailboxOwnership` migration).

  `purpose` (task 01a1f5cc stage 1) is `"access"` for an ordinary read grant
  or `"flag_important"` for the one agent a mailbox's owner chose to flag
  important email (`Ownership.set_flag_important_agent/3`). Both purposes
  grant read; an agent may hold one row of each on a mailbox, and a mailbox
  has at most one flag_important row, always an agent's.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @principal_types ~w(user agent)
  @purposes ~w(access flag_important)

  @type t :: %__MODULE__{}

  schema "mail_account_grants" do
    belongs_to(:account, Platform.Mail.Account)
    field(:principal_type, :string)
    field(:principal_id, :binary_id)
    field(:purpose, :string, default: "access")
    belongs_to(:granted_by_user, Platform.Accounts.User)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = grant, attrs) do
    grant
    |> cast(attrs, [:account_id, :principal_type, :principal_id, :purpose, :granted_by_user_id])
    |> validate_required([:account_id, :principal_type, :principal_id, :purpose])
    |> validate_inclusion(:principal_type, @principal_types)
    |> validate_inclusion(:purpose, @purposes)
    |> unique_constraint([:account_id, :principal_type, :principal_id, :purpose],
      name: :mail_account_grants_account_principal_purpose_index
    )
    |> unique_constraint(:account_id,
      name: :mail_account_grants_one_flag_agent_index,
      message: "already has a flag agent"
    )
    |> check_constraint(:principal_type, name: :mail_account_grants_principal_type_check)
    |> check_constraint(:purpose, name: :mail_account_grants_purpose_check)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:granted_by_user_id)
  end
end
