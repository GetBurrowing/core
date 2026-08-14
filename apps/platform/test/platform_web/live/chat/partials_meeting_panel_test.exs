defmodule PlatformWeb.Chat.PartialsMeetingPanelTest do
  @moduledoc """
  Tests for the `meeting_panel/1` and screen-share button wiring in
  `PlatformWeb.Chat.Partials` (task 019e420f stages 2 + 3).

  These cover the chat-surface Quick Meet panel only — the dedicated
  `/meetings/:slug` LiveView is covered by `PlatformWeb.MeetingLiveTest`.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PlatformWeb.ChatLive.Partials

  defp render_panel(assigns) do
    assigns =
      Map.merge(
        %{
          in_meeting: true,
          active_space: %{name: "Test Space"},
          mic_enabled: true,
          camera_enabled: true,
          screen_share_enabled: false,
          meeting_participants: []
        },
        assigns
      )

    ~H"""
    <Partials.meeting_panel
      in_meeting={@in_meeting}
      active_space={@active_space}
      mic_enabled={@mic_enabled}
      camera_enabled={@camera_enabled}
      screen_share_enabled={@screen_share_enabled}
      meeting_participants={@meeting_participants}
    />
    """
    |> rendered_to_string()
  end

  describe "screen-share button wiring (stage 2)" do
    test "desktop share button uses MeetingShareButton hook, not phx-click" do
      html = render_panel(%{})

      # The desktop variant carries the stable id + hook attribute. The
      # JS hook handles the click client-side so the user-activation
      # gesture survives the call into `getDisplayMedia()`.
      assert html =~ ~s(id="meeting-share-btn-desktop")
      assert html =~ ~s(phx-hook="MeetingShareButton")

      # The old `phx-click="meeting_toggle_screen_share"` MUST NOT live
      # on this button anymore — a phx-click would race the hook and
      # double-toggle, and worse the round-trip would kill the gesture.
      refute html =~
               ~r/id="meeting-share-btn-desktop"[^>]*phx-click="meeting_toggle_screen_share"/
    end

    test "mobile share button uses MeetingShareButton hook" do
      html = render_panel(%{})

      assert html =~ ~s(id="meeting-share-btn-mobile")

      # Both share buttons have a `data-role` so JS / tests can find
      # them by intent rather than chrome-specific selectors.
      assert html =~ ~s(data-role="meeting-share-button")
    end

    test "mic + camera + leave buttons still use phx-click (only share moved)" do
      html = render_panel(%{})

      # We're isolating ONE button-class change. The neighbors must
      # still be server-driven (no gesture concerns there).
      assert html =~ ~s(phx-click="meeting_toggle_mic")
      assert html =~ ~s(phx-click="meeting_toggle_camera")
      assert html =~ ~s(phx-click="meeting_leave")
    end
  end

  describe "screen-share preview slot (stage 3)" do
    test "renders desktop screen-share preview slot above the participants grid" do
      html = render_panel(%{})

      # The slot is the dedicated render target for incoming screen-
      # share tracks (`meeting_client.js` `_attachScreenShareTrack`). It
      # must be present so the JS hook has somewhere to attach the
      # `<video>` element instead of jamming it into a participant tile.
      assert html =~ ~s(data-quickmeet-screen-share-slot)
      assert html =~ ~s(data-pane="desktop")
      assert html =~ ~s(id="meeting-screen-share-slot-desktop")

      # `phx-update="ignore"` so the LV doesn't blow away the live
      # `<video>` element on re-render — JS owns those children.
      assert html =~
               ~r/data-quickmeet-screen-share-slot[^>]*phx-update="ignore"|phx-update="ignore"[^>]*data-quickmeet-screen-share-slot/

      # Starts hidden (no active share). The hook clears `hidden` when
      # it attaches a track.
      assert html =~
               ~r/data-quickmeet-screen-share-slot[^>]*class="[^"]*hidden/
    end

    test "renders mobile screen-share preview slot" do
      html = render_panel(%{})

      assert html =~ ~s(id="meeting-screen-share-slot-mobile")
      assert html =~ ~s(data-pane="mobile")
    end

    test "renders the sharer-name label slot for each preview" do
      html = render_panel(%{})

      # JS writes the sharer's display name here when the track lands.
      assert html =~ ~s(data-quickmeet-screen-share-sharer)
    end

    test "screen-share slots only render when in a meeting" do
      html = render_panel(%{in_meeting: false})

      # The whole panel disappears when not in a meeting; the screen-
      # share slot follows. (`:if={@in_meeting}` gate on the panel root.)
      refute html =~ ~s(data-quickmeet-screen-share-slot)
    end
  end

  describe "local self-view parking slot + dock (v4 stage 2)" do
    test "renders the desktop local self-view parking slot with a DISTINCT id" do
      html = render_panel(%{})

      # The page-level MeetingClient hook births the persistent local
      # <video> in `[data-role="local-self-view"]`. The quick-meet panel
      # must carry a parking slot (was absent → local <video> orphaned).
      assert html =~ ~s(id="quickmeet-local-self-view")
      assert html =~ ~s(data-role="local-self-view")

      # DISTINCT from MeetingLive's `meeting-local-self-view` so the two
      # surfaces never collide on a duplicate id when both are in the DOM.
      refute html =~ ~s(id="meeting-local-self-view")

      # phx-update="ignore" so the LV patch never wipes the hook's <video>.
      assert html =~
               ~r/id="quickmeet-local-self-view"[^>]*phx-update="ignore"|phx-update="ignore"[^>]*id="quickmeet-local-self-view"/
    end

    test "renders the desktop gallery dock the hook reparents the <video> into" do
      html = render_panel(%{})

      # The quick-meet panel is single-layout (no MeetingLive stage modes),
      # so it gets ONE dock with data-dock-mode="gallery" — the mode
      # `_currentStageMode()` defaults to when no center-stage is present.
      assert html =~ ~s(id="quickmeet-local-video-dock")
      assert html =~ ~s(data-local-video-dock)
      assert html =~ ~s(data-dock-mode="gallery")
    end

    test "renders the mobile parking slot + dock with mobile pane markers" do
      html = render_panel(%{})

      # Both desktop and mobile quick-meet variants coexist in the DOM;
      # the hook picks the visible pane via data-pane + matchMedia.
      assert html =~ ~s(id="quickmeet-local-self-view-mobile")
      assert html =~ ~s(id="quickmeet-local-video-dock-mobile")
      assert html =~ ~s(data-pane="mobile")
      assert html =~ ~s(data-pane="desktop")
    end

    test "parking slot + dock only render when in a meeting" do
      html = render_panel(%{in_meeting: false})

      refute html =~ ~s(id="quickmeet-local-self-view")
      refute html =~ ~s(data-local-video-dock)
    end
  end

  describe "server-presence roster (v4 stage 3)" do
    test "renders each participant by REAL display_name, never the literal 'User'" do
      participants = [
        %{
          id: Ecto.UUID.generate(),
          participant_id: Ecto.UUID.generate(),
          participant_type: "user",
          display_name: "Dev Alice",
          avatar_url: nil
        },
        %{
          id: Ecto.UUID.generate(),
          participant_id: Ecto.UUID.generate(),
          participant_type: "user",
          display_name: "Dev Bob",
          avatar_url: nil
        }
      ]

      html = render_panel(%{meeting_participants: participants})

      assert html =~ "Dev Alice"
      assert html =~ "Dev Bob"
      refute html =~ ">User<"
      # The roster is the LV-owned, server-presence-sourced surface.
      assert html =~ ~s(data-role="meeting-roster")
      assert html =~ ~s(data-role="meeting-roster-row")
    end

    test "reflects the count of active participants" do
      participants = [
        %{
          id: Ecto.UUID.generate(),
          participant_id: Ecto.UUID.generate(),
          participant_type: "user",
          display_name: "Dev Alice",
          avatar_url: nil
        },
        %{
          id: Ecto.UUID.generate(),
          participant_id: Ecto.UUID.generate(),
          participant_type: "user",
          display_name: "Dev Bob",
          avatar_url: nil
        }
      ]

      html = render_panel(%{meeting_participants: participants})

      # Count surfaces in the roster header (both desktop + mobile rails).
      assert html =~ ~s(data-role="meeting-roster-count")
      # Two roster rows are rendered (one per participant), per rail.
      rows = html |> String.split(~s(data-role="meeting-roster-row")) |> length()
      # 2 rails x 2 participants = 4 row markers (+1 from the split head).
      assert rows == 5
    end

    test "an unresolved identity falls through to 'Unknown participant', not 'User'" do
      participants = [
        %{
          id: Ecto.UUID.generate(),
          participant_id: nil,
          participant_type: "user",
          display_name: nil,
          avatar_url: nil
        }
      ]

      html = render_panel(%{meeting_participants: participants})

      assert html =~ "Unknown participant"
      refute html =~ ">User<"
    end

    test "the media grid still renders alongside the roster (coexistence)" do
      html = render_panel(%{meeting_participants: []})

      # Roster is LV-owned; the JS media grid keeps its phx-update=ignore so
      # live tracks aren't wiped.
      assert html =~ ~s(id="meeting-roster")
      assert html =~ ~s(id="meeting-participants")
    end

    test "roster only renders when in a meeting" do
      html = render_panel(%{in_meeting: false, meeting_participants: []})

      refute html =~ ~s(data-role="meeting-roster")
    end
  end

  # Task 019ff712 stage 2 — ONE caption host per panel render.
  #
  # `render_panel/1` renders `meeting_panel/1` in its PRODUCTION shape:
  # both breakpoint subtrees are emitted into the same document (one is
  # hidden by CSS at any given width), which is exactly the condition
  # that used to produce two `MeetingCaptions` hosts. A cut-down render
  # of a single container would pass against the two-host markup too and
  # would prove nothing.
  #
  # Counted with LazyHTML, not with `=~`: `LazyHTML.query/2` returns a
  # struct and is NEVER falsy, so `if result do` and `result == []` are
  # both wrong — the nodes have to be counted.
  describe "single caption host (stage 2)" do
    defp caption_hosts(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([phx-hook="MeetingCaptions"]))
      |> Enum.count()
    end

    test "renders exactly one MeetingCaptions host across both breakpoint subtrees" do
      html = render_panel(%{})

      # Anti-vacuity: the production shape really does emit both
      # subtrees, so a count of 1 is a collapse and not a missing panel.
      assert html =~ ~s(id="meeting-share-btn-desktop")
      assert html =~ ~s(id="meeting-share-btn-mobile")

      assert caption_hosts(html) == 1
      assert html =~ ~s(id="meeting-captions")
      assert html =~ ~s(data-role="meeting-captions")
    end

    test "the single host is hoisted out of the breakpoint-scoped subtrees" do
      html = render_panel(%{})

      # The old per-breakpoint host lived inside the desktop rail /
      # mobile overlay. The hoisted one is a fixed-position sibling of
      # both, so it is legible at either width rather than swapping.
      host =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-captions"]))

      assert Enum.count(host) == 1

      classes = host |> LazyHTML.attribute("class") |> List.first()
      assert classes =~ "fixed"
      # ONE bottom offset, unprefixed, so the host clears the control row
      # at both widths — measured over CDP against both control rows.
      assert classes =~ "bottom-32"
      refute classes =~ "lg:bottom-"
      # Pinned inside the w-96 desktop rail at lg, full-bleed below it.
      assert classes =~ "lg:right-3"
      assert classes =~ "inset-x-4"
    end

    test "the host carries phx-update=ignore so a patch cannot wipe committed lines" do
      html = render_panel(%{})

      update =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="meeting-captions"]))
        |> LazyHTML.attribute("phx-update")

      assert update == ["ignore"]
    end

    test "no caption host at all when not in a meeting" do
      html = render_panel(%{in_meeting: false})

      assert caption_hosts(html) == 0
      refute html =~ ~s(data-role="meeting-captions")
    end
  end
end
