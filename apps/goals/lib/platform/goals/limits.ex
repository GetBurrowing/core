defmodule Platform.Goals.Limits do
  @moduledoc "Install-tunable coach limits, kept as data (task 01a1dfc1-05b0)."
  defp value(key, default), do: Map.get(Application.get_env(:goals, :limits, %{}), key, default)
  def tick_interval_ms, do: value(:tick_interval_ms, 60000)
  def tick_batch, do: value(:tick_batch, 50)
  def default_wake_hour, do: value(:default_wake_hour, 6)
  def stall_after, do: value(:stall_after, 3)
  def ask_expiry_days, do: value(:ask_expiry_days, 14)
  def max_open_tasks, do: value(:max_open_tasks, 5)
  def max_cards, do: value(:max_cards, 20)
  def max_addressed, do: value(:max_addressed, 20)
  def briefing_entries, do: value(:briefing_entries, 20)

  def respond_within_hours(rhythm),
    do:
      Map.get(
        value(:respond_within_hours, %{
          "daily" => 12,
          "weekdays" => 12,
          "weekly" => 48,
          "biweekly" => 48
        }),
        rhythm
      )

  def max_open_asks(outreach),
    do: Map.get(value(:max_open_asks, %{"off" => 0, "gentle" => 1, "pushy" => 3}), outreach)
end
