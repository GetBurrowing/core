defmodule Platform.Goals.Goal do
  @moduledoc """
  A goal (task 01a1dfc0, Goals 1/8): what its owner wants, why, the number
  that measures it (optional: a goal may have no number yet) and how its
  agent works on it. Its stops (`Platform.Goals.Stop`), grants
  (`Platform.Goals.Grant`) and notebook entries (`Platform.Goals.Entry`) are
  deleted with it (FK `delete_all`).

  `owner_user_id` and `org_id` are set by the context from the actor, never
  cast from attrs, so a goal cannot change hands or orgs through attrs.

  `agent_mode`: `do` = the agent does the work itself; `advise` = it only
  advises; `coach` = the owner practises and the agent plans and prepares
  practice material. `rhythm_weekday` is ISO (1 = Monday), used by `weekly`
  and `biweekly`. `source_key` is free text on purpose: a later member adds a
  number source without touching the table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(personal shared)
  @statuses ~w(active paused finished)
  @agent_modes ~w(do advise coach)
  @rhythms ~w(daily weekdays weekly biweekly)
  @outreaches ~w(off gentle pushy)

  @type t :: %__MODULE__{}

  schema "goals" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:owner_user, Platform.Accounts.User)
    belongs_to(:coach_agent, Platform.Agents.Agent)

    field(:title, :string)
    field(:why, :string)
    field(:kind, :string, default: "personal")
    field(:status, :string, default: "active")
    field(:unit, :string)
    field(:target_value, :decimal)
    field(:source_key, :string)
    field(:source_settings, :map, default: %{})
    field(:agent_mode, :string, default: "advise")
    field(:rhythm, :string, default: "weekly")
    field(:rhythm_weekday, :integer)
    field(:retro_every, :integer)
    field(:outreach, :string, default: "gentle")

    has_many(:stops, Platform.Goals.Stop)
    has_many(:grants, Platform.Goals.Grant)
    has_many(:entries, Platform.Goals.Entry)

    timestamps()
  end

  @editable ~w(coach_agent_id title why kind status unit target_value source_key source_settings
               agent_mode rhythm rhythm_weekday outreach retro_every)a

  @doc "The allowed values of each checked column."
  def kinds, do: @kinds
  def statuses, do: @statuses
  def agent_modes, do: @agent_modes
  def rhythms, do: @rhythms
  def outreaches, do: @outreaches

  @doc """
  Changeset for the editable fields. `owner_user_id` and `org_id` are never
  cast: the context sets them on the struct from the actor.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = goal, attrs) do
    goal
    |> cast(attrs, @editable)
    |> validate_required([:org_id, :owner_user_id, :title, :kind, :status, :agent_mode, :rhythm])
    |> validate_required([:outreach, :source_settings])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:agent_mode, @agent_modes)
    |> validate_inclusion(:rhythm, @rhythms)
    |> validate_inclusion(:outreach, @outreaches)
    |> validate_number(:rhythm_weekday, greater_than_or_equal_to: 1, less_than_or_equal_to: 7)
    |> validate_number(:retro_every, greater_than_or_equal_to: 2, less_than_or_equal_to: 60)
    |> name_constraints()
  end

  @doc """
  Names every database constraint on the table, so a value the database
  refuses comes back as a changeset error, not a raise. `changeset/2` pipes
  through it; a caller writing a raw `change/2` can too.
  """
  @spec name_constraints(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def name_constraints(changeset) do
    changeset
    |> check_constraint(:retro_every, name: :goals_retro_every)
    |> check_constraint(:kind, name: :goals_kind_check)
    |> check_constraint(:status, name: :goals_status_check)
    |> check_constraint(:agent_mode, name: :goals_agent_mode_check)
    |> check_constraint(:rhythm, name: :goals_rhythm_check)
    |> check_constraint(:rhythm_weekday, name: :goals_rhythm_weekday_check)
    |> check_constraint(:outreach, name: :goals_outreach_check)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:coach_agent_id)
  end
end
