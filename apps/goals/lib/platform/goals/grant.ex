defmodule Platform.Goals.Grant do
  @moduledoc """
  Who a goal is opened to (task 01a1dfc0, Goals 1/8), read only: one user, one
  team, or one space. A team is an ORG row (core has no team table). A space
  grant IS the goal's link to that space; there is no other link column.

  Exactly the column matching `audience_type` is set (`user` -> `user_id`,
  `team` -> `org_id`, `space` -> `space_id`), held by the CHECK
  `goal_grants_one_audience`; the same audience twice on one goal is refused
  by a partial unique index per column. `goal_id` and `granted_by_user_id`
  are set by the context from the goal and the actor, never cast.

  The hand-off columns (task 01a1dfc1-dffb, Goals 7/8) are set only by the
  context, never cast from attrs: `handed_at` and `handed_by_user_id` say the
  space's agents were given the goal (`Platform.Goals.Handoff`), and the
  CHECK `goal_grants_handoff_only_space` keeps them on space grants;
  `card_canvas_id` and the `last_update_*` columns record the card and the
  last progress update placed in that space.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @audience_types ~w(user team space)
  @audience_columns %{"user" => :user_id, "team" => :org_id, "space" => :space_id}

  @type t :: %__MODULE__{}

  schema "goal_grants" do
    belongs_to(:goal, Platform.Goals.Goal)
    field(:audience_type, :string)
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:space, Platform.Chat.Space)
    belongs_to(:granted_by_user, Platform.Accounts.User)
    field(:handed_at, :utc_datetime_usec)
    belongs_to(:handed_by_user, Platform.Accounts.User)
    field(:card_canvas_id, :binary_id)
    belongs_to(:last_update_wake_up, Platform.Goals.WakeUp)
    field(:last_update_at, :utc_datetime_usec)
    field(:last_update_number, :string)

    timestamps()
  end

  @doc "The allowed audience types."
  def audience_types, do: @audience_types

  @doc """
  Changeset for the audience. `goal_id` and `granted_by_user_id` are set by
  the context.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = grant, attrs) do
    grant
    |> cast(attrs, [:audience_type, :user_id, :org_id, :space_id])
    |> validate_required([:goal_id, :audience_type])
    |> validate_inclusion(:audience_type, @audience_types)
    |> validate_one_audience()
    |> name_constraints()
  end

  defp validate_one_audience(changeset) do
    case Map.fetch(@audience_columns, get_field(changeset, :audience_type)) do
      {:ok, column} ->
        set = for c <- Map.values(@audience_columns), get_field(changeset, c) != nil, do: c

        if set == [column],
          do: changeset,
          else: add_error(changeset, :audience_type, "must set exactly #{column}")

      :error ->
        changeset
    end
  end

  @doc """
  Names every database constraint on the table, so a value the database
  refuses comes back as a changeset error, not a raise. `changeset/2` pipes
  through it; a caller writing a raw `change/2` can too.
  """
  @spec name_constraints(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def name_constraints(changeset) do
    changeset
    |> check_constraint(:audience_type, name: :goal_grants_audience_type_check)
    |> check_constraint(:audience_type, name: :goal_grants_one_audience)
    |> check_constraint(:handed_at, name: :goal_grants_handoff_only_space)
    |> unique_constraint(:user_id, name: :goal_grants_goal_id_user_id_index)
    |> unique_constraint(:org_id, name: :goal_grants_goal_id_org_id_index)
    |> unique_constraint(:space_id, name: :goal_grants_goal_id_space_id_index)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:space_id)
    |> foreign_key_constraint(:handed_by_user_id)
    |> foreign_key_constraint(:card_canvas_id)
    |> foreign_key_constraint(:last_update_wake_up_id)
  end
end
