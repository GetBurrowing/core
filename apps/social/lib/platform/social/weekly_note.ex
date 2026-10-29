defmodule Platform.Social.WeeklyNote.Item do
  @moduledoc "A stable suggestion and its human decision, stored in the note's JSONB list."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  embedded_schema do
    field(:kind, :string)
    field(:text, :string)
    field(:payload, :map, default: %{})
    field(:effect, :map, default: %{})
    field(:decision, :string)
    field(:decided_by_user_id, :binary_id)
    field(:decided_at, :utc_datetime_usec)
  end

  @doc false
  def submission_changeset(item, attrs) do
    item
    |> cast(attrs, [:id, :kind, :text, :payload])
    |> validate_required([:kind, :text])
    |> validate_inclusion(:kind, ~w(voice timing recycle other))
    |> validate_length(:text, max: 2000)
  end
end

defmodule Platform.Social.WeeklyNote do
  @moduledoc """
  Weekly suggestions (task 01a16c52), written only through WeeklyNotes.

  `week_start` is Monday of the delivery/decision week in the profile timezone.
  `facts/2` describes the immediately preceding completed local Monday week,
  with an inclusive start and exclusive finish. It never calls an LLM.
  Authorship and decisions are trusted service fields, never submission attrs.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social.{PostingSlot, Profile, Results}

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @type t :: %__MODULE__{}

  schema "social_weekly_notes" do
    belongs_to(:org, Platform.Tenancy.Org)
    belongs_to(:profile, Profile)
    field(:week_start, :date)
    field(:author_kind, :string)
    field(:author_id, :binary_id)
    field(:summary, :string)
    embeds_many(:items, Platform.Social.WeeklyNote.Item, on_replace: :delete)
    timestamps()
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:week_start, :summary])
    |> update_change(:summary, &String.trim/1)
    |> cast_embed(:items, with: &Platform.Social.WeeklyNote.Item.submission_changeset/2)
    |> validate_required([:org_id, :profile_id, :week_start, :author_kind, :summary])
    |> validate_length(:summary, max: 2000)
    |> validate_inclusion(:author_kind, ~w(agent system))
    |> validate_change(:week_start, fn :week_start, date ->
      if Date.day_of_week(date) == 1,
        do: [],
        else: [week_start: "must be Monday of the delivery week"]
    end)
    |> unique_constraint([:profile_id, :week_start])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:profile_id)
    |> check_constraint(:author_kind, name: :social_weekly_notes_author_check)
    |> check_constraint(:summary, name: :social_weekly_notes_summary_check)
    |> check_constraint(:week_start, name: :social_weekly_notes_monday_check)
  end

  @doc "UTC boundaries for the completed reporting week preceding delivery Monday."
  def reporting_window(%Profile{timezone: timezone}, %Date{} = week_start) do
    if Date.day_of_week(week_start) != 1,
      do: raise(ArgumentError, "week_start must be Monday of the delivery week")

    {midnight(Date.add(week_start, -7), timezone), midnight(week_start, timezone)}
  end

  @doc "Deterministic measured facts for the completed week preceding delivery Monday."
  def facts(%Profile{} = profile, %Date{} = week_start) do
    {start, finish} = reporting_window(profile, week_start)
    now = DateTime.add(finish, -1, :microsecond)
    rows = Results.by_idea([profile], 7, start_at: start, end_at: finish)
    accounts = Repo.preload(profile, :accounts, force: true).accounts |> Enum.sort_by(& &1.id)

    measured =
      rows
      |> Enum.filter(&(not is_nil(&1.idea_id) and is_number(&1.engagement)))
      |> Enum.map(&Map.put(&1, :platform_numbers, platform_numbers(&1.versions)))

    %{
      profile_id: profile.id,
      timezone: profile.timezone,
      week_start: week_start,
      reporting_week_start: Date.add(week_start, -7),
      start_at: start,
      end_at: finish,
      published_count: Enum.sum(Enum.map(rows, &length(&1.versions))),
      results: rows,
      top_ideas: Enum.take(measured, 3),
      bottom_ideas: measured |> Enum.sort_by(&{&1.engagement, &1.key}) |> Enum.take(3),
      timing_differences: Enum.flat_map(accounts, &timing_differences(&1, now)),
      recycle_candidates: Results.recycle_candidates([profile], now: now),
      goal_progress:
        Enum.map(
          accounts,
          &Results.weekly_progress(&1, start_at: start, end_at: finish, now: now)
        )
        |> Enum.reject(&is_nil/1)
    }
  end

  defp timing_differences(account, now) do
    case Results.best_times(account, now: now) do
      nil ->
        []

      result ->
        configured =
          MapSet.new(account.posting_slots, fn slot ->
            {slot.weekday, div(PostingSlot.local_time(slot).hour, 3) * 3}
          end)

        result.buckets
        |> Enum.reject(&MapSet.member?(configured, {&1.weekday, &1.hour}))
        |> Enum.sort_by(&{-&1.mean_engagement, &1.weekday, &1.hour})
        |> Enum.map(
          &Map.merge(&1, %{
            account_id: account.id,
            platform: account.platform,
            time: String.pad_leading(Integer.to_string(&1.hour), 2, "0") <> ":00",
            sample_count: result.count,
            timezone: result.timezone
          })
        )
    end
  end

  defp platform_numbers(versions) do
    versions
    |> Enum.group_by(& &1.platform)
    |> Map.new(fn {platform, versions} ->
      metrics =
        Map.new(hd(versions).metrics, fn {key, _} ->
          known = Enum.map(versions, & &1.metrics[key]) |> Enum.filter(&is_number/1)
          {key, if(known == [], do: nil, else: Enum.sum(known))}
        end)

      {platform, metrics}
    end)
  end

  defp midnight(date, timezone) do
    case DateTime.new(date, ~T[00:00:00], timezone) do
      {:ok, value} -> DateTime.shift_zone!(value, "Etc/UTC")
      {:ambiguous, first, _} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
    end
  end
end
