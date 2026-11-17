defmodule Platform.Goals.Proposal do
  @moduledoc """
  A New goal conversation's proposal (task 01a1dfc1-7625, Goals 5/8): what
  the agent and the person have settled so far. Nothing here is a goal; the
  goal is created only by the person's own confirmation
  (`Platform.Goals.confirm_proposal/3`).

  `draft` holds string keys (title, why, unit, target_value, source_key,
  source_settings, agent_mode, rhythm, rhythm_weekday, outreach, kind,
  stops). `settled` maps a setting name (stops, source, agent_mode, rhythm,
  outreach) to the ISO 8601 time it was first set. `revision` rises by one on
  every agent write.

  `user_id`, `agent_id`, `org_id`, `space_id` and `goal_id` are set by the
  context, never cast from attrs. Every read starts from
  `Platform.Goals.Proposals.visible_proposals/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(open confirmed cancelled expired)
  @deliveries ~w(pending sent offline failed no_runtime)

  @type t :: %__MODULE__{}

  schema "goal_proposals" do
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:agent, Platform.Agents.Agent)
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:space, Platform.Chat.Space)
    belongs_to(:goal, Platform.Goals.Goal)

    field(:first_message_id, :binary_id)
    field(:status, :string, default: "open")
    field(:revision, :integer, default: 0)
    field(:draft, :map, default: %{})
    field(:replies, {:array, :string}, default: [])
    field(:settled, :map, default: %{})
    field(:ready, :boolean, default: false)
    field(:confirmed_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:delivery, :string, default: "pending")

    timestamps()
  end

  @editable ~w(first_message_id status revision draft replies settled ready confirmed_at
               expires_at delivery)a

  def statuses, do: @statuses
  def deliveries, do: @deliveries

  @doc "Changeset for the non-identity fields. Identity columns are set by the context."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = proposal, attrs) do
    proposal
    |> cast(attrs, @editable)
    |> validate_required([
      :user_id,
      :agent_id,
      :org_id,
      :space_id,
      :first_message_id,
      :status,
      :expires_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:delivery, @deliveries)
    |> check_constraint(:status, name: :goal_proposals_status)
    |> check_constraint(:delivery, name: :goal_proposals_delivery)
    |> unique_constraint(:user_id, name: :goal_proposals_one_open)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:space_id)
    |> foreign_key_constraint(:goal_id)
  end
end
