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
    * `:audio_muted?` — when `true`, a `hero-microphone-slash` overlay shows.
    * `:speaking?` — when `true`, the tile gets a `ring-2 ring-primary` active
      speaker treatment.
    * `:avatar_url` — optional avatar image URL for the camera-off fallback.
  """

  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [human_avatar: 1]

  attr(:participant, :map, required: true, doc: "participant with :identity and :name")
  attr(:video_track, :any, default: nil, doc: "truthy when a video track is published")
  attr(:audio_muted?, :boolean, default: false, doc: "renders mute overlay when true")
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

      <%!-- Mute indicator: hero-microphone-slash in the corner. --%>
      <div
        :if={@audio_muted?}
        data-mute-indicator
        class="absolute bottom-1 left-1 rounded-full bg-base-100/80 p-1 text-error shadow"
        title={"#{@name} is muted"}
      >
        <span class="hero-microphone-slash block size-3.5" aria-hidden="true" />
        <span class="sr-only">{@name} is muted</span>
      </div>

      <%!-- Name label. --%>
      <div class="absolute inset-x-0 bottom-0 truncate bg-gradient-to-t from-black/60 to-transparent px-1.5 pb-0.5 pt-2 text-[10px] font-medium text-white">
        {@name}
      </div>
    </div>
    """
  end

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
  # tile 312×780 — tall, narrow, distorted. Rowan: "it shouldn't go long
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
