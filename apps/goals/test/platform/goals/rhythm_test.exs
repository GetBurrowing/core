defmodule Platform.Goals.RhythmTest do
  use ExUnit.Case, async: true
  alias Platform.Goals.Rhythm

  defp settings(rhythm, weekday \\ 3, anchor \\ nil),
    do: %{
      rhythm: rhythm,
      rhythm_weekday: weekday,
      anchor_on: anchor,
      wake_hour: 6,
      time_zone: "America/Chicago"
    }

  defp local(slot), do: DateTime.shift_zone!(slot, "America/Chicago")

  test "daily from Wednesday and weekdays from Friday" do
    assert {:ok, slot} = Rhythm.next_slot(~U[2026-03-04 13:00:00Z], settings("daily"))
    assert local(slot) == DateTime.from_naive!(~N[2026-03-05 06:00:00], "America/Chicago")
    assert {:ok, slot} = Rhythm.next_slot(~U[2026-03-06 13:00:00Z], settings("weekdays"))
    assert local(slot) == DateTime.from_naive!(~N[2026-03-09 06:00:00], "America/Chicago")
  end

  test "weekly is strictly after and ISO Sunday maps to zero" do
    assert {:ok, slot} = Rhythm.next_slot(~U[2026-03-04 12:00:00Z], settings("weekly"))
    assert DateTime.to_date(local(slot)) == ~D[2026-03-11]
    assert {:ok, slot} = Rhythm.next_slot(~U[2026-03-04 13:00:00Z], settings("weekly", 7))
    assert Date.day_of_week(DateTime.to_date(local(slot))) == 7
    assert Rhythm.cron("weekly", nil, 6) == "0 6 * * 1"
  end

  test "biweekly follows local anchor in fourteen-day steps across DST" do
    settings = settings("biweekly", 3, ~D[2026-03-04])
    assert {:ok, first} = Rhythm.next_slot(~U[2026-03-04 12:00:00Z], settings)
    assert DateTime.to_date(local(first)) == ~D[2026-03-18]
    assert {:ok, second} = Rhythm.next_slot(first, settings)
    assert Date.diff(DateTime.to_date(local(second)), DateTime.to_date(local(first))) == 14
    assert local(first).hour == 6
    assert {:ok, slot} = Rhythm.next_slot(~U[2026-03-04 12:00:00Z], %{settings | anchor_on: nil})
    assert DateTime.to_date(local(slot)) == ~D[2026-03-11]
  end

  test "DST preserves local wake hour and bad zones are invalid" do
    assert {:ok, slot} = Rhythm.next_slot(~U[2026-03-07 13:00:00Z], settings("daily"))
    assert slot == ~U[2026-03-08 11:00:00Z]
    refute Rhythm.valid_time_zone?("Mars/Olympus")
    assert Rhythm.valid_time_zone?("America/Chicago")

    assert Rhythm.schedule_key(%{rhythm: "daily", rhythm_weekday: nil}, 6, "Etc/UTC") ==
             "daily:-:6:Etc/UTC"
  end
end
