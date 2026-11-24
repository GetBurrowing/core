defmodule Platform.Goals.Limits do
  @moduledoc "Install-tunable coach limits, kept as data (task 01a1dfc1-05b0)."
  defp value(key, default), do: Map.get(Application.get_env(:goals, :limits, %{}), key, default)
  def report_window_days, do: value(:report_window_days, 7)
  def max_suggestions, do: value(:max_suggestions, 10)
  def max_moved, do: value(:max_moved, 10)
  def max_idea_steps, do: value(:max_idea_steps, 10)
  def max_question_chars, do: value(:max_question_chars, 500)
  def tick_interval_ms, do: value(:tick_interval_ms, 60000)
  def tick_batch, do: value(:tick_batch, 50)
  def default_wake_hour, do: value(:default_wake_hour, 6)
  def stall_after, do: value(:stall_after, 3)
  def ask_expiry_days, do: value(:ask_expiry_days, 14)
  def max_open_tasks, do: value(:max_open_tasks, 5)
  def max_tasks_per_wake_up, do: value(:max_tasks_per_wake_up, 3)
  def max_cards, do: value(:max_cards, 20)
  def max_addressed, do: value(:max_addressed, 20)
  def briefing_entries, do: value(:briefing_entries, 20)

  # Task 01a20de3: the goal conversation a check-in or retro briefing carries.
  def briefing_messages, do: value(:briefing_messages, 20)
  def briefing_message_chars, do: value(:briefing_message_chars, 1000)

  @doc "Overrides accept a map keyed by rhythm string under :respond_within_hours."
  def respond_within_hours(rhythm) when rhythm in ~w(daily weekdays weekly biweekly) do
    defaults = %{"daily" => 12, "weekdays" => 12, "weekly" => 48, "biweekly" => 48}
    Map.get(value(:respond_within_hours, %{}), rhythm, Map.fetch!(defaults, rhythm))
  end

  @doc "Overrides accept a map keyed by outreach string under :max_open_asks."
  def max_open_asks(outreach) when outreach in ~w(off gentle pushy) do
    defaults = %{"off" => 0, "gentle" => 1, "pushy" => 3}
    Map.get(value(:max_open_asks, %{}), outreach, Map.fetch!(defaults, outreach))
  end

  def retro_every(rhythm), do: rhythm_value(:retro_every, rhythm, [7, 5, 4, 2])
  def pace_after_ignored_briefs, do: value(:pace_after_ignored_briefs, 3)
  def paced_every(rhythm), do: rhythm_value(:paced_every, rhythm, [7, 5, 2, 2])
  def paced_max_open_asks, do: value(:paced_max_open_asks, 1)
  def flat_retros_before_goal_change, do: value(:flat_retros_before_goal_change, 3)
  def flat_within, do: value(:flat_within, Decimal.new(0))
  def on_track_tolerance_percent, do: value(:on_track_tolerance_percent, 0)
  def max_retro_rows, do: value(:max_retro_rows, 10)
  def max_retro_predictions, do: value(:max_retro_predictions, 50)

  # Goals 5/8 (task 01a1dfc1-7625): the New goal conversation.
  def proposal_expiry_days, do: value(:proposal_expiry_days, 7)
  def max_quick_replies, do: value(:max_quick_replies, 4)
  def max_reply_chars, do: value(:max_reply_chars, 40)
  def max_stops, do: value(:max_stops, 12)
  def max_opening_chars, do: value(:max_opening_chars, 2000)
  def max_sources, do: value(:max_sources, 8)
  def max_takeaways, do: value(:max_takeaways, 20)

  defp rhythm_value(key, rhythm, numbers) do
    defaults = Map.new(Enum.zip(~w(daily weekdays weekly biweekly), numbers))
    Map.get(value(key, %{}), rhythm, Map.fetch!(defaults, rhythm))
  end
end
