defmodule PlatformWeb.Components.BottomNavTest do
  @moduledoc """
  Unit tests for the mobile bottom_nav component.

  Stage 3 of task 019e2ca8 adds the Meetings tab between Tasks and Activity.
  Asserts the rendered DOM contract:

    * Each surface link uses the correct `href`.
    * The Meetings entry carries the hero-video-camera path data verbatim
      (matches the desktop sidebar icon — keeps mobile/desktop visually aligned).
    * The active-state class is applied when the active_module matches the
      tab's label (Meetings included), and omitted otherwise.
  """

  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.BottomNav

  # Distinctive path fragment from the hero-video-camera 24/outline heroicon.
  # If the icon shape ever changes upstream, this assertion flags the drift.
  @video_camera_path_fragment "m15.75 10.5 4.72-4.72"

  defp render_bottom_nav(assigns) do
    assigns =
      Map.merge(
        %{
          active_module: "Chat",
          tasks_count: 0
        },
        assigns
      )

    rendered_to_string(~H"""
    <.bottom_nav active_module={@active_module} tasks_count={@tasks_count} />
    """)
  end

  describe "surface links" do
    test "renders Chat link to /chat" do
      html = render_bottom_nav(%{})
      assert html =~ ~s(href="/chat")
      assert html =~ ~s(aria-label="Chat")
    end

    test "renders Tasks link to /tasks" do
      html = render_bottom_nav(%{})
      assert html =~ ~s(href="/tasks")
      assert html =~ ~s(aria-label="Tasks")
    end

    test "renders Meetings link to /meetings" do
      html = render_bottom_nav(%{})
      assert html =~ ~s(href="/meetings")
      assert html =~ ~s(aria-label="Meetings")
      assert html =~ ">Meetings<"
    end

    test "renders Activity link to /activity" do
      html = render_bottom_nav(%{})
      assert html =~ ~s(href="/activity")
      assert html =~ ~s(aria-label="Activity")
    end

    test "renders More button" do
      html = render_bottom_nav(%{})
      assert html =~ ~s(phx-click="open_more_sheet")
      assert html =~ ~s(aria-label="More surfaces")
    end
  end

  describe "Meetings icon" do
    test "uses the hero-video-camera path data (matches desktop sidebar)" do
      html = render_bottom_nav(%{})
      assert html =~ @video_camera_path_fragment
    end
  end

  describe "active state" do
    test "marks Meetings tab active when active_module is \"Meetings\"" do
      html = render_bottom_nav(%{active_module: "Meetings"})

      # Active tab gets the modifier class + aria-current="page".
      # Look for the substring of the Meetings link that carries both.
      assert html =~ "bottom-nav-tab--active"
      assert html =~ ~s(aria-current="page")
      # And the active marker is *on* the Meetings link specifically.
      meetings_link_chunk =
        html
        |> String.split(~s(href="/meetings"))
        |> Enum.at(1, "")

      assert meetings_link_chunk =~ "bottom-nav-tab--active" or
               html
               |> String.split("bottom-nav-tab--active")
               |> Enum.at(0, "") =~ ~s(href="/meetings")
    end

    test "does not mark Meetings tab active when another surface is active" do
      html = render_bottom_nav(%{active_module: "Chat"})

      # Locate just the Meetings link's opening tag and assert no active class.
      meetings_open =
        html
        |> String.split(~s(href="/meetings"))
        |> Enum.at(1, "")
        |> String.split(">")
        |> Enum.at(0, "")

      refute meetings_open =~ "bottom-nav-tab--active"
      refute meetings_open =~ ~s(aria-current="page")
    end
  end
end
