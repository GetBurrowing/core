defmodule PlatformWeb.Components.MeetingBriefingRowTest do
  @moduledoc """
  `MeetingBriefingRow.assigns_for/2` is the meeting briefing row's logic
  with no markup (task 01a1694a stage 4), and `meeting_briefing_row/1`
  paints it.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Inbox.Item
  alias PlatformWeb.Components.MeetingBriefingRow

  @meeting_id "01a1694a-0000-7000-8000-000000000001"

  defp item(attrs \\ %{}) do
    struct!(
      %Item{
        id: "01a1694a-0000-7000-8000-000000000002",
        kind: "meeting_briefing",
        title: "Bucket policy sync",
        url: "/inbox/meeting/" <> @meeting_id,
        read_at: nil,
        inserted_at: ~U[2026-10-23 15:00:00.000000Z]
      },
      attrs
    )
  end

  defp row(counts, opts \\ []),
    do: MeetingBriefingRow.assigns_for(item(), Keyword.merge([counts: counts], opts))

  describe "the receipt line" do
    test "N items · K open, singular at 1" do
      assert row(%{total: 3, open: 2}).summary == "3 items · 2 open"
      assert row(%{total: 1, open: 1}).summary == "1 item · 1 open"
    end

    test "nothing open is all resolved" do
      assert row(%{total: 3, open: 0}).summary == "All resolved"
    end

    test "a briefing with no items says so, and no counts is not a crash" do
      assert row(%{total: 0, open: 0}).summary == "No items"
      assert row(nil).summary == "No items"
    end
  end

  describe "slots" do
    test "kind, title, meeting id, time in the viewer's zone, unread" do
      r =
        row(%{total: 1, open: 1},
          ended_at: ~U[2026-10-23 19:05:00.000000Z],
          time_zone: "America/Chicago"
        )

      assert r.kind == "Meeting"
      assert r.title == "Bucket policy sync"
      assert r.meeting_id == @meeting_id
      assert r.time == "Oct 23, 14:05"
      assert r.unread? == true
      assert r.selected? == false
    end

    test "a read row is not unread; a malformed url has no meeting id" do
      r =
        MeetingBriefingRow.assigns_for(item(read_at: DateTime.utc_now(), url: "/inbox/meeting/x"))

      refute r.unread?
      assert r.meeting_id == nil
    end
  end

  describe "markup" do
    test "paints every slot and patches to the row's url" do
      r = row(%{total: 2, open: 1}, selected: true)

      html =
        rendered_to_string(
          MeetingBriefingRow.meeting_briefing_row(%{
            row: r,
            patch: "/inbox/meeting/" <> @meeting_id <> "?f=briefing"
          })
        )

      assert html =~ ~s(data-role="inbox-meeting-briefing-row")
      assert html =~ ~s(data-meeting-id="#{@meeting_id}")
      assert html =~ "2 items · 1 open"
      assert html =~ "Bucket policy sync"
      assert html =~ ~s(href="/inbox/meeting/#{@meeting_id}?f=briefing")
      assert html =~ ~s(aria-current="page")
      assert html =~ "Unread"
      # No bare `hover:` utility: every hover is `lg:` prefixed.
      refute html =~ ~r/(^|[\s"])(group-)?hover:/
    end
  end
end
