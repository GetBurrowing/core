defmodule PlatformWeb.MeetingLive.CalendarRedirectTest do
  @moduledoc """
  The allow list that maps an old `/meetings` index link onto Calendar (task
  01a1b8a5 stage 4). Pure: no database, so the mapping cannot leak whether
  a meeting exists.
  """
  use ExUnit.Case, async: true

  alias PlatformWeb.MeetingLive.CalendarRedirect

  @id "01a1b8a5-a4d8-7000-8c89-4d7da10c2701"

  defp query(path) do
    case URI.parse(path) do
      %URI{path: "/calendar", query: nil} -> %{}
      %URI{path: "/calendar", query: q} -> URI.decode_query(q)
    end
  end

  test "the bare listing is plain Calendar" do
    assert CalendarRedirect.path(%{}) == "/calendar"
  end

  test "a list selection keeps its meeting id for Calendar to re-resolve" do
    assert query(CalendarRedirect.path(%{"meeting" => @id})) == %{"meeting" => @id}
  end

  test "a malformed meeting id is dropped, not echoed" do
    for bad <- ["not-a-uuid", "", "1; drop table", @id <> "x"] do
      assert CalendarRedirect.path(%{"meeting" => bad}) == "/calendar", bad
    end
  end

  test "the archive becomes Past events and its filters are dropped" do
    assert query(
             CalendarRedirect.path(%{
               "view" => "archive",
               "q" => "bucket policy",
               "types" => "canvases",
               "person_id" => @id,
               "project_id" => @id
             })
           ) == %{"past" => "1"}
  end

  test "view=calendar and unknown views add nothing" do
    for view <- ["calendar", "list", "week", "<script>"] do
      assert CalendarRedirect.path(%{"view" => view}) == "/calendar", view
    end
  end

  test "the old schedule sheet opens Calendar's editor with a parsed date, start and project" do
    q =
      query(
        CalendarRedirect.path(%{
          "schedule" => "true",
          "from" => "calendar",
          "date" => "2026-11-13",
          "start_time" => "2:00 PM",
          "project_id" => @id
        })
      )

    assert q == %{"new" => "1", "date" => "2026-11-13", "start" => "2:00 PM", "project" => @id}
  end

  test "an unparseable date, start or project is dropped rather than passed on" do
    q =
      query(
        CalendarRedirect.path(%{
          "schedule" => "true",
          "date" => "2026-13-45",
          "start_time" => "teatime",
          "project_id" => "nope"
        })
      )

    assert q == %{"new" => "1"}
  end

  test "schedule must be exactly true" do
    for v <- ["1", "TRUE", "yes", ""] do
      assert CalendarRedirect.path(%{"schedule" => v}) == "/calendar", v
    end
  end

  test "parameters the allow list does not name never reach Calendar" do
    q =
      query(
        CalendarRedirect.path(%{
          "draft" => "token",
          "select" => @id,
          "tab" => "transcript",
          "redirect" => "https://evil.example",
          "date" => "2026-11-13"
        })
      )

    assert q == %{"date" => "2026-11-13"}
  end

  test "a non-map is plain Calendar" do
    assert CalendarRedirect.path(nil) == "/calendar"
  end
end
