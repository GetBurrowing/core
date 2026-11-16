defmodule Platform.Goals.LimitsTest do
  use ExUnit.Case, async: false
  alias Platform.Goals.Limits

  test "defaults and install override" do
    previous = Application.fetch_env(:goals, :limits)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :limits, value)
        :error -> Application.delete_env(:goals, :limits)
      end
    end)

    Application.delete_env(:goals, :limits)

    for {key, expected} <- [
          tick_interval_ms: 60000,
          tick_batch: 50,
          pace_after_ignored_briefs: 3,
          paced_max_open_asks: 1,
          flat_retros_before_goal_change: 3,
          on_track_tolerance_percent: 0,
          max_retro_rows: 10,
          max_retro_predictions: 50,
          default_wake_hour: 6,
          stall_after: 3,
          ask_expiry_days: 14,
          max_open_tasks: 5,
          max_cards: 20,
          max_addressed: 20,
          briefing_entries: 20
        ] do
      assert apply(Limits, key, []) == expected
    end

    for rhythm <- ~w(daily weekdays), do: assert(Limits.respond_within_hours(rhythm) == 12)
    for rhythm <- ~w(weekly biweekly), do: assert(Limits.respond_within_hours(rhythm) == 48)
    assert Enum.map(~w(off gentle pushy), &Limits.max_open_asks/1) == [0, 1, 3]
    assert Decimal.equal?(Limits.flat_within(), 0)
    assert Enum.map(~w(daily weekdays weekly biweekly), &Limits.retro_every/1) == [7, 5, 4, 2]
    assert Enum.map(~w(daily weekdays weekly biweekly), &Limits.paced_every/1) == [7, 5, 2, 2]
    Application.put_env(:goals, :limits, %{retro_every: %{"daily" => 9}})
    assert Limits.retro_every("daily") == 9
    assert Limits.retro_every("weekly") == 4
    Application.put_env(:goals, :limits, %{max_cards: 7})
    assert Limits.max_cards() == 7
    assert Limits.tick_batch() == 50

    Application.put_env(:goals, :limits, %{
      respond_within_hours: %{"daily" => 8},
      max_open_asks: %{"pushy" => 2}
    })

    assert Limits.respond_within_hours("daily") == 8
    assert Limits.respond_within_hours("weekly") == 48
    assert Limits.max_open_asks("pushy") == 2
    assert Limits.max_open_asks("gentle") == 1
  end
end
