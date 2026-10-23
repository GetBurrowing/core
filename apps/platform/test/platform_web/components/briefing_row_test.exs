defmodule PlatformWeb.Components.BriefingRowTest do
  @moduledoc """
  `BriefingRow.assigns_for/2` is the briefing row's logic with no markup
  (task 01a15ee1 stage 4): every slot as plain data, so a later list
  renderer can reuse it unchanged. These pin the copy from canvas 01a15ee2
  rev 2 and prototype 01a15ec9 v1.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Inbox.Item
  alias PlatformWeb.Components.BriefingRow

  @date ~D[2026-10-21]

  defp item(attrs \\ %{}) do
    struct!(
      %Item{
        id: "01a15ee1-0000-7000-8000-000000000001",
        kind: "briefing",
        url: "/inbox/briefing/2026-10-21",
        read_at: nil,
        inserted_at: ~U[2026-10-21 12:00:00.000000Z]
      },
      attrs
    )
  end

  defp row(counts, opts \\ []),
    do: BriefingRow.assigns_for(item(), Keyword.merge([counts: counts, today: @date], opts))

  describe "the receipt line" do
    test "K calls: lead plus a pill, singular at 1" do
      assert %{receipt_lead: "5 items · ", receipt_pill: "3 need your call"} =
               row(%{total: 5, open: 5, calls: 3})

      assert %{receipt_lead: "2 items · ", receipt_pill: "1 needs your call"} =
               row(%{total: 2, open: 2, calls: 1})

      assert row(%{total: 5, open: 5, calls: 3}).summary == "5 items · 3 need your call"
      assert row(%{total: 2, open: 2, calls: 1}).summary == "2 items · 1 needs your call"
    end

    test "no calls is FYI only, with no pill" do
      assert %{receipt_lead: "4 items · FYI only", receipt_pill: nil} =
               row(%{total: 4, open: 2, calls: 0})
    end

    test "nothing open is all done, whatever the call count" do
      assert %{receipt_lead: "All done · nothing waiting", receipt_pill: nil} =
               row(%{total: 4, open: 0, calls: 0})
    end

    test "no counts at all reads as all done, not a crash" do
      assert row(nil).summary == "All done · nothing waiting"
    end
  end

  describe "title, kind, time, state" do
    test "today's row and an earlier day's" do
      assert row(%{}).title == "Today's briefing"
      assert row(%{}, today: ~D[2026-10-22]).title == "Briefing · Wed, Oct 21"
      assert row(%{}).kind == "Briefing"
    end

    test "the date comes from the url when not given, and drives the patch target" do
      assert %{date: @date, url: "/inbox/briefing/2026-10-21"} = row(%{})
    end

    test "the time is the delivery time in the viewer's zone" do
      # 12:00Z is 07:00 in Chicago (CDT) and 13:00 in London (BST).
      assert row(%{}).time == "7:00"
      assert row(%{}, time_zone: "Europe/London").time == "13:00"
      assert row(%{}, time_zone: "Not/AZone").time == "7:00"
    end

    test "unread until read_at is set; selected only when asked" do
      assert row(%{}).unread?
      refute BriefingRow.assigns_for(item(read_at: DateTime.utc_now()), today: @date).unread?
      refute row(%{}).selected?
      assert row(%{}, selected: true).selected?
    end
  end

  test "the markup paints the slots it is given" do
    html =
      rendered_to_string(
        BriefingRow.briefing_row(%{
          row: row(%{total: 5, open: 5, calls: 3}),
          patch: "/inbox/briefing/2026-10-21"
        })
      )

    assert html =~ ~s(data-role="inbox-briefing-row")
    assert html =~ ~s(href="/inbox/briefing/2026-10-21")
    assert html =~ "hero-sun"
    assert html =~ "3 need your call"
    assert html =~ "Today&#39;s briefing"
  end
end
