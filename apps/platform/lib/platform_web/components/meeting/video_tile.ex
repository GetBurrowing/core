defmodule PlatformWeb.Components.Meeting.VideoTile do
  @moduledoc """
  A single LiveKit video tile for a human meeting participant.

  Origin: sibling task 019e2475-0037 — Meetings: bottom video strip (humans +
  agent presence tiles). This file is a verbatim copy committed inside task
  019e2474-bc7c (stage 3 — Screen + Gallery mode renderers) so the Gallery
  renderer can reuse it without depending on an unmerged sibling branch. The
  stack rollup will reconcile this duplicate.

  Spec: docs/decisions/0042-meeting-system-with-collaborative-canvas.md (Layout → Bottom strip).

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
      id={"video-tile-#{@identity}"}
      phx-hook="MeetingVideoTile"
      data-participant={@identity}
      data-has-video={to_string(@has_video?)}
      data-meeting-video-tile
      class={[
        "meeting-video-tile group relative overflow-hidden rounded-lg bg-base-300",
        "aspect-video h-full shrink-0",
        @speaking? && "ring-2 ring-primary",
        @class
      ]}
      {@rest}
    >
      <%!-- Video slot: JS hook appends the LiveKit <video> element here. --%>
      <div
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
