defmodule Platform.Social.ApprovalCard do
  @moduledoc """
  One approval card (task 01a140a9-31b0, Social 3/7): the chat canvas a
  post's approvers decide on. The canvas document holds only a
  `social_post_card` node with `card_id` and `rev`; everything a human sees
  is rendered from the post at view time, for that viewer.

  States: `pending` (live, actions shown to approvers), `deciding` (a
  decision holds the row lock), `decided` (approve or reject, with the
  decider and time; a DB CHECK enforces all three) and `superseded`. A post
  has at most one live (`pending`/`deciding`) card, by a partial unique
  index.

  `create_changeset/2` casts only the pointers and the digest. The decision
  fields (`decision`, `decided_by_user_id`, `decided_at`) and the edit stamp
  are never cast from attrs: only `Platform.Social.Approvals` sets them,
  through `decided_changeset/3` and `edited_changeset/2`, inside its locked
  transaction.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @states ~w(pending deciding decided superseded)
  @live_states ~w(pending deciding)
  @decisions ~w(approve reject)

  @type t :: %__MODULE__{}

  schema "social_approval_cards" do
    belongs_to(:post, Platform.Social.Post)
    belongs_to(:canvas, Platform.Chat.Canvas)
    belongs_to(:message, Platform.Chat.Message)

    field(:card_digest, :string)
    field(:state, :string, default: "pending")
    field(:decision, :string)
    belongs_to(:decided_by_user, Platform.Accounts.User)
    field(:decided_at, :utc_datetime_usec)
    belongs_to(:edited_by_user, Platform.Accounts.User)
    field(:edited_at, :utc_datetime_usec)

    timestamps()
  end

  @doc "Accepted `state` values."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "States in which a card is still live (at most one per post)."
  @spec live_states() :: [String.t()]
  def live_states, do: @live_states

  @doc "Accepted `decision` values."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  @doc "A new pending card: the post, the canvas, its message and the document digest."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = card, attrs) do
    card
    |> cast(attrs, [:post_id, :canvas_id, :message_id, :card_digest])
    |> validate_required([:post_id, :canvas_id, :card_digest])
    |> put_change(:state, "pending")
    |> db_constraints()
  end

  @doc false
  # Set by `Platform.Social.Approvals` only, inside its locked transaction.
  @spec decided_changeset(t(), String.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def decided_changeset(%__MODULE__{} = card, decision, user_id) when decision in @decisions do
    card
    |> change(
      state: "decided",
      decision: decision,
      decided_by_user_id: user_id,
      decided_at: DateTime.utc_now()
    )
    |> db_constraints()
  end

  @doc false
  # Set by `Platform.Social.Approvals` only: a human edited the post's text.
  @spec edited_changeset(t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def edited_changeset(%__MODULE__{} = card, user_id) do
    card
    |> change(edited_by_user_id: user_id, edited_at: DateTime.utc_now())
    |> db_constraints()
  end

  defp db_constraints(changeset) do
    changeset
    |> check_constraint(:state, name: :social_approval_cards_state_check)
    |> check_constraint(:decision, name: :social_approval_cards_decision_check)
    |> check_constraint(:state, name: :social_approval_cards_decided_complete_check)
    |> unique_constraint(:canvas_id)
    |> unique_constraint(:post_id, name: :social_approval_cards_one_live_card_per_post)
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:canvas_id)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:decided_by_user_id)
    |> foreign_key_constraint(:edited_by_user_id)
  end
end
