defmodule Platform.Mail.AccountGrant do
  @moduledoc """
  One person's or agent's right to read one mail account (task 01a1ea5b
  stage 1). Written and deleted ONLY by `Platform.Mail.Ownership`.

  A grant is a permission, not data: revoking deletes the row (the audit row
  keeps the history). `principal_id` is polymorphic (a `users.id` or an
  `agents.id`), so it has no FK; DB triggers delete a principal's grants when
  the principal row is deleted (see the `AddMailboxOwnership` migration).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @principal_types ~w(user agent)

  @type t :: %__MODULE__{}

  schema "mail_account_grants" do
    belongs_to(:account, Platform.Mail.Account)
    field(:principal_type, :string)
    field(:principal_id, :binary_id)
    belongs_to(:granted_by_user, Platform.Accounts.User)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = grant, attrs) do
    grant
    |> cast(attrs, [:account_id, :principal_type, :principal_id, :granted_by_user_id])
    |> validate_required([:account_id, :principal_type, :principal_id])
    |> validate_inclusion(:principal_type, @principal_types)
    |> unique_constraint([:account_id, :principal_type, :principal_id],
      name: :mail_account_grants_account_principal_index
    )
    |> check_constraint(:principal_type, name: :mail_account_grants_principal_type_check)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:granted_by_user_id)
  end
end
