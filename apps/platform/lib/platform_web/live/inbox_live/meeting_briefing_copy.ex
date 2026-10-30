defmodule PlatformWeb.InboxLive.MeetingBriefingCopy do
  @moduledoc """
  Every word the meeting briefing shows in the Inbox (task 01a1694a stage
  4): the row (`PlatformWeb.Components.MeetingBriefingRow`) and the detail
  (`PlatformWeb.InboxLive.MeetingBriefingComponent`). The components only
  paint.

  A sibling of `PlatformWeb.InboxLive.BriefingCopy` rather than an addition
  to it, so the daily briefing's strings stay exactly as they are.
  """

  @default_zone "America/Chicago"

  @doc "The kind word on the row."
  @spec kind_label() :: String.t()
  def kind_label, do: "Meeting"

  @doc """
  The row's receipt line from the briefing's counts: "1 item · 1 open",
  "3 items · 2 open", "All resolved" once nothing is open, and "No items"
  for a briefing with nothing to act on.
  """
  @spec receipt_line(map()) :: String.t()
  def receipt_line(%{total: 0}), do: "No items"
  def receipt_line(%{open: 0}), do: "All resolved"
  def receipt_line(%{total: total, open: open}), do: items(total) <> " · #{open} open"
  def receipt_line(_counts), do: "No items"

  @doc "\"1 item\" / \"N items\"."
  @spec items(non_neg_integer()) :: String.t()
  def items(1), do: "1 item"
  def items(n), do: "#{n} items"

  @doc "What the detail shows for every briefing it cannot load."
  @spec not_found() :: String.t()
  def not_found, do: "There's no briefing here."

  @doc "The Summary section's text while no summary exists yet."
  @spec summary_pending() :: String.t()
  def summary_pending, do: "Summary unavailable"

  @doc "Missing parts at the bounded delivery deadline."
  def missing_part("summary"), do: "Summary unavailable"
  def missing_part("triage filing"), do: "Task filing incomplete"
  def missing_part("synthesis"), do: "Synthesis incomplete"

  @doc "Section headings, in render order."
  @spec heading(atom()) :: String.t()
  def heading(:summary), do: "Summary"
  def heading(:open), do: "Open"
  def heading(:resolved), do: "Resolved"
  def heading(:open_questions), do: "Open questions"
  def heading(:unfiled), do: "Action items not filed"
  def heading(:transcript), do: "Transcript"

  @doc "The label on each action button."
  @spec action_label(atom()) :: String.t()
  def action_label(:revert), do: "Revert"
  def action_label(:confirm), do: "Looks right"
  def action_label(:ask), do: "Ask"
  # Task 01a18d37 stage 2 bridge: `MeetingBriefings.view/2` now offers
  # `:follow_up`, and without a label the card raises on render. Stage 3
  # replaces this with the agent-named "Follow up with <Agent>" button.
  def action_label(:follow_up), do: "Follow up"
  def action_label(:align), do: "Seek alignment"
  def action_label(:dismiss), do: "Not a conflict"

  @doc "The item's kind tag."
  @spec kind_tag(String.t() | nil) :: String.t()
  def kind_tag("task"), do: "Task filed"
  def kind_tag("canvas"), do: "Canvas created"
  def kind_tag("finding"), do: "Finding"
  def kind_tag(_), do: "Item"

  @doc """
  A synthesis finding's label, by finding kind (task 01a16974 stage 5):
  "Alignment needed" for a conflict, "Possible duplicate", "Contradicts a
  decision", and "Related work" for a dependency.
  """
  @spec finding_label(String.t() | nil) :: String.t()
  def finding_label("conflicts_with"), do: "Alignment needed"
  def finding_label("duplicates"), do: "Possible duplicate"
  def finding_label("contradicts"), do: "Contradicts a decision"
  def finding_label("depends_on"), do: "Related work"
  def finding_label(_), do: "Finding"

  @doc """
  The row's finding hint from the kinds of the viewer's open findings: nil
  for none, "Alignment needed" when any is a conflict, otherwise the first
  one's label.
  """
  @spec row_finding([String.t()]) :: String.t() | nil
  def row_finding([]), do: nil

  def row_finding(kinds) when is_list(kinds) do
    if "conflicts_with" in kinds,
      do: finding_label("conflicts_with"),
      else: finding_label(hd(kinds))
  end

  @doc "The heading over a finding's citations."
  @spec citations_heading() :: String.t()
  def citations_heading, do: "Sources"

  @doc """
  A resolved item's receipt, as `{lead, time}`: "Reverted by Ada" and
  "14:05" in the viewer's zone ("" when the receipt carries no time).
  """
  @spec receipt(map(), String.t() | nil) :: {String.t(), String.t()}
  def receipt(%{verb: verb, by_name: name} = receipt, zone) do
    {verb_label(verb) <> " by " <> (name || "someone"), time(receipt[:at], zone)}
  end

  defp verb_label("reverted"), do: "Reverted"
  defp verb_label("confirmed"), do: "Confirmed"
  defp verb_label("asked"), do: "Asked"
  defp verb_label("aligned"), do: "Aligned"
  defp verb_label("dismissed"), do: "Dismissed"
  defp verb_label(_), do: "Handled"

  @doc "The note a stale click gets: \"Already handled by Ada\"."
  @spec already_handled(String.t() | nil) :: String.t()
  def already_handled(name), do: "Already handled by " <> (name || "someone")

  @doc "The Ask field's placeholder: a hint once a blank question was sent."
  @spec ask_placeholder(boolean()) :: String.t()
  def ask_placeholder(true), do: "Type a question first"
  def ask_placeholder(false), do: "What do you want to ask the meeting?"

  @doc "The error under a card's buttons for a refused action."
  @spec error_text(term()) :: String.t()
  def error_text(:not_revertible), do: "This task has moved on, so it can't be reverted here."
  def error_text(:unauthorized), do: "You don't have permission to revert this task."
  def error_text(:not_found), do: "That item isn't available."
  def error_text(:unsupported), do: "That action isn't available for this item."
  def error_text(_), do: "That didn't work. Try again."

  @doc """
  `error_text/1` for a refusal of `verb`: "Seek alignment" refused as
  `:unauthorized` means the clicker can post in neither meeting's chat.
  """
  @spec error_text(term(), atom()) :: String.t()
  def error_text(:unauthorized, :align),
    do: "You can't post in either meeting's chat, so alignment can't be sought from here."

  def error_text(reason, _verb), do: error_text(reason)

  @doc "The row's time: when the meeting ended, in `zone`, e.g. \"Oct 23, 14:05\"."
  @spec ended(DateTime.t() | nil, String.t() | nil) :: String.t()
  def ended(%DateTime{} = at, zone), do: Calendar.strftime(local(at, zone), "%b %-d, %-H:%M")
  def ended(_at, _zone), do: ""

  defp time(iso, zone) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(local(at, zone), "%-H:%M")
      _ -> ""
    end
  end

  defp time(_at, _zone), do: ""

  defp local(at, zone) do
    case DateTime.shift_zone(at, zone || @default_zone) do
      {:ok, shifted} -> shifted
      {:error, _} -> DateTime.shift_zone!(at, @default_zone)
    end
  end
end
