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
          screen_share_enabled: false
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
end
