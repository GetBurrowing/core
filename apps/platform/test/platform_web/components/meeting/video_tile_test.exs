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

  # ── Layout attr (task 019e412a) ───────────────────────────────────────────
  #
  # The bottom strip and the gallery grid both compose <.video_tile>, but
  # they have different sizing contracts. The :layout attr is what keeps
  # both correct.
  #
  # :strip = "tile fills the container's height, width follows from
  # aspect-video" (fixed-height flex row contract). The strip caller
  # supplies a fixed height (`h-[96px] lg:h-[120px]`) and tiles scroll
  # horizontally; 16:9 is preserved because there is no orthogonal width
  # constraint.
  #
  # :gallery = "tile preserves 16:9 AND grows to whichever cell dimension
  # binds first, letterboxing the other axis". Pure-CSS aspect-ratio
  # with both width and height explicit becomes intrinsic and is
  # ignored, so the actual sizing is done by a CSS container query in
  # `apps/platform/assets/css/app.css` under
  # `[data-gallery-cell] > .meeting-video-tile` — that selector picks
  # `height: 100%; width: auto` for wider-than-16:9 cells and
  # `width: 100%; height: auto` for narrower-than-16:9 cells, with
  # `max-w-full max-h-full` clamps. The outer tile element here
  # therefore carries NO width/height/aspect-ratio classes; the CSS
  # rule applies them based on the parent's aspect.
  #
  # Why not inline `aspect-video h-full` (3ee579f, REJECTED): no
  # max-bound caused tiles to overflow / shrink to floating thumbnails.
  #
  # Why not inline `h-full w-full` (f1e16f1, REJECTED): forcing both
  # axes to 100% inside a tall cell distorts faces vertically. Rowan:
  # "it shouldn't go long vertically, it should still fit the aspect
  # ratio."
  #
  # The tests below pin the new container-query contract — the outer
  # tile class string is intentionally minimal so the CSS rule is the
  # single source of truth for sizing.
  describe "video_tile/1 — :layout attr" do
    test "layout=:strip (default) keeps the bottom-strip class string" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} />
        """)

      [_, outer_class] =
        Regex.run(~r/class="([^"]*meeting-video-tile[^"]*)"/, html)

      outer_tokens = String.split(outer_class)

      assert "aspect-video" in outer_tokens
      assert "h-full" in outer_tokens
      assert "shrink-0" in outer_tokens
      # Gallery-only classes must NOT leak into the strip default.
      refute "max-h-full" in outer_tokens
      refute "max-w-full" in outer_tokens
      refute "w-auto" in outer_tokens
      refute "h-auto" in outer_tokens
    end

    test "explicit layout=:strip is identical to the default" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} layout={:strip} />
        """)

      [_, outer_class] =
        Regex.run(~r/class="([^"]*meeting-video-tile[^"]*)"/, html)

      outer_tokens = String.split(outer_class)

      assert "aspect-video" in outer_tokens
      assert "h-full" in outer_tokens
      assert "shrink-0" in outer_tokens
      refute "max-h-full" in outer_tokens
      refute "w-auto" in outer_tokens
    end

    test "layout=:gallery emits no inline sizing classes — CSS container query owns it" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} layout={:gallery} />
        """)

      # Extract the OUTER tile element's class string so substring
      # matches against the inner data-video-slot (which has `h-full
      # w-full` of its own) don't poison the assertion.
      [_, outer_class] =
        Regex.run(~r/class="([^"]*meeting-video-tile[^"]*)"/, html)

      outer_tokens = String.split(outer_class)

      # Base presentation tokens still come from the shared class
      # string — these are the only tokens we keep on the outer.
      assert "meeting-video-tile" in outer_tokens
      assert "group" in outer_tokens
      assert "relative" in outer_tokens
      assert "overflow-hidden" in outer_tokens
      assert "rounded-lg" in outer_tokens
      assert "bg-base-300" in outer_tokens

      # NO inline sizing classes on the outer. The CSS rule in
      # `assets/css/app.css` (selector
      # `[data-gallery-cell] > .meeting-video-tile`) declares
      # `aspect-ratio: 16/9; max-width: 100%; max-height: 100%;` and
      # then, via container queries on the parent cell's aspect
      # ratio, picks `height: 100%; width: auto` (wider cells) or
      # `width: 100%; height: auto` (narrower cells). Keeping the
      # inline class list clean ensures Tailwind utilities don't
      # override the container-query CSS.
      refute "aspect-video" in outer_tokens
      refute "h-full" in outer_tokens
      refute "w-full" in outer_tokens
      refute "h-auto" in outer_tokens
      refute "w-auto" in outer_tokens
      refute "max-h-full" in outer_tokens
      refute "max-w-full" in outer_tokens
      refute "shrink-0" in outer_tokens
      refute "shrink" in outer_tokens
    end
  end

  # ── no per-tile caption overlay (task 019ff712 stage 3) ────────────────────
  #
  # The per-speaker `[data-caption-slot]` overlay and its `caption_slot?`
  # attr are GONE. Captions are the single consolidated bar in every stage
  # mode, gallery included — see `meeting_live_test.exs`, which asserts the
  # bar renders un-hidden in gallery. Deleting the overlay on its own would
  # have left gallery caption-less; the two changes landed together.
  describe "video_tile/1 — no caption overlay" do
    test "no layout renders a [data-caption-slot] overlay" do
      assigns = %{p: participant()}

      gallery =
        rendered_to_string(~H"""
        <.video_tile participant={@p} layout={:gallery} />
        """)

      strip =
        rendered_to_string(~H"""
        <.video_tile participant={@p} layout={:strip} />
        """)

      refute gallery =~ ~s(data-caption-slot)
      refute strip =~ ~s(data-caption-slot)

      # Anti-vacuity: both renders really did produce a tile, so the
      # refutes above are about the overlay and not about an empty string.
      assert gallery =~ ~s(data-participant)
      assert strip =~ ~s(data-participant)
    end

    test "the caption_slot? attr is no longer declared on the component" do
      # A leftover declaration is invisible to a render assertion — every
      # caller stopped passing it, so the overlay would be absent either
      # way. Assert the attr itself is gone from the compiled component.
      attrs =
        PlatformWeb.Components.Meeting.VideoTile.__components__()
        |> Map.fetch!(:video_tile)
        |> Map.fetch!(:attrs)
        |> Enum.map(& &1.name)

      refute :caption_slot? in attrs
      # Anti-vacuity: the attr list is the real one.
      assert :participant in attrs
    end
  end
end
