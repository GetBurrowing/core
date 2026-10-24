defmodule Platform.Social.Slots do
  @moduledoc """
  Posting slots as instants (Social authoring 4/11, task 01a16c4f-9041).

  An account's `posting_slots` are weekly `%{weekday, time}` pairs read in
  its PROFILE's timezone (`profile.timezone`, IANA), so "Monday 09:00" in
  America/Denver is 15:00Z in summer time and 16:00Z after the clocks go
  back. Everything here returns UTC `DateTime`s (second precision).

  ## DST

  A local time can be missing or repeated on a change day:

    * in the spring-forward gap (02:30 when 02:00 jumps to 03:00) the slot
      resolves to the first instant after the gap (03:00 local);
    * in the fall-back overlap (01:30 happens twice) it resolves to the
      FIRST 01:30 (the earlier instant).

  ## Taken

  A slot is taken when a post of the same account whose status is one of
  `Platform.Social.Post.approved_statuses/0` (approved, scheduled,
  published) has `scheduled_at` inside the slot's minute
  (`[slot, slot + 60s)`). Drafts and needs_approval posts never hold a slot.
  Nothing here reserves a slot: the caller writes `scheduled_at` itself.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Social.{Account, Post, PostingSlot, Profile}

  @horizon_weeks 53

  @type week_slot :: %{
          account_id: Ecto.UUID.t(),
          platform: String.t(),
          weekday: 1..7,
          time: String.t(),
          at: DateTime.t(),
          taken?: boolean()
        }

  @doc """
  The first slot of `account` at or after `after_at` with no approved,
  scheduled or published post of that account in it, as a UTC `DateTime`.
  nil when the account has no slots, is archived, or every slot in the next
  #{@horizon_weeks} weeks is taken.
  """
  @spec next_free(Account.t(), DateTime.t()) :: DateTime.t() | nil
  def next_free(%Account{archived_at: archived}, _after) when not is_nil(archived), do: nil
  def next_free(%Account{posting_slots: []}, _after), do: nil
  def next_free(%Account{posting_slots: nil}, _after), do: nil

  def next_free(%Account{} = account, %DateTime{} = after_at) do
    tz = timezone(Repo.get(Profile, account.profile_id))
    after_at = DateTime.truncate(after_at, :second)
    first_day = after_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()

    Enum.find_value(0..(@horizon_weeks - 1), fn week ->
      from_day = Date.add(first_day, week * 7)

      candidates =
        from_day
        |> instants(Date.add(from_day, 6), account.posting_slots, tz)
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(&(DateTime.compare(&1, after_at) != :lt))

      taken = taken_minutes(account.id, candidates)
      Enum.find(candidates, &(not MapSet.member?(taken, &1)))
    end)
  end

  @doc """
  Every slot instant of the profile's live (non-archived) accounts in the
  LOCAL week that contains `monday` (any date in it; the week runs Monday
  to Sunday in the profile's timezone), sorted by instant. Each is
  `%{account_id, platform, weekday, time, at, taken?}`, `at` in UTC. For
  calendar shading (8/11).
  """
  @spec slots_in_week(Profile.t(), Date.t()) :: [week_slot()]
  def slots_in_week(%Profile{} = profile, %Date{} = monday) do
    tz = timezone(profile)
    monday = Date.beginning_of_week(monday)

    accounts =
      Repo.all(
        from(a in Account,
          where: a.profile_id == ^profile.id and is_nil(a.archived_at),
          order_by: [asc: a.inserted_at, asc: a.id]
        )
      )

    Enum.flat_map(accounts, fn account ->
      slots = instants(monday, Date.add(monday, 6), account.posting_slots || [], tz)
      taken = taken_minutes(account.id, Enum.map(slots, &elem(&1, 1)))

      Enum.map(slots, fn {slot, at} ->
        %{
          account_id: account.id,
          platform: account.platform,
          weekday: slot.weekday,
          time: slot.time,
          at: at,
          taken?: MapSet.member?(taken, at)
        }
      end)
    end)
    |> Enum.sort_by(& &1.at, DateTime)
  end

  @doc """
  The UTC instant of a local `date` and `time` in `tz`, resolving the DST
  gap and overlap as the moduledoc says.
  """
  @spec resolve(Date.t(), Time.t(), String.t()) :: DateTime.t()
  def resolve(%Date{} = date, %Time{} = time, tz) do
    local =
      case DateTime.new(date, time, tz) do
        {:ok, dt} -> dt
        {:ambiguous, first, _second} -> first
        {:gap, _before, just_after} -> just_after
      end

    local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  # {slot, utc_instant} for each slot on each local day in from..to, sorted.
  defp instants(from_day, to_day, slots, tz) do
    Date.range(from_day, to_day)
    |> Enum.flat_map(fn day ->
      weekday = Date.day_of_week(day)

      slots
      |> Enum.filter(&(&1.weekday == weekday))
      |> Enum.map(&{&1, resolve(day, PostingSlot.local_time(&1), tz)})
    end)
    |> Enum.sort_by(&elem(&1, 1), DateTime)
  end

  # The candidate instants that a holding post of the account occupies.
  defp taken_minutes(_account_id, []), do: MapSet.new()

  defp taken_minutes(account_id, candidates) do
    first = Enum.min(candidates, DateTime)
    last = candidates |> Enum.max(DateTime) |> DateTime.add(60, :second)
    statuses = Post.approved_statuses()

    scheduled =
      Repo.all(
        from(p in Post,
          where:
            p.account_id == ^account_id and p.status in ^statuses and
              p.scheduled_at >= ^first and p.scheduled_at < ^last,
          select: p.scheduled_at
        )
      )

    candidates
    |> Enum.filter(fn slot ->
      Enum.any?(scheduled, fn at ->
        DateTime.compare(at, slot) != :lt and DateTime.diff(at, slot, :second) < 60
      end)
    end)
    |> MapSet.new()
  end

  defp timezone(%Profile{timezone: tz}) when is_binary(tz) and tz != "", do: tz
  defp timezone(_), do: "Etc/UTC"
end
