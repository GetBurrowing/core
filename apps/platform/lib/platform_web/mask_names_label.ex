defmodule PlatformWeb.MaskNamesLabel do
  @moduledoc """
  When screen-share name masking ends, as the viewer reads it (task 01a1600d
  stage 1). One formatter for the two places that say it: Settings' "On until
  9:41 pm" helper and the shell's "Names masked" chip.

  Times are in the viewer's IANA zone (the socket's `timezone` connect param,
  resolved by `PlatformWeb.MeetingLive.CalendarWindow.resolve_time_zone/1`).
  Without a zone, or with one that does not shift, the time is UTC and says
  so, rather than passing a UTC time off as local.
  """

  @doc """
  "until 9:41 pm", or "until 9:41 am tomorrow" when the local date of `until`
  is after the local date of `now`. nil when there is no `until`.

  With a nil or unknown zone the time and the date comparison are UTC:
  "until 9:41 pm UTC".
  """
  @spec until_text(DateTime.t() | nil, String.t() | nil, DateTime.t()) :: String.t() | nil
  def until_text(until, zone, now \\ DateTime.utc_now())

  def until_text(nil, _zone, _now), do: nil

  def until_text(%DateTime{} = until, zone, %DateTime{} = now) do
    {local_until, _utc?} = local(until, zone)
    {local_now, _utc?} = local(now, zone)

    day =
      if Date.compare(DateTime.to_date(local_until), DateTime.to_date(local_now)) == :gt,
        do: " tomorrow",
        else: ""

    "until " <> clock(until, zone) <> day
  end

  @doc """
  The clock time of `at` in `zone`: "9:41 pm", or "9:41 pm UTC" when the zone
  is nil or unknown.
  """
  @spec clock(DateTime.t(), String.t() | nil) :: String.t()
  def clock(%DateTime{} = at, zone) do
    case local(at, zone) do
      {local, false} -> Calendar.strftime(local, "%-I:%M %P")
      {utc, true} -> Calendar.strftime(utc, "%-I:%M %P") <> " UTC"
    end
  end

  defp local(at, zone) do
    case zone && DateTime.shift_zone(at, zone) do
      {:ok, local} -> {local, false}
      _ -> {at, true}
    end
  end
end
