defmodule PlatformWeb.MeetingBarLiveTest do
  @moduledoc """
  Tests for the MeetingBarLive component rendered in the shell layout.

  These tests verify the mini-bar's conditional visibility, content rendering,
  and event handling by directly testing the LiveComponent assigns and markup.
  """
  use PlatformWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias PlatformWeb.MeetingBarLive

  @meeting_assigns %{
    meeting_active: true,
    meeting_space_id: "space-123",
    meeting_space_name: "Engineering",
    meeting_space_slug: "engineering",
    meeting_slug: "engineering-standup-2026-06-19",
    meeting_started_at: ~U[2026-04-14 08:00:00Z],
    on_meeting_page: false,
    sidebar_collapsed: false,
    id: "meeting-bar"
  }

  describe "render/1" do
    test "renders mini-bar when meeting is active and not on meeting page" do
      html = render_component(MeetingBarLive, @meeting_assigns)

      assert html =~ "meeting-mini-bar"
      assert html =~ "Engineering"
      assert html =~ "data-timer"
      assert html =~ "Return to call"
      assert html =~ "Leave"
    end

    test "hides mini-bar when on the meeting page" do
      assigns = Map.put(@meeting_assigns, :on_meeting_page, true)
      html = render_component(MeetingBarLive, assigns)

      assert html =~ "hidden"
    end

    test "hides mini-bar when no active meeting" do
      assigns = Map.put(@meeting_assigns, :meeting_active, false)
      html = render_component(MeetingBarLive, assigns)

      assert html =~ "hidden"
    end

    test "return-to-call link deep-links to /meetings/<meeting_slug>" do
      html = render_component(MeetingBarLive, @meeting_assigns)

      # The Return-to-call action targets the canonical MeetingLive surface,
      # not the chat surface — this is the whole point of the stage-2 wiring:
      # navigating back to the call lands you on the meeting page where the
      # actual video/audio UI lives.
      assert html =~ ~s|href="/meetings/engineering-standup-2026-06-19"|
      # The space-name link still points at the chat surface (intentional —
      # only Return-to-call is the meeting deep link).
      assert html =~ ~s|href="/chat/engineering"|
    end

    test "return-to-call link falls back to /chat/<space_slug> when meeting_slug is nil" do
      assigns = Map.put(@meeting_assigns, :meeting_slug, nil)
      html = render_component(MeetingBarLive, assigns)

      # Falls back to the chat surface when the join broadcast raced ahead
      # of the Meeting row insert (stage-1 fallback path).
      assert html =~ ~s|href="/chat/engineering"|
      refute html =~ ~s|href="/meetings/|
    end

    test "return-to-call link falls back to /chat/<space_id> when both slugs are nil" do
      assigns =
        @meeting_assigns
        |> Map.put(:meeting_slug, nil)
        |> Map.put(:meeting_space_slug, nil)

      html = render_component(MeetingBarLive, assigns)

      # Final fallback so a wholly-degraded bar still has a valid href
      # rather than `nil` interpolation in the DOM.
      assert html =~ ~s|href="/chat/space-123"|
    end

    test "duration timer has correct data-started-at attribute" do
      html = render_component(MeetingBarLive, @meeting_assigns)

      assert html =~ "data-started-at=\"2026-04-14T08:00:00Z\""
    end

    test "uses MeetingBar JS hook" do
      html = render_component(MeetingBarLive, @meeting_assigns)

      assert html =~ ~s|phx-hook="MeetingBar"|
    end

    test "mic toggle defaults to on (microphone icon)" do
      html = render_component(MeetingBarLive, @meeting_assigns)

      assert html =~ "hero-microphone"
      refute html =~ "hero-microphone-slash"
    end

    test "camera toggle defaults to off (camera-slash icon)" do
      html = render_component(MeetingBarLive, @meeting_assigns)

      assert html =~ "hero-video-camera-slash"
    end

    test "renders with sidebar collapsed class" do
      assigns = Map.put(@meeting_assigns, :sidebar_collapsed, true)
      html = render_component(MeetingBarLive, assigns)

      assert html =~ "lg:left-14"
    end

    test "renders with sidebar expanded class" do
      html = render_component(MeetingBarLive, @meeting_assigns)

      assert html =~ "lg:left-56"
    end

    test "includes data-bar attributes for JS hook binding" do
      html = render_component(MeetingBarLive, @meeting_assigns)

      assert html =~ "data-bar-mic"
      assert html =~ "data-bar-camera"
      assert html =~ "data-bar-leave"
    end
  end
end
