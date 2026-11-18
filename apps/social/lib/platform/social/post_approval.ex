defmodule Platform.Social.PostApproval do
  @moduledoc """
  One receipt for one approval of a Studio post: bound to
  `(post_id, version, account_id)`, with the approver, the content
  fingerprint and a snapshot. Rows are never deleted: a new version moves a
  `current` row to `superseded`, a withdrawal to `revoked`. At most one
  `current` row per post (partial unique index
  `social_post_approvals_one_current`); `post_id` and `account_id` are
  `restrict` foreign keys, so a post that has a receipt cannot be removed.

  Slice A defines the schema; slice B's `Platform.Social.Studio` functions
  are its writers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(current superseded revoked)

  @type t :: %__MODULE__{}

  schema "social_post_approvals" do
    belongs_to(:post, Platform.Social.Post)
    field(:version, :integer)
    belongs_to(:account, Platform.Social.Account)
    belongs_to(:approved_by_user, Platform.Accounts.User)
    field(:approved_at, :utc_datetime_usec)
    field(:state, :string, default: "current")
    field(:ended_at, :utc_datetime_usec)
    field(:ended_by_kind, :string)
    field(:ended_by_id, :binary_id)
    field(:ended_reason, :string)
    field(:content_fingerprint, :string)
    field(:snapshot, :map, default: %{})
  end

  @doc "Accepted `state` values."
  @spec states() :: [String.t()]
  def states, do: @states

  @fields ~w(post_id version account_id approved_by_user_id approved_at state ended_at
             ended_by_kind ended_by_id ended_reason content_fingerprint snapshot)a

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = approval, attrs) do
    approval
    |> cast(attrs, @fields)
    |> validate_required(
      ~w(post_id version account_id approved_by_user_id approved_at state content_fingerprint)a
    )
    |> validate_inclusion(:state, @states)
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> check_constraint(:state, name: :social_post_approvals_state_check)
    |> check_constraint(:version, name: :social_post_approvals_version_check)
    |> unique_constraint(:post_id, name: :social_post_approvals_one_current)
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:approved_by_user_id)
  end
end
