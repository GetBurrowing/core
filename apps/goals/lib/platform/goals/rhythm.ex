defmodule Platform.Goals.Rhythm do
  @moduledoc "Pure goal slots using core's timezone-aware cron (task 01a1dfc1-05b0)."
  alias Platform.Responsibilities.Cron
  def cron("daily", _weekday, hour), do: "0 #{hour} * * *"
  def cron("weekdays", _weekday, hour), do: "0 #{hour} * * 1-5"

  def cron(rhythm, weekday, hour) when rhythm in ["weekly", "biweekly"],
    do: "0 #{hour} * * #{rem(weekday || 1, 7)}"

  def next_slot(after_time, settings) do
    zone = if valid_time_zone?(settings.time_zone), do: settings.time_zone, else: "Etc/UTC"

    with {:ok, spec} <-
           Cron.parse(cron(settings.rhythm, settings.rhythm_weekday, settings.wake_hour)) do
      candidate(after_time, spec, zone, settings.rhythm, settings.anchor_on)
    end
  end

  defp candidate(after_time, spec, zone, rhythm, anchor) do
    with {:ok, slot} <- Cron.next_fire_after(after_time, spec, timezone: zone) do
      local_date = slot |> DateTime.shift_zone!(zone) |> DateTime.to_date()

      if rhythm != "biweekly" or is_nil(anchor) or rem(Date.diff(local_date, anchor), 14) == 0,
        do: {:ok, slot},
        else:
          if(rem(Date.diff(local_date, anchor), 7) == 0,
            do: candidate(slot, spec, zone, rhythm, anchor),
            else: {:error, :unaligned_anchor}
          )
    end
  end

  def schedule_key(goal, hour, zone),
    do: "#{goal.rhythm}:#{goal.rhythm_weekday || "-"}:#{hour}:#{zone}"

  def valid_time_zone?(zone) when is_binary(zone) do
    case DateTime.now(zone) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def valid_time_zone?(_), do: false
end
