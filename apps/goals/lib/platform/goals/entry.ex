defmodule Platform.Goals.Entry do
  @moduledoc """
  One notebook entry on a goal (task 01a1dfc0, Goals 1/8): a wake-up, an
  action, an ask, a wait, a takeaway or a retro.

  A prediction is three optional fields: the sentence (`prediction`), the
  expected change in the goal's unit (`predicted_change`) and by when
  (`predicted_by`). `sources` is a list of maps with `"name"` and an optional
  `"url"`; `details` holds kind-specific content (a takeaway's "what we're
  doing about it", a retro's breakdown and keep/start/stop suggestions).
  `takeaway_id` names the takeaway a suggestion came from; `stop_id` the stop
  a retro looks back on.

  `goal_id` and the author fields (`author_type`, `author_user_id`,
  `author_agent_id`) are set by the context from the goal and the actor,
  never cast from attrs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(wake_up action ask wait takeaway retro)
  @author_types ~w(user agent)

  @type t :: %__MODULE__{}

  schema "goal_entries" do
    belongs_to(:goal, Platform.Goals.Goal)

    field(:kind, :string)
    field(:title, :string)
    field(:body, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:author_type, :string)
    belongs_to(:author_user, Platform.Accounts.User)
    belongs_to(:author_agent, Platform.Agents.Agent)
    field(:prediction, :string)
    field(:predicted_change, :decimal)
    field(:predicted_by, :date)
    field(:sources, {:array, :map}, default: [])
    field(:details, :map, default: %{})
    belongs_to(:takeaway, __MODULE__)
    belongs_to(:stop, Platform.Goals.Stop)
    belongs_to(:reading, Platform.Goals.Reading)

    timestamps()
  end

  @editable ~w(kind title body occurred_at prediction predicted_change predicted_by sources details
               takeaway_id stop_id reading_id)a

  @doc "The allowed values of each checked column."
  def kinds, do: @kinds
  def author_types, do: @author_types

  @doc """
  Changeset for the editable fields. `goal_id` and the author fields are set
  by the context from the actor, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, @editable)
    |> validate_required([:goal_id, :kind, :occurred_at, :author_type, :sources, :details])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:author_type, @author_types)
    |> validate_takeaway()
    |> name_constraints()
  end

  # Goals 5/8 (task 01a1dfc1-7625): a takeaway is a finding, so it binds
  # every writer, the owner included: a non-blank title and at least one
  # source with a non-blank "name", at most `Limits.max_sources/0` sources.
  defp validate_takeaway(changeset) do
    if get_field(changeset, :kind) == "takeaway" do
      changeset
      |> validate_required([:title])
      |> validate_takeaway_sources()
    else
      changeset
    end
  end

  defp validate_takeaway_sources(changeset) do
    sources = get_field(changeset, :sources) || []
    max = Platform.Goals.Limits.max_sources()

    cond do
      not Enum.any?(sources, &named_source?/1) ->
        add_error(changeset, :sources, "a takeaway needs at least one source with a name",
          validation: :named_source
        )

      length(sources) > max ->
        add_error(changeset, :sources, "at most %{count} sources", count: max)

      true ->
        changeset
    end
  end

  defp named_source?(%{} = source) do
    name = Map.get(source, "name", Map.get(source, :name))
    is_binary(name) and String.trim(name) != ""
  end

  defp named_source?(_source), do: false

  @doc """
  Names every database constraint on the table, so a value the database
  refuses comes back as a changeset error, not a raise. `changeset/2` pipes
  through it; a caller writing a raw `change/2` can too.
  """
  @spec name_constraints(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def name_constraints(changeset) do
    changeset
    |> check_constraint(:kind, name: :goal_entries_kind_check)
    |> check_constraint(:author_type, name: :goal_entries_author_type_check)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:takeaway_id)
    |> foreign_key_constraint(:stop_id)
    |> foreign_key_constraint(:reading_id)
  end
end
