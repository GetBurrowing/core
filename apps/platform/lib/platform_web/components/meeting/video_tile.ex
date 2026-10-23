defmodule PlatformWeb.Components.Meeting.VideoTile do
  @moduledoc """
  A single LiveKit video tile for a human meeting participant.

  Origin: sibling task 019e2475-0037 — Meetings: bottom video strip (humans +
  agent presence tiles). This file is a verbatim copy committed inside task
  019e2474-bc7c (stage 3 — Screen + Gallery mode renderers) so the Gallery
  renderer can reuse it without depending on an unmerged sibling branch. The
  stack rollup will reconcile this duplicate.

  Meeting system: docs/decisions/0030-meetings-livekit-voice-video.md.

  The bottom-strip layout itself is NOT specified in any ADR. A grep for
  "bottom strip" across docs/ returns nothing -- the phrase lives only in
  code. This module and its tests ARE the specification. The citation this
  line previously carried named a file that has never existed in the repo,
  and 0042 is a duplicated ADR number besides (01a04a5e-c28f), so it was
  ambiguous as well as dangling.

  Renders one human participant's video feed. The actual LiveKit `MediaStreamTrack`
  is attached client-side: the `MeetingVideoTile` JS hook (mirroring the tile
  plumbing in `assets/js/hooks/meeting_client.js`) targets the
  `[data-video-slot]` element by the participant's `data-participant` identity
  and appends the `<video>` element there when a track is subscribed.

  This component is intentionally presentation-only and self-contained so it can
  be reused by both the bottom video strip and member 3's Gallery mode — the
  caller controls sizing via the surrounding fl/grid container.

  ## Props

    * `:participant` — map/struct describing the participant. Must expose
      `:identity` (LiveKit identity, used as the JS-hook target key) and
      `:name` (display name). Required.
    * `:video_track` — truthy when the participant currently has a video track
      published. When `nil`/`false`, the avatar fallback renders instead.
      The video element itself is attached by JS; this flag only drives which
      visual state the server renders.
    * `:audio_muted?` — the participant's mic state. Drives the mic slot in
      the name bar, which renders in BOTH states (see "The name bar" below).
    * `:camera_off?` — the participant's camera state. Drives a camera slot in
      the name bar that renders ONLY when off.
    * `:speaking?` — when `true`, the tile gets a `ring-2 ring-primary` active
      speaker treatment.
    * `:avatar_url` — optional avatar image URL for the camera-off fallback.

  ## The name bar (task 01a0740d stage 1)

  The name and both state indicators are ONE absolutely-positioned child,
  `[data-tile-name-bar]`, and the tile has exactly three absolutely-
  positioned children in total: the video slot, the avatar fallback, and
  the bar, in that order, with the bar LAST.

  That count is the fix, not a tidiness preference. This component used to
  carry TWO independent bottom overlays — a 19px `[data-mute-indicator]`
  chip at `bottom-1 left-1` and a full-width name label at `inset-x-0
  bottom-0` — neither setting a `z-index`, both claiming the same pixels.
  FE-3 stage 3 measured it live: `document.elementFromPoint` at the badge's
  own centre returned the NAME LABEL, because the label came later in DOM
  order. The badge rendered, reported `display: block, opacity: 1,
  visibility: visible`, and passed every DOM assertion written against it.
  The product lead still could not see it.

  Relocating that chip would not have fixed it. At 19px on a 155x218 tile
  it is 361px² of 33,790px², about 1% of the tile, competing with moving
  video — invisible in any corner. What makes state readable is a band with
  its own ground, which the eye already lands on because the name lives
  there. So the scrim IS the bar's container rather than a fourth overlay,
  and one element means the name and the icons cannot overlap each other by
  layout at all.

  `overflow-hidden` on the tile gives the scrim the tile's corner radius,
  so the bar needs no radius of its own and no inset.

  NOTHING HERE MAY TAKE `pointer-events-none`. It would suppress the
  `title` tooltips, and it would make `document.elementFromPoint` return
  the tile instead of the icon — which would make the occlusion check that
  caught the original defect pass on a broken build. An instrument that
  cannot see the hazard is worse than no instrument.

  ## Two icons, two rules

  The state vocabulary mirrors
  `PlatformWeb.Components.Meetings.ParticipantRail` (`mic_state/1`,
  `camera_state/1`, `well_class/1`, `glyph_tone/1`, `state_sentence/3`) so
  the roster and the tile cannot drift, with ONE deliberate divergence: on
  the tile the ON state has NO well.

    * Mic renders in BOTH states. An unmuted mic has no other tell on a
      tile, so an empty slot would be ambiguous with "we forgot to draw it".
    * ON is deliberately weak — a bare 16px glyph, no well, white at 45%.
      Nine unmuted people is nine icons; at full strength the one muted
      person stops standing out and the feature inverts. The meaning lives
      in the CONTRAST between the two states, not in either alone.
    * OFF gets the full treatment: `--color-error` glyph in an
      `--color-error`-tinted well.
    * Camera renders ONLY when off. A tile with no video already says so,
      and the avatar fallback is untouched, so a camera-off tile reads as a
      person with their camera down rather than as a failed feed.

  Never `--color-warning`: on this screen warning means a human is being
  asked for something, and a muted person asks nothing of anyone. Never
  `--color-success`: reserved for SPEAKING, a later ticket that will want
  the tile border. That channel is left unspent.

  ### Why `text-white` and not `--color-base-content`

  The design canvas assigns `--color-base-content` to the name and to the
  ON glyph. That is wrong on this surface: in light theme
  `--color-base-content` is `oklch(0% 0 0)`, pure black (`app.css`), and
  the scrim is black in BOTH themes, so the name would be black on black in
  light mode. The canvas got the reasoning right one row above, for the
  scrim itself, and did not carry it down to the content sitting on that
  ground. The shipped name label already used `text-white` over
  `from-black/60`, so this follows the existing precedent.
  `--color-error` keeps its semantic token. Its value differs per theme
  (task 01a160c4 retuned it: `#da1729` light, `#f53c41` dark).

  ### The mic glyph draws, as of FE-19

  `hero-microphone-slash` did not ship in Heroicons, so until FE-19
  (`01a07486-7985-7001-87ce-277681791f52`) the class generated NO CSS and
  a muted mic painted its red well around an empty centre. FE-19 vendored
  `assets/icons/24/outline/microphone-slash.svg` and taught
  `assets/vendor/heroicons.js` to read that second root, so the class now
  resolves at every call site with no call-site change. The class here was
  kept, not swapped, for exactly that reason. `hero-video-camera-slash`
  ships upstream and always compiled. The guard in
  `test/platform_web/hero_icon_resolution_guard_test.exs` fails if either
  stops resolving.
  """

  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [human_avatar: 1]

  attr(:participant, :map, required: true, doc: "participant with :identity and :name")
  attr(:video_track, :any, default: nil, doc: "truthy when a video track is published")

  attr(:audio_muted?, :boolean,
    default: false,
    doc: "mic state for the name bar's mic slot, which renders in BOTH states"
  )

  attr(:camera_off?, :boolean,
    default: false,
    doc: "renders the name bar's camera slot when true; the slot is absent when false"
  )

  attr(:speaking?, :boolean, default: false, doc: "renders active-speaker ring when true")
  attr(:avatar_url, :string, default: nil, doc: "avatar image for camera-off fallback")
  attr(:class, :any, default: nil, doc: "extra classes for the outer tile element")

  attr(:id_prefix, :string,
    default: "video-tile",
    doc:
      "prefix for the tile's dom id (`#{:id_prefix}-#{:identity}`). MeetingLive deliberately passes DIFFERENT prefixes for the gallery (`gallery-tile`) and bottom strip (`strip-tile`) so the two surfaces don't share a dom id per participant — sharing the id used to encourage morphdom to move/reuse the node across stage_mode swaps, but in practice the injected remote `<video>` dropped on every gallery↔strip transition. Distinct ids give us clean destroy-and-mount so the hook's `_detach`/`_syncExistingTrack` lifecycle reliably re-binds the LiveKit track on the freshly mounted tile. The persistent local self-view anchor (task 019e42f6) passes `local-self-view` for the same reason — a DISTINCT, never-unmounted tile for the local identity that survives mode switches."
  )

  attr(:layout, :atom,
    default: :strip,
    values: [:strip, :gallery],
    doc:
      "sizing strategy. :strip keeps `aspect-video h-full` for the fixed-height bottom strip; :gallery uses `aspect-video max-w-full max-h-full w-auto h-auto` so the tile preserves 16:9 and grows to whichever cell dimension fits first, letterboxing the other axis. The grid caller pairs this with `place-items-center` to center the tile in its cell."
  )

  attr(:rest, :global)

  def video_tile(assigns) do
    identity = participant_identity(assigns.participant)
    name = participant_name(assigns.participant)

    assigns =
      assigns
      |> assign(:identity, identity)
      |> assign(:name, name)
      |> assign(:has_video?, !!assigns.video_track)
      |> assign(:mic_state, mic_state(assigns.audio_muted?))
      |> assign(:camera_state, camera_state(assigns.camera_off?))

    ~H"""
    <div
      id={"#{@id_prefix}-#{@identity}"}
      phx-hook="MeetingVideoTile"
      data-participant={@identity}
      data-has-video={to_string(@has_video?)}
      data-meeting-video-tile
      class={[
        "meeting-video-tile group relative overflow-hidden rounded-lg bg-base-300",
        tile_layout_classes(@layout),
        @speaking? && "ring-2 ring-primary",
        @class
      ]}
      {@rest}
    >
      <%!-- Video slot: JS hook appends the LiveKit <video> element here.
           `phx-update="ignore"` + stable id: morphdom must NOT touch the
           injected <video>. Without this, any LV re-render that touches a
           sibling (new joiner added to `:participants`, stage_mode change,
           speaking-ring toggle) wipes the <video> because LV thinks the
           slot has no children. The hook's `_attach`/`_detach` already
           toggles the `hidden` class on the slot, so the visibility state
           still tracks `data-has-video` correctly even though morphdom
           skips this subtree on subsequent patches.

           ── Contract (task 019f8153, custom-ElementInfo fix) — LOAD-BEARING ──
           The stable `id={"video-slot-#{@id_prefix}-#{@identity}"}` (below)
           and `phx-update="ignore"` are not merely a morphdom nicety; they
           are a hard prerequisite for the JS custom-ElementInfo fix. The
           `MeetingVideoTile` hook attaches exactly ONE stable `<video>` node
           into this slot and hands a direct reference to it to
           `StableTileElementInfo.element`. That hook is now the SOLE LiveKit
           visibility oracle — the SDK's own default IntersectionObserver
           watcher is intentionally never installed (the hook pre-registers
           its ElementInfo via `observeElementInfo` BEFORE `track.attach(el)`).
           So the `<video>` MUST remain a single node morphdom never replaces
           across LiveView patches: if it were swapped, the SDK's stored
           element reference would dangle and the tile would black-screen with
           no resume.

           Any future change that (a) removes `phx-update="ignore"`, (b)
           alters the slot-id derivation so the id is no longer stable per
           identity, or (c) lets the server render children INTO this slot
           (morphdom would then reconcile — and drop — the injected `<video>`)
           resurrects the exact black-tile class this task eliminated. Cross-
           reference `assets/js/hooks/meeting_video_tile.js` (the `_attach`
           boundary note + `StableTileElementInfo`) and the slot-identity
           regression test `test/platform_web/live/meeting_live_test.exs`
           ("[data-video-slot] identity stability across state-touching
           events").

           Avatar fallback below intentionally stays morphdom-driven so
           per-render attribute changes (name, avatar_url) still flow. --%>
      <div
        id={"video-slot-#{@id_prefix}-#{@identity}"}
        phx-update="ignore"
        data-video-slot
        class={[
          "absolute inset-0 h-full w-full",
          !@has_video? && "hidden"
        ]}
      >
      </div>

      <%!-- Camera-off fallback: avatar centered on bg-base-300. --%>
      <div
        data-avatar-fallback
        class={[
          "absolute inset-0 flex items-center justify-center bg-base-300",
          @has_video? && "hidden"
        ]}
      >
        <.human_avatar name={@name} avatar_url={@avatar_url} seed={@identity} size="lg" />
      </div>

      <%!-- Name bar: name + both state slots, ONE overlay, LAST child.
           See the moduledoc — the count of absolutely-positioned children
           is the fix, and the scrim is this element's own background
           rather than a fourth overlay stacked under it. No
           `pointer-events-none` anywhere inside: it would suppress the
           `title` tooltips and blind `elementFromPoint`. --%>
      <div
        data-tile-name-bar
        class="absolute inset-x-0 bottom-0 flex h-[40%] min-h-7 items-end bg-gradient-to-t from-black/[0.72] to-transparent"
      >
        <div class="flex h-7 w-full items-center gap-1.5 px-2">
          <span
            data-role="tile-name"
            class="min-w-0 flex-1 truncate text-[13px] font-medium leading-none text-white"
          >
            {@name}
          </span>

          <%!-- Mic: BOTH states. ON is the bare glyph with no well, so a
               grid of unmuted people recedes and the muted one reads. --%>
          <span
            class={["grid flex-shrink-0 place-items-center", well_class(@mic_state)]}
            role="img"
            aria-label={mic_label(@mic_state)}
            title={mic_title(@mic_state)}
            data-role="mic-indicator"
            data-mic-state={to_string(@mic_state)}
          >
            <span class={[glyph_size(@mic_state), mic_glyph(@mic_state), glyph_tone(@mic_state)]}>
            </span>
          </span>

          <%!-- Camera: OFF only. A tile with no video already says the
               camera is off; drawing "camera on" everywhere spends
               attention on the state nobody acts on. --%>
          <span
            :if={@camera_off?}
            class={["grid flex-shrink-0 place-items-center", well_class(:off)]}
            role="img"
            aria-label={camera_label(:off)}
            title={camera_title(:off)}
            data-role="camera-indicator"
            data-camera-state="off"
          >
            <span class={[glyph_size(:off), camera_glyph(:off), glyph_tone(:off)]}></span>
          </span>
        </div>

        <%!-- The icons ARE the payload of this feature, so a screen reader
             that only gets the name gets nothing. `sr-only` is
             `position: absolute`, so this is not a flex item and adds no
             gap to the row above it — the same trick `participant_rail.ex`
             documents. The per-icon `aria-label`s stay alongside it so the
             two are also reachable one at a time. --%>
        <span class="sr-only" data-role="tile-state-summary">
          {state_sentence(@name, @mic_state, @camera_state)}
        </span>
      </div>
    </div>
    """
  end

  # ── Name-bar state vocabulary (task 01a0740d stage 1) ──────────────────────
  #
  # Deliberately the same function names, the same atoms and the same
  # tokens as `PlatformWeb.Components.Meetings.ParticipantRail`, so the
  # roster and the tile cannot drift apart on what "off" looks like. The
  # ONE divergence is `well_class(:on)`, and it is argued in the moduledoc:
  # the rail draws one row per person in a scanned column where a neutral
  # well helps alignment, while the tile draws one icon per FACE in a grid
  # of moving video, where nine equally-weighted wells would drown the one
  # that matters.

  defp mic_state(true), do: :off
  defp mic_state(_muted?), do: :on

  defp camera_state(true), do: :off
  defp camera_state(_off?), do: :on

  # OFF gets a tinted well; ON gets NO well at all — not a neutral one.
  # `bg-base-300` over arbitrary video would be a small opaque box on a
  # moving image, which is the corner-badge failure mode again.
  defp well_class(:off), do: "size-5 rounded-md bg-error/15"
  defp well_class(_state), do: "size-4"

  # The glyph is bigger in the weak state than in the strong one: the ON
  # glyph is the whole slot (16px, no well), while OFF is 14px INSIDE a
  # 20px well, so the well is what carries OFF's extra weight.
  defp glyph_size(:off), do: "size-3.5"
  defp glyph_size(_state), do: "size-4"

  # `text-white`, not `text-base-content`: the scrim is black in both
  # themes and `--color-base-content` is pure black in light theme. See
  # the moduledoc. `--color-error` is the same in both themes and keeps
  # its semantic token.
  defp glyph_tone(:off), do: "text-error"
  defp glyph_tone(_state), do: "text-white/45"

  # `hero-microphone-slash` resolves and paints as of FE-19 — see the
  # moduledoc. It is our vendored glyph, not an upstream Heroicon.
  defp mic_glyph(:off), do: "hero-microphone-slash"
  defp mic_glyph(_state), do: "hero-microphone"

  # `hero-video-camera-slash` ships upstream, in all four Heroicons sizes.
  defp camera_glyph(_state), do: "hero-video-camera-slash"

  defp mic_label(:off), do: "Microphone muted"
  defp mic_label(_state), do: "Microphone on"

  defp mic_title(:off), do: "Muted"
  defp mic_title(_state), do: "Mic on"

  defp camera_label(_state), do: "Camera off"

  defp camera_title(_state), do: "Camera off"

  # The whole tile state in plain words, for the `sr-only` line only. The
  # visible bar says this with icons; nine tiles reading "unmuted, camera
  # on" would be a wall of text announcing that nothing happened. Same
  # sentence shape as the rail's, so a viewer hears the same words on
  # both surfaces.
  defp state_sentence(name, mic_state, camera_state) do
    "#{name}, #{mic_word(mic_state)}, #{camera_word(camera_state)}"
  end

  defp mic_word(:off), do: "muted"
  defp mic_word(_state), do: "unmuted"

  defp camera_word(:off), do: "camera off"
  defp camera_word(_state), do: "camera on"

  # ── Sizing strategy ────────────────────────────────────────────────────────
  # :strip is the original bottom-strip contract — the caller provides a
  # fixed-height container (e.g. `h-[96px] lg:h-[120px]`) and the tile
  # derives its width from 16:9. `h-full shrink-0` is correct there
  # because there is no orthogonal width constraint to compete with.
  #
  # :gallery is the responsive-grid contract — the cell has BOTH a width
  # AND a height (from `auto-rows-fr` + `grid-cols-N grid-rows-M`). The
  # tile must PRESERVE 16:9 (no horizontal/vertical stretching that
  # distorts faces) AND grow as large as the cell allows, letterboxing
  # the unused axis with the grid container's `place-items-center`.
  #
  # `aspect-video max-w-full max-h-full w-auto h-auto` does exactly this:
  # the aspect-video sets a 16:9 intrinsic ratio; max-w/max-h caps growth
  # at the cell bounds; w-auto/h-auto lets the larger axis breathe to
  # whichever dimension is the binding constraint. Pairing with
  # `place-items-center` on the grid centers the tile in its cell.
  #
  # Why not `h-full w-full` (f1e16f1, REJECTED): forcing both axes to
  # 100% inside a tall cell (e.g. 312×780 for 2p sideways) makes the
  # tile 312×780 — tall, narrow, distorted. The operator: "it shouldn't go long
  # vertically".
  #
  # Why not bare `aspect-video h-full` (3ee579f, REJECTED): without
  # max-bounds the tile blows past the cell in the unconstrained axis
  # and the layout collapses to a small floating thumbnail.
  # Gallery sizing: the tile preserves 16:9 AND grows as large as
  # possible within its cell, letterboxing the unused axis. Pure-CSS
  # `aspect-ratio` with explicit width AND height becomes intrinsic
  # (effectively ignored), so we use a CSS container query keyed off
  # the cell's aspect ratio to pick the binding axis (height-bound
  # for wider-than-16:9 cells, width-bound for narrower-than-16:9
  # cells). The actual CSS lives in `apps/platform/assets/css/app.css`
  # under the `[data-gallery-cell] > .meeting-video-tile` selector
  # — see the comment block there. Here we keep the class string
  # minimal so the @container rules can take over.
  #
  # `:strip` is the original bottom-strip contract — the caller
  # provides a fixed-height container and tiles derive width from
  # 16:9. `h-full shrink-0` is correct because the strip has no
  # orthogonal width constraint.
  defp tile_layout_classes(:gallery), do: ""

  defp tile_layout_classes(_), do: "aspect-video h-full shrink-0"

  # ── Participant field extraction ───────────────────────────────────────────
  # Tolerant of both maps and structs; falls back gracefully so a partially
  # populated participant never crashes the render.

  defp participant_identity(%{identity: identity}) when is_binary(identity) and identity != "",
    do: identity

  defp participant_identity(%{id: id}) when is_binary(id) and id != "", do: id
  defp participant_identity(%{id: id}) when not is_nil(id), do: to_string(id)
  defp participant_identity(_), do: "unknown"

  defp participant_name(%{name: name}) when is_binary(name) and name != "", do: name

  defp participant_name(%{display_name: name}) when is_binary(name) and name != "",
    do: name

  defp participant_name(%{identity: identity}) when is_binary(identity) and identity != "",
    do: identity

  defp participant_name(_), do: "Participant"
end
