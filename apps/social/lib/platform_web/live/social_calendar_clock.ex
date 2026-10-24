defmodule PlatformWeb.SocialCalendarClock do
  @moduledoc """
  The Calendar's clock (Social authoring 8/11): which zone the week is drawn
  in, the week's UTC bounds in that zone, and each account's posting slots
  placed in the drawn week.

  The zone and slot DATA belong to Social authoring 4/11 (task
  01a16c4f-9041): `social_profiles.timezone` and
  `social_accounts.posting_slots` (`[%{weekday: 1..7, time: "HH:MM"}]` in
  the profile's zone). This module is the one boundary the Calendar reads
  them through, so it reads the fields only if the schema has them:

    * `profile_zone/1` - the profile's `timezone` when it is a Tzdata zone,
      else `"Etc/UTC"`.
    * `account_slots/1` - the account's `posting_slots`, else `[]`.

  Before 4/11 is on main both answer the defaults (UTC, no slots), so the
  calendar draws in UTC with no shading. TODO(01a16c4f-9041): once
  `Platform.Social.Slots.slots_in_week/2` is on main, have `slots_in_week/4`
  call it rather than reading `posting_slots` here.
  """

  @utc "Etc/UTC"

  @doc "The fallback zone."
  def utc, do: @utc

  @doc "`zone` when Tzdata knows it, else nil. Never raises on client input."
  @spec valid_zone(term()) :: String.t() | nil
  def valid_zone(zone) when is_binary(zone) and byte_size(zone) in 1..64 do
    if Tzdata.zone_exists?(zone), do: zone, else: nil
  end

  def valid_zone(_zone), do: nil

  @doc "The profile's drawing zone (4/11's `timezone`), falling back to UTC."
  def profile_zone(%{} = profile), do: valid_zone(Map.get(profile, :timezone)) || @utc
  def profile_zone(_profile), do: @utc

  @doc "The zone's display name: \"UTC\" for UTC, else the IANA name."
  def label(zone) when zone in [@utc, "UTC", "Etc/UCT", "Etc/Zulu"], do: "UTC"
  def label(zone), do: zone

  @doc "The zone's abbreviation at the start of the week (e.g. \"MDT\"), for a narrow column head."
  def abbreviation(%Date{} = monday, zone), do: at_local(monday, ~T[12:00:00], zone).zone_abbr

  @doc "Today's date in `zone`."
  def today(zone), do: DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  @doc "`at` (any zone) shifted into `zone`."
  def local(%DateTime{} = at, zone), do: DateTime.shift_zone!(at, zone)

  @doc """
  Local `date` at `time` in `zone`: the earlier instant when the wall time
  repeats, the first instant after the change when it is skipped.
  """
  def at_local(%Date{} = date, %Time{} = time, zone) do
    case DateTime.new(date, time, zone) do
      {:ok, at} -> at
      {:ambiguous, first, _second} -> first
      {:gap, _before, just_after} -> just_after
    end
  end

  @doc "Half-open UTC bounds of the week starting `monday`, midnight to midnight in `zone`."
  def week_bounds(%Date{} = monday, zone) do
    {to_utc(at_local(monday, ~T[00:00:00], zone)),
     to_utc(at_local(Date.add(monday, 7), ~T[00:00:00], zone))}
  end

  defp to_utc(at), do: DateTime.shift_zone!(at, @utc)

  @doc "The account's posting slots as `[{weekday, %Time{}}]` (4/11's field; `[]` before it)."
  def account_slots(%{} = account) do
    account
    |> Map.get(:posting_slots)
    |> List.wrap()
    |> Enum.flat_map(fn slot ->
      with weekday when weekday in 1..7 <- field(slot, :weekday),
           time when is_binary(time) <- field(slot, :time),
           {:ok, time} <- Time.from_iso8601(normalize_time(time)) do
        [{weekday, time}]
      else
        _ -> []
      end
    end)
  end

  def account_slots(_account), do: []

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_other, _key), do: nil

  defp normalize_time(<<_::binary-size(5)>> = hh_mm), do: hh_mm <> ":00"
  defp normalize_time(time), do: time

  @doc """
  `account`'s slots in the week starting `monday` as drawn in `draw_zone`:
  each `%{account_id, date, hour, time}` in `draw_zone`. A slot is a wall
  time in `profile_zone`, so it is resolved to an instant on its own date
  (DST-aware) and only then shifted to the drawing zone.
  """
  def slots_in_week(account, profile_zone, %Date{} = monday, draw_zone) do
    slots = account_slots(account)
    days = Date.range(Date.add(monday, -1), Date.add(monday, 7))

    for {weekday, time} <- slots,
        date <- days,
        Date.day_of_week(date) == weekday,
        local = date |> at_local(time, profile_zone) |> local(draw_zone),
        local_date = DateTime.to_date(local),
        Date.diff(local_date, monday) in 0..6 do
      %{
        account_id: Map.get(account, :id),
        date: local_date,
        hour: local.hour,
        time: Calendar.strftime(local, "%H:%M")
      }
    end
    |> Enum.sort_by(&{&1.date, &1.time}, :asc)
  end
end
