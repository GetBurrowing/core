defmodule PlatformWeb.Components.InboxItemTest do
  @moduledoc """
  Read-state rendering for `PlatformWeb.Components.InboxItem` (task 01a11703
  stage 2): one marker per row — the unread dot, the "Needs your review" tag,
  or nothing — plus the title weight step.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.InboxItem

  alias Platform.Inbox.Item

  @now ~U[2026-10-07 12:00:00.000000Z]

  defp item(kind, read_at) do
    %Item{
      id: "01a11703-0000-7000-8000-000000000001",
      user_id: "01a11703-0000-7000-8000-000000000002",
      kind: kind,
      source_type: "test",
      title: "Q4 onboarding plan",
      body: nil,
      url: "/tasks/x",
      read_at: read_at,
      dismissed_at: nil,
      inserted_at: @now
    }
  end

  defp render_row(item) do
    assigns = %{item: item}

    rendered_to_string(~H"""
    <.inbox_item id={"inbox-item-#{@item.id}"} item={@item} selectable={true} />
    """)
    |> LazyHTML.from_fragment()
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  defp title_class(doc) do
    [class] =
      doc |> LazyHTML.query(~s([data-role="inbox-item-title"])) |> LazyHTML.attribute("class")

    class
  end

  test "an unread chat_mention renders exactly one dot, a semibold title and no tag" do
    doc = render_row(item("chat_mention", nil))

    assert count(doc, ~s([data-role="inbox-item-unread-dot"])) == 1
    assert title_class(doc) =~ "font-semibold"
    refute title_class(doc) =~ "font-normal"
    assert count(doc, ~s([data-role="inbox-item-needs-action"])) == 0
    assert doc |> LazyHTML.query(".sr-only") |> LazyHTML.text() |> String.trim() == "Unread"
  end

  test "an unread task_plan_review renders the dot, not the tag" do
    doc = render_row(item("task_plan_review", nil))

    assert count(doc, ~s([data-role="inbox-item-unread-dot"])) == 1
    assert count(doc, ~s([data-role="inbox-item-needs-action"])) == 0
  end

  test "a read task_plan_review renders no dot, one Needs your review tag and a normal title" do
    doc = render_row(item("task_plan_review", @now))

    assert count(doc, ~s([data-role="inbox-item-unread-dot"])) == 0
    tag = LazyHTML.query(doc, ~s([data-role="inbox-item-needs-action"]))
    assert Enum.count(tag) == 1
    assert tag |> LazyHTML.text() |> String.trim() == "Needs your review"
    assert title_class(doc) =~ "font-normal"
    refute title_class(doc) =~ "font-semibold"
    assert count(doc, ".sr-only") == 0
  end

  test "a read review_request_pending renders the tag and no dot" do
    doc = render_row(item("review_request_pending", @now))

    assert count(doc, ~s([data-role="inbox-item-unread-dot"])) == 0
    assert count(doc, ~s([data-role="inbox-item-needs-action"])) == 1
  end

  test "a read chat_mention (restored by Undo) renders no dot and no tag" do
    doc = render_row(item("chat_mention", @now))

    assert count(doc, ~s([data-role="inbox-item-unread-dot"])) == 0
    assert count(doc, ~s([data-role="inbox-item-needs-action"])) == 0
    assert title_class(doc) =~ "font-normal"
  end

  test "the dot sits in the meta line, not in the checkbox slot" do
    doc = render_row(item("meeting_invited", nil))

    assert count(
             doc,
             ~s([data-role="inbox-item-open"] [data-role="inbox-item-unread-dot"].ml-auto)
           ) ==
             1

    assert count(doc, ~s([data-role="inbox-item-kind"] ~ [data-role="inbox-item-unread-dot"])) ==
             1
  end
end
