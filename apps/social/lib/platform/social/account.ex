defmodule Platform.Social.Account do
  @moduledoc """
  One platform account under a `Platform.Social.Profile` (task 01a140a8).

  **There is no secret field**, following `Platform.Mail.Account`: the
  platform credential lives in the Vault at scope `{:integration,
  account.id}`, and `secret_slug` only names it (`"social:<account_id>"`).
  `Platform.Social` sets the slug, `profile_id` and `archived_at`; none of
  them is ever cast from attrs.

  `approval_mode` defaults to `approve_first` (the column default too), so an
  account created without one never publishes unreviewed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @platforms ~w(linkedin x tiktok instagram youtube)
  @approval_modes ~w(draft_only approve_first)
  @statuses ~w(connected reauth_needed)
  @platform_account_types ~w(personal business creator)

  @type t :: %__MODULE__{}

  schema "social_accounts" do
    belongs_to(:profile, Platform.Social.Profile)

    field(:platform, :string)
    field(:handle, :string)
    field(:provider, :string)
    field(:provider_account_ref, :string)
    field(:approval_mode, :string, default: "approve_first")
    field(:secret_slug, :string)
    field(:status, :string)
    field(:archived_at, :utc_datetime_usec)
    # Social 2/7: Instagram Reels need business or creator.
    field(:platform_account_type, :string)

    has_many(:posts, Platform.Social.Post)

    timestamps()
  end

  @editable ~w(platform handle provider provider_account_ref approval_mode status)a

  @publisher_fields ~w(platform_account_type)a

  @doc "Accepted `platform_account_type` values (`nil` when unknown)."
  @spec platform_account_types() :: [String.t()]
  def platform_account_types, do: @platform_account_types

  @doc "Platforms an account may be on."
  @spec platforms() :: [String.t()]
  def platforms, do: @platforms

  @doc "Accepted `approval_mode` values."
  @spec approval_modes() :: [String.t()]
  def approval_modes, do: @approval_modes

  @doc "Accepted `status` values (`nil` until connected)."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Changeset for the editable fields. `profile_id`, `secret_slug` and
  `archived_at` are set by `Platform.Social`, never cast from attrs.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = account, attrs) do
    account
    |> cast(attrs, @editable)
    |> cast(attrs, @publisher_fields)
    |> validate_required([:platform, :approval_mode])
    |> validate_inclusion(:platform_account_type, @platform_account_types)
    |> check_constraint(:platform_account_type,
      name: :social_accounts_platform_account_type_check
    )
    |> validate_inclusion(:platform, @platforms)
    |> validate_inclusion(:approval_mode, @approval_modes)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:platform, name: :social_accounts_platform_check)
    |> check_constraint(:approval_mode, name: :social_accounts_approval_mode_check)
    |> check_constraint(:status, name: :social_accounts_status_check)
    |> foreign_key_constraint(:profile_id)
  end
end
