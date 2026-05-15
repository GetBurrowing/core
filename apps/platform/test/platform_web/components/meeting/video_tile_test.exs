defmodule PlatformWeb.Components.Meeting.VideoTileTest do
  @moduledoc """
  Stage 1 unit tests for the <.video_tile> component.

  Origin: sibling task 019e2475-0037 — Meetings: bottom video strip. Copied
  into task 019e2474-bc7c (stage 3) alongside the component itself; the stack
  rollup will reconcile.

  Spec: docs/decisions/0042-meeting-system-with-collaborative-canvas.md (Layout → Bottom strip).

  Verifies the rendered DOM contract: video slot vs avatar fallback based on
  video_track presence, mute overlay toggling on audio_muted?, active-speaker
  ring on speaking?, hero icons only. Visual end-to-end is covered by the
  task-level e2e_behavior validations.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.Meeting.VideoTile

  defp participant(overrides \\ %{}) do
    Map.merge(%{identity: "user-alice", name: "Alice"}, overrides)
  end

  describe "video_tile/1 — base render" do
    test "renders the tile shell with the participant identity wired for the JS hook" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} />
        """)

      assert html =~ "meeting-video-tile"
      assert html =~ ~s(phx-hook="MeetingVideoTile")
      assert html =~ ~s(data-participant="user-alice")
      assert html =~ ~s(id="video-tile-user-alice")
      assert html =~ "data-video-slot"
      # Name label is always shown.
      assert html =~ "Alice"
    end
  end

  describe "video_tile/1 — camera-off fallback" do
    test "renders the avatar fallback on bg-base-300 when video_track is nil" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} video_track={nil} />
        """)

      assert html =~ "data-avatar-fallback"
      assert html =~ "bg-base-300"
      # Fallback is visible (not hidden) and the video slot is hidden.
      assert html =~ ~r/data-avatar-fallback[^>]*class="[^"]*flex/
      assert html =~ ~r/data-video-slot[^>]*class="[^"]*hidden/
      assert html =~ ~s(data-has-video="false")
      # The human_avatar component renders for the fallback.
      assert html =~ ~s(data-avatar-kind="human")
    end

    test "shows the video slot and hides the fallback when a video_track is present" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} video_track={%{sid: "TR_abc"}} />
        """)

      assert html =~ ~s(data-has-video="true")
      # Avatar fallback is hidden when video is present.
      assert html =~ ~r/data-avatar-fallback[^>]*class="[^"]*hidden/
      # Video slot is not hidden.
      refute html =~ ~r/data-video-slot[^>]*class="[^"]*hidden/
    end
  end

  describe "video_tile/1 — mute indicator" do
    test "renders the hero-microphone-slash overlay when audio_muted? is true" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} />
        """)

      assert html =~ "data-mute-indicator"
      assert html =~ "hero-microphone-slash"
      assert html =~ "Alice is muted"
    end

    test "omits the mute overlay when audio_muted? is false" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={false} />
        """)

      refute html =~ "data-mute-indicator"
      refute html =~ "hero-microphone-slash"
    end
  end

  describe "video_tile/1 — active-speaker ring" do
    test "applies ring-2 ring-primary when speaking? is true" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} speaking?={true} />
        """)

      assert html =~ "ring-2"
      assert html =~ "ring-primary"
    end

    test "omits the speaking ring when speaking? is false" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} speaking?={false} />
        """)

      refute html =~ "ring-primary"
    end
  end

  describe "video_tile/1 — participant field tolerance" do
    test "falls back gracefully when participant fields are sparse" do
      assigns = %{p: %{id: "p-7"}}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} />
        """)

      # id is used as the identity key, and as the name fallback path is
      # exercised without crashing.
      assert html =~ ~s(data-participant="p-7")
    end

    test "prefers display_name when name is absent" do
      assigns = %{p: %{identity: "u-9", display_name: "Casey Jones"}}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} />
        """)

      assert html =~ "Casey Jones"
    end
  end

  describe "video_tile/1 — passthrough" do
    test "merges extra class and global attrs onto the outer element" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} class="w-32" data-testid="strip-tile" />
        """)

      assert html =~ "w-32"
      assert html =~ ~s(data-testid="strip-tile")
    end
  end
end
