defmodule PlatformWeb.Components.Meeting.VideoTileTest do
  @moduledoc """
  Stage 1 unit tests for the <.video_tile> component.

  Origin: sibling task 019e2475-0037 — Meetings: bottom video strip. Copied
  into task 019e2474-bc7c (stage 3) alongside the component itself; the stack
  rollup will reconcile.

  Meeting system: docs/decisions/0030-meetings-livekit-voice-video.md.

  The bottom-strip layout itself is NOT specified in any ADR. A grep for
  "bottom strip" across docs/ returns nothing -- the phrase lives only in
  code. This module and its tests ARE the specification. The citation this
  line previously carried named a file that has never existed in the repo,
  and 0042 is a duplicated ADR number besides (01a04a5e-c28f), so it was
  ambiguous as well as dangling.

  Verifies the rendered DOM contract: video slot vs avatar fallback based on
  video_track presence, the name bar's mic and camera slots, active-speaker
  ring on speaking?, hero icons only. Visual end-to-end is covered by the
  task-level e2e_behavior validations.

  ## What these tests are allowed to claim (task 01a0740d stage 1)

  A test asserting an indicator EXISTS, or carries a class, or has non-zero
  size, PASSES ON THE DEFECT THIS TICKET EXISTS TO FIX. The corner badge it
  replaced satisfied all three: it rendered, `getComputedStyle` reported
  `display: block, opacity: 1, visibility: visible`, and it was still
  invisible to a human because a full-width name label was painted over it.

  An Elixir render test has no layout engine, so it cannot measure
  occlusion. What it CAN assert is the STRUCTURAL INVARIANT that makes
  occlusion impossible: name and both state slots live inside ONE overlay,
  and the tile has exactly three absolutely-positioned children. Two
  overlays cannot fight for the same pixels if there is only one of them.
  That is what `describe "the name bar — structural invariant"` below pins,
  and it is the part that would turn red if somebody re-added a floating
  chip. The rest of the file is behaviour.
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
      # The name is always shown, inside the name bar.
      assert html =~ "data-tile-name-bar"
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

  # ── The name bar (task 01a0740d stage 1) ─────────────────────────────────
  #
  # THE STRUCTURAL HALF. These are the tests the corner badge would have
  # failed. Everything below them is behaviour, and behaviour alone is what
  # let the original defect ship green.

  describe "video_tile/1 — the name bar, structural invariant" do
    test "the tile has EXACTLY three absolutely-positioned children, in order" do
      # The defect was two independently-positioned bottom overlays with no
      # z-index between them, so `elementFromPoint` at the badge's centre
      # returned the name label. Enumerating the overlays is how a re-added
      # fourth one turns this red instead of quietly re-creating the fight.
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} camera_off?={true} />
        """)

      assert absolute_overlays(html) == [
               "data-video-slot",
               "data-avatar-fallback",
               "data-tile-name-bar"
             ]
    end

    test "the name bar is the LAST child of the tile" do
      # DOM order is the whole mechanism: the label won the pixels because
      # it came after the badge. The bar being last is what makes "later in
      # DOM order" a property of ONE element rather than a race between two.
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} camera_off?={true} />
        """)

      last =
        html
        |> tile_root()
        |> element_children()
        |> List.last()

      assert last, "the tile rendered no element children at all"
      assert has_attr?(last, "data-tile-name-bar")
    end

    test "every state indicator lives INSIDE the bar, and none outside it" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} camera_off?={true} />
        """)

      bar = Floki.find(doc(html), "[data-tile-name-bar]")
      assert length(bar) == 1

      for role <- ["mic-indicator", "camera-indicator", "tile-name"] do
        selector = ~s([data-role="#{role}"])
        in_tile = html |> doc() |> Floki.find(selector) |> length()
        in_bar = bar |> Floki.find(selector) |> length()

        # Anti-vacuity first: an equality between two zeroes would pass on
        # a tile that rendered no indicators at all.
        assert in_tile == 1, "expected exactly one #{role} in the tile, got #{in_tile}"
        assert in_bar == in_tile, "#{role} exists outside [data-tile-name-bar]"
      end
    end

    test "the old [data-mute-indicator] corner badge is gone from every state" do
      for muted <- [true, false], camera_off <- [true, false] do
        assigns = %{p: participant(), muted: muted, camera_off: camera_off}

        html =
          rendered_to_string(~H"""
          <.video_tile participant={@p} audio_muted?={@muted} camera_off?={@camera_off} />
          """)

        refute html =~ "data-mute-indicator"
        # Anti-vacuity: the render really did produce a tile.
        assert html =~ "data-tile-name-bar"
      end
    end

    test "neither the bar nor either indicator takes pointer-events-none" do
      # `pointer-events-none` would suppress the `title` tooltips AND make
      # `document.elementFromPoint` return the tile instead of the icon —
      # which would make the stage-3 occlusion check pass on a broken
      # build. An instrument that cannot see the hazard is worse than none.
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} camera_off?={true} />
        """)

      for selector <- [
            "[data-tile-name-bar]",
            ~s([data-role="mic-indicator"]),
            ~s([data-role="camera-indicator"])
          ] do
        classes = html |> doc() |> Floki.find(selector) |> Floki.attribute("class")
        assert classes != [], "no node matched #{selector}"
        refute Enum.any?(classes, &(&1 =~ "pointer-events-none")), "#{selector} is click-through"
      end
    end
  end

  describe "video_tile/1 — the name bar, mic slot" do
    test "the mic slot renders in BOTH states, with distinct data-mic-state" do
      # An unmuted mic has no other tell on a tile, so an empty slot would
      # be ambiguous with "we forgot to draw it".
      assigns = %{p: participant()}

      on =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={false} />
        """)

      off =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} />
        """)

      assert mic_state(on) == "on"
      assert mic_state(off) == "off"
      assert off =~ "hero-microphone-slash"

      # `"hero-microphone"` is a PREFIX of `"hero-microphone-slash"`, so a
      # bare `=~` on the ON render would also pass if ON drew the slashed
      # glyph. The refute is the half that can actually fail.
      assert on =~ "hero-microphone"
      refute on =~ "hero-microphone-slash"
    end

    test "ON and OFF differ in BOTH the well class and the glyph tone" do
      # The meaning lives in the CONTRAST between the two states: nine
      # unmuted people is nine icons, and at full strength the one muted
      # person stops standing out and the feature inverts. Asserting each
      # state's classes in isolation would pass on two identical
      # treatments, which is exactly the failure being guarded against.
      assigns = %{p: participant()}

      on =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={false} />
        """)

      off =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} />
        """)

      {well_on, tone_on} = mic_treatment(on)
      {well_off, tone_off} = mic_treatment(off)

      refute well_on == well_off, "both mic states draw the same well: #{well_on}"
      refute tone_on == tone_off, "both mic states draw the same tone: #{tone_on}"

      # OFF is the loud one: an --color-error glyph in an --color-error well.
      assert well_off =~ "bg-error/15"
      assert tone_off =~ "text-error"

      # ON is deliberately weak: no well at all, white at low alpha.
      refute well_on =~ "bg-"
      assert tone_on =~ "text-white/45"

      # NOT --color-warning (warning means a human is being asked for
      # something, and a muted person asks nothing of anyone) and NOT
      # --color-success (reserved for SPEAKING, a later ticket).
      refute tone_off =~ "warning"
      refute tone_off =~ "success"
      refute well_off =~ "warning"
      refute well_off =~ "success"
    end

    test "the name is white, not base-content, because the scrim is black in both themes" do
      # `--color-base-content` is `oklch(0% 0 0)` in light theme — black
      # text on a black scrim.
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} />
        """)

      [name_class] =
        html |> doc() |> Floki.find(~s([data-role="tile-name"])) |> Floki.attribute("class")

      assert name_class =~ "text-white"
      refute name_class =~ "text-base-content"
    end
  end

  describe "video_tile/1 — the name bar, camera slot" do
    test "the camera slot is ABSENT when camera_off? is false" do
      # A tile with no video already says the camera is off; drawing
      # "camera on" everywhere spends attention on the state nobody acts on.
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} camera_off?={false} />
        """)

      assert Floki.find(doc(html), ~s([data-role="camera-indicator"])) == []
      # Anti-vacuity: the bar and the mic slot DID render, so the refute
      # above is about the camera slot and not about an empty string.
      assert html =~ "data-tile-name-bar"
      assert mic_state(html) == "on"
    end

    test "the camera slot renders with data-camera-state=off when camera_off? is true" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} camera_off?={true} />
        """)

      [state] =
        html
        |> doc()
        |> Floki.find(~s([data-role="camera-indicator"]))
        |> Floki.attribute("data-camera-state")

      assert state == "off"
      # `hero-video-camera-slash` DOES ship and compile, unlike the mic's.
      assert html =~ "hero-video-camera-slash"
    end

    test "the avatar fallback still renders when camera_off? is true" do
      # The camera slot ADDS to the fallback rather than replacing it: a
      # camera-off tile should read as a person with their camera down,
      # not as a failed feed.
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} video_track={nil} camera_off?={true} />
        """)

      assert html =~ "data-avatar-fallback"
      assert html =~ ~r/data-avatar-fallback[^>]*class="[^"]*flex/
      assert html =~ ~s(data-avatar-kind="human")
    end
  end

  describe "video_tile/1 — the name bar, accessible summary" do
    test "the sr-only sentence names the participant and BOTH states" do
      # The icons ARE the payload of this feature: a screen reader that
      # only gets the name gets nothing.
      assigns = %{p: participant()}

      muted_dark =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} camera_off?={true} />
        """)

      live =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={false} camera_off?={false} />
        """)

      assert summary(muted_dark) == "Alice, muted, camera off"
      assert summary(live) == "Alice, unmuted, camera on"
    end

    test "the summary is sr-only, so it is not a flex item and adds no gap" do
      assigns = %{p: participant()}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} />
        """)

      [class] =
        html
        |> doc()
        |> Floki.find(~s([data-role="tile-state-summary"]))
        |> Floki.attribute("class")

      assert "sr-only" in String.split(class)
    end
  end

  # ── Structural helpers ────────────────────────────────────────────────────
  #
  # Floki rather than a regex: the claim "exactly three absolutely-positioned
  # CHILDREN" is about tree shape, and a substring match cannot tell a child
  # from a grandchild — which is precisely the distinction that separates the
  # fix from the defect.

  @known_overlays ~w(data-video-slot data-avatar-fallback data-tile-name-bar)

  defp doc(html), do: Floki.parse_fragment!(html)

  defp tile_root(html) do
    html
    |> doc()
    |> Enum.filter(&is_tuple/1)
    |> Enum.find(fn node -> "meeting-video-tile" in class_tokens(node) end)
    |> case do
      nil -> flunk("no .meeting-video-tile root in the rendered tile")
      node -> node
    end
  end

  defp element_children(node) do
    node |> Floki.children() |> Enum.filter(&is_tuple/1)
  end

  defp class_tokens({_tag, attrs, _children}) do
    attrs
    |> Enum.find_value("", fn
      {"class", value} -> value
      _ -> nil
    end)
    |> String.split()
  end

  defp has_attr?({_tag, attrs, _children}, name) do
    Enum.any?(attrs, fn {attr, _value} -> attr == name end)
  end

  # The direct children of the tile that are absolutely positioned, named by
  # the data attribute that identifies each. An unrecognised overlay reports
  # its class string rather than being silently counted, so the failure
  # message says WHAT was re-added.
  defp absolute_overlays(html) do
    html
    |> tile_root()
    |> element_children()
    |> Enum.filter(fn node -> "absolute" in class_tokens(node) end)
    |> Enum.map(fn node ->
      Enum.find(@known_overlays, &has_attr?(node, &1)) ||
        "UNKNOWN OVERLAY: " <> Enum.join(class_tokens(node), " ")
    end)
  end

  defp mic_state(html) do
    html
    |> doc()
    |> Floki.find(~s([data-role="mic-indicator"]))
    |> Floki.attribute("data-mic-state")
    |> List.first()
  end

  # `{well_class, glyph_tone_class}` for the mic slot: the well is the
  # indicator element's own class, the tone lives on the glyph span inside it.
  defp mic_treatment(html) do
    slot = Floki.find(doc(html), ~s([data-role="mic-indicator"]))
    assert slot != [], "no mic slot rendered"

    well = slot |> Floki.attribute("class") |> List.first()

    # The glyph is the slot's CHILD, not a `Floki.find(slot, "span")` — that
    # selector matches the slot itself first and would compare the well
    # against the well, which passes whatever the tones are.
    tone =
      slot
      |> List.first()
      |> Floki.children()
      |> Enum.filter(&is_tuple/1)
      |> Floki.attribute("class")
      |> List.first()

    {well, tone}
  end

  defp summary(html) do
    html
    |> doc()
    |> Floki.find(~s([data-role="tile-state-summary"]))
    |> Floki.text()
    |> String.trim()
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

  # ── The name-drop rule (task 01a0740d stage 2) ─────────────────────────────
  #
  # Below a tile width threshold the NAME is dropped and the state icons
  # stay. The rule is a CSS container query. `Phoenix.LiveViewTest` has no
  # layout engine and no CSS at all, so AN ELIXIR TEST CANNOT PROVE THE RULE
  # FIRES. A test that rendered the tile and asserted `data-role="tile-name"`
  # is present would pass identically whether the container query exists,
  # is misspelled, or was deleted — it is the class-string assertion this
  # file's moduledoc already warns about, one abstraction up.
  #
  # So this block asserts exactly two things it CAN establish, and nothing
  # that sounds stronger:
  #
  #   1. The markup gives CSS a stable hook, in BOTH layouts. If the
  #      attribute is renamed the rule silently stops matching, and that is
  #      a failure Elixir can see.
  #   2. `app.css` keys the query to the TILE's own container, not the
  #      cell's, and states the threshold exactly once.
  #
  # The load-bearing proof is a browser. It was run at build time against
  # the compiled stylesheet (headless Chromium, real component HTML, real
  # `[data-gallery-cell]` and `#meeting-bottom-strip` markup): the name's
  # computed `display` flipped from `block` to `none` across the threshold
  # in gallery, and was `none` on a strip tile narrowed to 80px by
  # `env(safe-area-inset-bottom)`. A control run with `container-type`
  # forced back to `normal` kept `display: block` at every width, so the
  # flip is this rule and not something else in the cascade.
  #
  # That run measured the 140px threshold this originally shipped with.
  # Stage 4 moved the threshold to 120px. The stage-3 manual gate and the
  # behavioural e2e gate independently suspended the query and measured
  # seven real names, and both found a truncated name still readable, with
  # the complete given name still rendering, down to a 112-115px tile. So
  # 140px was discarding the name about 25px above where legibility
  # actually degrades. What moved is the NUMBER. The rule and the flip
  # mechanism are untouched, and the browser control above still describes
  # them.
  describe "video_tile/1 — the name-drop hook" do
    test "the name carries [data-role=\"tile-name\"] in BOTH layouts" do
      assigns = %{p: participant(%{name: "Mariah Ellingsworth"})}

      for layout <- [:strip, :gallery] do
        assigns = Map.put(assigns, :layout, layout)

        html =
          rendered_to_string(~H"""
          <.video_tile participant={@p} layout={@layout} />
          """)

        assert html =~ ~s(data-role="tile-name"),
               "layout #{inspect(layout)}: the CSS name-drop rule targets " <>
                 ~s([data-role="tile-name"]; renaming it silently disables the rule)

        # The hook must be on the NAME, not on some other element that
        # merely also renders. Anti-vacuity: the attribute and the
        # participant's name have to be on the same tag.
        assert html =~ ~r/data-role="tile-name"[^>]*>\s*Mariah Ellingsworth/s or
                 html =~ ~r/<span[^>]*data-role="tile-name".{0,300}?Mariah Ellingsworth/s
      end
    end

    test "the name keeps min-w-0 flex-1 truncate and the icons keep shrink-0" do
      # The drop is the LAST resort. Above the threshold the name still has
      # to yield space to the icons rather than push them out of the bar,
      # which is what these four utilities do together. Dropping any of
      # them changes what happens between 141px and a long name.
      assigns = %{p: participant(%{name: "Mariah Ellingsworth"})}

      html =
        rendered_to_string(~H"""
        <.video_tile participant={@p} audio_muted?={true} camera_off?={true} />
        """)

      [_, name_class] =
        Regex.run(~r/data-role="tile-name"\s+class="([^"]*)"/, html)

      name_tokens = String.split(name_class)
      assert "min-w-0" in name_tokens
      assert "flex-1" in name_tokens
      assert "truncate" in name_tokens

      for role <- ["mic-indicator", "camera-indicator"] do
        [_, icon_class] =
          Regex.run(~r/class="([^"]*)"[^>]*data-role="#{role}"/, html)

        icon_tokens = String.split(icon_class)

        assert "flex-shrink-0" in icon_tokens or "shrink-0" in icon_tokens,
               "#{role} must not shrink: the icons are what survives when space runs out"
      end
    end

    test "app.css keys the name-drop query to the TILE, not the gallery cell" do
      # Resolved from __DIR__, not the cwd — a cwd-relative read passes or
      # fails depending on where mix was invoked from, which is a flake.
      css = File.read!(Path.expand("../../../../assets/css/app.css", __DIR__))

      # The tile is its own container. Without this the @container block
      # below matches nothing and the rule is dead CSS.
      assert css =~ ~r/\.meeting-video-tile\s*\{[^}]*container-type:\s*inline-size/
      assert css =~ ~r/\.meeting-video-tile\s*\{[^}]*container-name:\s*video-tile/

      assert css =~ ~r/@container\s+video-tile\s*\(max-width:\s*120px\)/

      # NOT the cell's container. `[data-gallery-cell]` measures the CELL,
      # and the bottom strip has no `[data-gallery-cell]` ancestor at all
      # (`meeting_live.html.heex`, the `#meeting-bottom-strip` footer), so
      # a cell-keyed rule would never fire on half the surfaces this
      # component renders on. `canvas_tile_test.exs` refutes
      # `@container gallery-cell` for its own (sizing) reason; this
      # refutes it again for the name, because a well-meaning "reuse the
      # container we already have" edit is the likely regression.
      refute css =~ ~r/@container\s+gallery-cell/

      # The threshold lives in exactly ONE place. A container-query
      # condition cannot take `var()`, so it is a literal, and a second
      # copy is how two surfaces drift to two thresholds. Counted inside
      # the at-rule condition specifically, so unrelated `140px` values
      # elsewhere in the file (the legacy `.meeting-tile` grid tracks) do
      # not make this pass or fail.
      thresholds = Regex.scan(~r/@container\s+video-tile\s*\(max-width:\s*(\d+)px\)/, css)
      assert length(thresholds) == 1

      # The number's PROVENANCE has to stay in the file. It is no longer
      # provisional: stage 4 lowered it to 120px against two independent
      # measurements. But a bare magic number invites deleting the rule
      # instead of retuning it, and the next person needs the floor those
      # measurements found rather than a fresh re-derivation of it.
      assert css =~ "MEASURED, NOT REASONED"
      assert css =~ "112-115px"
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
