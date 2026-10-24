defmodule Platform.Social.Account do
  @moduledoc """
  One platform account under a `Platform.Social.Profile` (task 01a140a8).

  **There is no secret field**, following `Platform.Mail.Account`: the
  platform credential lives in the Vault at scope `{:integration,
  account.id}`, and `secret_slug` only names it (`"social:<account_id>"`).
  `Platform.Social` sets the slug, `profile_id`, `archived_at` and
  `owner_user_id`; none of them is ever cast from attrs.

  `owner_user_id` (task 01a14ce1) is the person the account posts as. When
  it is set, only that user may approve, edit or reject the account's posts
  (`Platform.Social.post_approver_check/4`); when nil, the profile's
  approvers may, as before.

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
    # Task 01a14ce1: set by `Platform.Social.set_account_owner/3`, never cast.
    belongs_to(:owner_user, Platform.Accounts.User)
    # Social authoring 4/11: weekly slots in the PROFILE's timezone, and the
    # posts-per-week goal. Written by `schedule_changeset/2` only.
    embeds_many(:posting_slots, Platform.Social.PostingSlot, on_replace: :delete)
    field(:weekly_goal, :integer)
    # Social authoring 9/11: the disconnect alert's once-only marker. Written
    # by `Platform.Social.Health` only; never cast.
    field(:disconnect_alerted_at, :utc_datetime_usec)

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
  Changeset for the editable fields. `profile_id`, `secret_slug`,
  `archived_at` and `owner_user_id` are set by `Platform.Social`, never cast
  from attrs.
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
    |> rearm_disconnect_alert()
  end

  # Social authoring 9/11: a move to "connected" re-arms the disconnect
  # alert, so the NEXT disconnect alerts the approvers again.
  defp rearm_disconnect_alert(changeset) do
    if get_change(changeset, :status) == "connected",
      do: put_change(changeset, :disconnect_alerted_at, nil),
      else: changeset
  end

  @doc """
  Sets (or clears, with nil) `owner_user_id`. Only `Platform.Social` calls
  this; the field is never in `changeset/2`'s cast list.
  """
  @spec owner_changeset(t(), Ecto.UUID.t() | nil) :: Ecto.Changeset.t()
  def owner_changeset(%__MODULE__{} = account, owner_user_id) do
    account
    |> change(owner_user_id: owner_user_id)
    |> foreign_key_constraint(:owner_user_id)
  end

  @max_slots 50

  @doc """
  Social authoring 4/11: the account's `posting_slots` (each
  `%{weekday, time}`, de-duplicated and sorted, at most #{@max_slots}) and
  `weekly_goal` (nil or 1..100). Only these two fields; written through
  `Platform.Social.update_account_schedule/3`.
  """
  @spec schedule_changeset(t(), map()) :: Ecto.Changeset.t()
  def schedule_changeset(%__MODULE__{} = account, attrs) do
    account
    |> cast(attrs, [:weekly_goal])
    |> cast_embed(:posting_slots, with: &Platform.Social.PostingSlot.changeset/2)
    |> validate_number(:weekly_goal, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> check_constraint(:weekly_goal, name: :social_accounts_weekly_goal_check)
    |> dedupe_slots()
    |> validate_length(:posting_slots, max: @max_slots, message: "at most %{count} slots")
  end

  defp dedupe_slots(%Ecto.Changeset{valid?: true} = changeset) do
    case fetch_change(changeset, :posting_slots) do
      {:ok, slot_changesets} ->
        unique =
          slot_changesets
          |> Enum.reject(&(&1.action == :replace))
          |> Enum.uniq_by(&{get_field(&1, :weekday), get_field(&1, :time)})
          |> Enum.sort_by(&{get_field(&1, :weekday), get_field(&1, :time)})

        put_embed(changeset, :posting_slots, Enum.map(unique, &apply_changes/1))

      :error ->
        changeset
    end
  end

  defp dedupe_slots(changeset), do: changeset
end
