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
    Application.put_env(:goals, :limits, %{max_cards: 7})
    assert Limits.max_cards() == 7
    assert Limits.tick_batch() == 50
  end
end
