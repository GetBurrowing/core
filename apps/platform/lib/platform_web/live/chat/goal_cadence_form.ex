defmodule PlatformWeb.ChatLive.GoalCadenceForm do
  @moduledoc """
  View helpers for the goal editor's "Check progress" control and the
  strip's cadence tail (task 01a0e882 stage 3, Saru's canvas "Design
  direction: goal check cadence").

  Everything here speaks in words and wall-clock times. It builds cron
  only through `Platform.Responsibilities.GoalCadence` and never returns
  an expression, so no cron string can reach the rendered page.

  Zones: `zone` is the viewer's IANA zone as resolved by
  `PlatformWeb.MeetingLive.CalendarWindow.resolve_time_zone/1`, or nil.
  nil and UTC both render UTC labels with no "UTC" suffix.
  """

  alias Platform.Responsibilities
  alias Platform.Responsibilities.{Cron, GoalCadence}

  @cadence_values %{
    "hourly" => :hourly,
    "every_4h" => :every_4h,
    "twice_daily" => :twice_daily,
    "daily" => :daily,
    "off" => :off,
    "custom" => :custom
  }

  # The local wall-clock hour a fresh "Once a day" pick starts on.
  @default_local_hour 9

  @type selection :: %{cadence: GoalCadence.cadence() | :custom, hour_utc: 0..23 | nil}

  @doc """
  Apply the form's `goal_cadence` / `goal_cadence_hour` params to the
  current selection. A value outside the list keeps the current cadence;
  a missing or invalid hour keeps the current hour (the "at" select is
  only rendered once "Once a day" is chosen, so the first change to daily
  carries no hour).
  """
  @spec change(selection(), map()) :: selection()
  def change(%{cadence: cadence, hour_utc: hour}, params) when is_map(params) do
    %{
      cadence: Map.get(@cadence_values, Map.get(params, "goal_cadence"), cadence),
      hour_utc:
        case parse_hour(Map.get(params, "goal_cadence_hour")) do
          {:ok, parsed} -> parsed
          :error -> hour
        end
    }
  end

  @doc "True when the submit carries the cadence control at all."
  @spec present?(map()) :: boolean()
  def present?(params), do: is_binary(Map.get(params, "goal_cadence"))

  @doc """
  The write the selection asks for, or nil when it asks for none:
  `:custom` is not settable, and a selection equal to `reading` is no
  change. Daily compares its hour; other cadences ignore it.
  """
  @spec requested_change(selection(), GoalCadence.reading()) ::
          {GoalCadence.cadence(), 0..23 | nil} | nil
  def requested_change(%{cadence: :custom}, _reading), do: nil

  def requested_change(%{cadence: :daily, hour_utc: hour}, reading) do
    if reading == %{cadence: :daily, hour_utc: hour}, do: nil, else: {:daily, hour}
  end

  def requested_change(%{cadence: cadence}, %{cadence: cadence}), do: nil
  def requested_change(%{cadence: cadence}, _reading), do: {cadence, nil}

  defp parse_hour(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {hour, ""} when hour in 0..23 -> {:ok, hour}
      _ -> :error
    end
  end

  defp parse_hour(hour) when is_integer(hour) and hour in 0..23, do: {:ok, hour}
  defp parse_hour(_raw), do: :error

  @doc """
  The viewer's IANA zone from the LiveSocket connect params
  (`assets/js/app.js`), validated at `CalendarWindow`'s single choke point.
  nil on the dead render and for a zone Tzdata does not know; the labels
  then render UTC.
  """
  @spec time_zone(map() | nil) :: String.t() | nil
  def time_zone(%{"timezone" => zone}),
    do: PlatformWeb.MeetingLive.CalendarWindow.resolve_time_zone(zone)

  def time_zone(_connect_params), do: nil

  @doc "The stored reading behind a goal panel; the context's when absent."
  @spec stored(map() | nil) :: GoalCadence.reading()
  def stored(%{cadence: %{cadence: _} = reading}), do: reading
  def stored(_panel), do: Responsibilities.goal_heartbeat_cadence()

  @doc "The selection the editor opens on for `panel`."
  @spec open(map() | nil, String.t() | nil) :: selection()
  def open(panel, zone), do: initial(stored(panel), zone, DateTime.utc_now())

  @doc """
  Apply a `save_goal` submit's cadence params. `:ok` when there is nothing
  to write (no control in the submit, `:custom`, or no change) or the
  write succeeded; `{:error, message}` for the flash otherwise. The
  context re-checks admin and audits, so this is safe to call for any
  actor.
  """
  @spec save(map(), map() | nil, selection() | nil, String.t() | nil, map()) ::
          :ok | {:error, String.t()}
  def save(actor, panel, form, zone, params) do
    stored = stored(panel)
    base = form || initial(stored, zone, DateTime.utc_now())

    with true <- present?(params),
         {cadence, hour} <- requested_change(change(base, params), stored) do
      case Responsibilities.set_goal_heartbeat_cadence(actor, cadence, hour_utc: hour) do
        {:ok, _} -> :ok
        {:error, :forbidden} -> {:error, "You cannot change how often agents check progress."}
        {:error, _} -> {:error, "Could not change how often agents check progress."}
      end
    else
      _ -> :ok
    end
  end

  @doc """
  The form's opening selection for a stored reading. A daily pick keeps
  its stored hour; any other cadence pre-selects the UTC hour of 9:00 AM
  in the viewer's zone, so switching to "Once a day" starts on a sensible
  morning time.
  """
  @spec initial(GoalCadence.reading(), String.t() | nil, DateTime.t()) :: selection()
  def initial(%{cadence: :daily, hour_utc: hour} = reading, _zone, _now)
      when is_integer(hour),
      do: reading

  def initial(%{cadence: cadence}, zone, %DateTime{} = now),
    do: %{cadence: cadence, hour_utc: default_hour_utc(zone, now)}

  @doc "`{label, value}` options for the Check progress select."
  @spec cadence_options(selection() | nil) :: [{String.t(), String.t()}]
  def cadence_options(selection) do
    base = Enum.map(GoalCadence.cadences(), &{GoalCadence.label(&1), Atom.to_string(&1)})

    if match?(%{cadence: :custom}, selection),
      do: base ++ [{GoalCadence.label(:custom), "custom"}],
      else: base
  end

  @doc """
  24 `{label, utc_hour}` options for the "at" select, in the viewer's
  local order (12:00 AM first). The label is the local wall-clock time of
  that UTC hour on `now`'s UTC date.
  """
  @spec hour_options(String.t() | nil, DateTime.t()) :: [{String.t(), 0..23}]
  def hour_options(zone, %DateTime{} = now) do
    date = DateTime.to_date(now)

    0..23
    |> Enum.map(fn hour ->
      local = utc_hour_on(date, hour) |> to_zone(zone)
      {local.hour * 60 + local.minute, {clock(local), hour}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The one-line preview under the selects. A concrete next time in the
  viewer's zone, with the UTC time in parentheses only when the zone is
  not UTC; the Off sentence for Off.
  """
  @spec preview(selection(), String.t() | nil, DateTime.t()) :: String.t()
  def preview(%{cadence: :off}, _zone, _now),
    do: "Agents will not check progress on this goal until you turn it back on."

  def preview(%{cadence: :custom}, _zone, _now),
    do: "Agents keep checking on the current custom schedule."

  def preview(%{cadence: cadence, hour_utc: hour}, zone, %DateTime{} = now) do
    with {:ok, %{trigger_config: %{"expression" => expression}}} <-
           GoalCadence.to_trigger(cadence, hour),
         {:ok, spec} <- Cron.parse(expression),
         {:ok, next} <- Cron.next_fire_after(now, spec) do
      local_next = to_zone(next, zone)
      local_now = to_zone(now, zone)
      suffix = if utc?(zone), do: "", else: " (#{Calendar.strftime(next, "%H:%M")} UTC)"
      "Next check: #{day_word(local_now, local_next)} at #{clock(local_next)}#{suffix}"
    else
      _ -> ""
    end
  end

  @doc """
  The strip's cadence tail, or nil. Hourly (the default) adds nothing.
  """
  @spec tail(GoalCadence.cadence() | :custom | nil) :: String.t() | nil
  def tail(:every_4h), do: "· checked every 4 h"
  def tail(:twice_daily), do: "· checked twice a day"
  def tail(:daily), do: "· checked daily"
  def tail(:off), do: "· not checked automatically"
  def tail(:custom), do: "· checked on a custom schedule"
  def tail(_hourly_or_nil), do: nil

  # ── time helpers ─────────────────────────────────────────────────────────

  defp default_hour_utc(zone, %DateTime{} = now) do
    local_date = now |> to_zone(zone) |> DateTime.to_date()

    case DateTime.new(local_date, Time.new!(@default_local_hour, 0, 0), zone_name(zone)) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC").hour
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC").hour
      {:gap, _, dt} -> DateTime.shift_zone!(dt, "Etc/UTC").hour
      {:error, _} -> @default_local_hour
    end
  end

  defp utc_hour_on(date, hour), do: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

  defp to_zone(dt, zone) do
    if utc?(zone) do
      dt
    else
      case DateTime.shift_zone(dt, zone) do
        {:ok, shifted} -> shifted
        {:error, _} -> dt
      end
    end
  end

  defp utc?(zone), do: zone in [nil, "", "UTC", "Etc/UTC"]

  defp zone_name(zone), do: if(utc?(zone), do: "Etc/UTC", else: zone)

  defp clock(dt), do: Calendar.strftime(dt, "%-I:%M %p")

  defp day_word(local_now, local_next) do
    case Date.diff(DateTime.to_date(local_next), DateTime.to_date(local_now)) do
      0 -> "today"
      1 -> "tomorrow"
      _ -> Calendar.strftime(local_next, "%A")
    end
  end
end
