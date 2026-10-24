defmodule PlatformWeb.Components.Meeting.AgentTile do
  @moduledoc """
  A single agent presence tile for a meeting bottom strip.

  Task: 019e2475-0037 — Meetings: bottom video strip (humans + agent presence tiles).
  Meeting system: docs/decisions/0030-meetings-livekit-voice-video.md.

  The bottom-strip layout itself is NOT specified in any ADR. A grep for
  "bottom strip" across docs/ returns nothing -- the phrase lives only in
  code. This module and its tests ARE the specification. The citation this
  line previously carried named a file that has never existed in the repo,
  and 0042 is a duplicated ADR number besides (01a04a5e-c28f), so it was
  ambiguous as well as dangling.

  Agents do not publish video tracks, so the tile is a presentation-only avatar
  card sized identically to `<.video_tile>` (16:9, full-height of the strip)
  with three deliberate affordances:

    1. The agent avatar/initials centred on the agent's identity slot
       (task 01a1557a rung 3 stage 3): `data-agent-slot` points app.css's
       `--ag`, `--ag-text` and `--ag-tint` at that slot's tokens, and
       `.meeting-agent-tile` paints the slot's 3px rail (an inset shadow, so
       no geometry moves), its 8% tint behind avatar AND voice tiles, and a
       2px `--ag` avatar ring, exactly as a chat agent row does.
    2. A small status dot in the bottom-right whose presence + tone reflects the
       `activity_state`. `:idle` hides the dot entirely; the active states use
       `animate-pulse` + `bg-success` so the meeting bar quietly signals which
       agents are working without a flicker storm.
    3. A name chip below the avatar: `<name> · <role>`, the role label
       ('listener' / 'designer' / 'specialist', falling back to 'agent')
       truncating first and the name last (Saru's canvas 01a15b1e-d673: "the
       name is the last thing to truncate ... and the ring never replaces
       it"). Colour is never the only identifier. Hero icons only.

  The tile is reused by both the meeting bottom strip (stage 3) and any future
  agent-presence surfaces, so the caller controls outer sizing via the
  surrounding flex/grid container — same contract as VideoTile.

  ## Props

    * `:agent_participant` — map/struct describing the agent. Must expose
      `:id` (or `:identity`) and `:name`. Required.
    * `:role` — short human-readable role label rendered in the chip. Optional;
      defaults to `"agent"`. Spec values include `"listener"`, `"designer"`,
      `"specialist"`.
    * `:activity_state` — one of `:idle`, `:typing`, `:computing`,
      `:listening`, `:failed`. Drives the activity badge. Defaults to `:idle`.
    * `:slot` — the agent's `Platform.Agents.ColorPalette` slot id, from
      `Chat.agent_slot_map_for_participants/1`. nil, blank or unknown is
      "blue" (`ColorPalette.slot_for/1`). Replaces the old free-form hex
      `:accent_color`, which no caller ever passed.
    * `:avatar_url` — optional avatar image URL.
    * `:dock?` — render as the GALLERY AGENT DOCK tile rather than the short
      mixed "who's here" strip tile. The dock is a taller, bordered panel
      (see `meeting_live.html.heex`), so the activity badge is laid out as a
      full-width centered bar with its WORD VISIBLE instead of a corner glyph
      with the word suppressed. Defaults to `false`.
  """

  use Phoenix.Component

  alias Platform.Agents.ColorPalette

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]
  import PlatformWeb.Components.Meetings.AgentActivityBadge, only: [agent_activity_badge: 1]
  import PlatformWeb.Components.Meeting.VoiceWaveform, only: [voice_waveform: 1]

  # `:failed` belongs here because `MeetingLive.agent_activity_state/2`
  # can return it and the strip's call site passes that straight through;
  # leaving it out made the attr `values:` a lie rather than a guard.
  @activity_states [:idle, :typing, :computing, :listening, :failed]

  @role_labels %{
    "listener" => "listener",
    "designer" => "designer",
    "specialist" => "specialist"
  }

  attr(:agent_participant, :map, required: true, doc: "agent with :id (or :identity) and :name")
  attr(:role, :string, default: nil, doc: "role label; falls back to 'agent' when nil/blank")

  attr(:activity_state, :atom,
    default: :idle,
    values: @activity_states,
    doc: "drives the activity dot; :idle hides it"
  )

  attr(:slot, :string,
    default: nil,
    doc: "ColorPalette slot id; nil, blank or unknown is \"blue\""
  )

  attr(:avatar_url, :string, default: nil, doc: "avatar image URL")

  attr(:dock?, :boolean,
    default: false,
    doc: "gallery dock tile: taller, so the activity WORD renders instead of being suppressed"
  )

  attr(:speaking?, :boolean,
    default: false,
    doc: "draws the same ring-2 ring-primary VideoTile uses for an active speaker"
  )

  attr(:voice?, :boolean,
    default: false,
    doc:
      "the agent is in the call by VOICE (its row carries an agent LiveKit identity): " <>
        "the centre shows the voice waveform instead of the avatar, on the slot's tint " <>
        "(task 01a1117f stage 4; task 01a1557a rung 3 stage 3)"
  )

  attr(:id_prefix, :string,
    default: "agent-tile",
    doc:
      "dom id prefix. The gallery grid passes a DISTINCT prefix so a speaking agent " <>
        "promoted into the grid cannot collide ids with its bottom-dock tile."
  )

  attr(:class, :any, default: nil, doc: "extra classes for the outer tile element")
  attr(:rest, :global)

  def agent_tile(assigns) do
    identity = agent_identity(assigns.agent_participant)
    name = agent_name(assigns.agent_participant)
    role_label = normalize_role(assigns.role)
    # A voice tile takes the same slot tint as an avatar tile: its waveform
    # bars are `base-content /60`, a painted strength, measured on every
    # painted tint by agent_slot_tokens_guard_test.exs (>= 3:1).
    assigns =
      assigns
      |> assign(:identity, identity)
      |> assign(:name, name)
      |> assign(:role_label, role_label)
      |> assign(:slot_id, ColorPalette.slot_for(assigns.slot))
      |> assign(:active?, assigns.activity_state != :idle)

    ~H"""
    <div
      id={"#{@id_prefix}-#{@identity}"}
      data-agent-tile
      data-agent={@identity}
      data-activity-state={Atom.to_string(@activity_state)}
      data-speaking={@speaking? && "true"}
      data-agent-slot={@slot_id}
      class={
        [
          "meeting-agent-tile group relative overflow-hidden rounded-lg",
          "aspect-video h-full shrink-0",
          # Same speaking affordance VideoTile draws. `ring-*` is an
          # outline-style paint, so it changes no geometry — the scope
          # fence on tile sizing/layout holds. It stays primary: speaking is
          # a status, never the agent hue. app.css's `.meeting-agent-tile`
          # rule composes the slot rail with this ring's shadow.
          @speaking? && "ring-2 ring-primary",
          @class
        ]
      }
      {@rest}
    >
      <%!-- Avatar centred on the slot tint, or — for an agent in
           the call by voice — the voice waveform (task 01a1117f stage 4). A
           voice agent has no camera and is not a person, so a face does not
           fit; a pending or text-only agent keeps its avatar, because a
           waveform there would claim a voice that is not in the room. --%>
      <div class="absolute inset-0 flex items-center justify-center">
        <.voice_waveform
          :if={@voice?}
          id={"#{@id_prefix}-wave-#{@identity}"}
          identity={@identity}
          bars={8}
          size={:tile}
        />
        <%!-- `agent_avatar/1`, not `human_avatar/1` — a tile is an agent by
             definition, and the human component would draw two initials over
             the seeded human palette under `data-avatar-kind="human"`. --%>
        <.agent_avatar
          :if={!@voice?}
          name={@name}
          avatar_url={@avatar_url}
          size="lg"
          class="agent-tile-avatar"
        />
      </div>

      <%!-- Activity indicator. NOT a colour-only dot: `agent_activity_badge/1`
           owns the ring colour, glyph and word per state, so a `:failed`
           agent reads as a red `!` instead of the healthy green pulse this
           tile drew for every non-idle state.

           Two layouts, and the difference is only ever about ROOM:

             * `dock?` (gallery agent dock) — a full-width centered bar sitting
               above the role chip. The dock footer is tall enough for it, so
               the WORD RENDERS. This is the intended presentation: the badge's
               own moduledoc is explicit that the contract is ring + glyph +
               WORD and never colour alone, because colour at avatar size is a
               few pixels and fails a colourblind viewer outright.

             * otherwise (short mixed "who's here" strip) — a corner glyph, with
               the word suppressed by `agent-tile-activity` (app.css). That
               strip tile really is ~40px and the word does not fit. The class
               is applied ONLY here, so the suppression can no longer reach the
               dock: stage 1 shipped it unscoped and that hid the word
               everywhere, which defeated the component. --%>
      <div
        :if={@active?}
        data-activity-indicator
        class={
          if @dock?,
            do: "absolute inset-x-0 bottom-6 flex justify-center px-1",
            else: "agent-tile-activity absolute bottom-1 right-1"
        }
      >
        <.agent_activity_badge state={@activity_state} name={@name} />
      </div>

      <%!-- Name chip pinned below the avatar inside the tile: `<name> · <role>`.
           The role shrinks 999x faster than the name, so it truncates first
           and the name last. `.agent-tile-chip` (app.css) paints the band
           the white text sits on; the measured ratios are recorded there. --%>
      <div class="agent-tile-chip absolute inset-x-0 bottom-0 bg-black/60 px-1.5 pb-0.5 pt-2">
        <div class="flex min-w-0 items-center gap-1 text-[10px] font-medium text-white">
          <span class="hero-cpu-chip block size-3 shrink-0" aria-hidden="true" />
          <span data-name-chip class="min-w-0 shrink truncate">{@name}</span>
          <span class="min-w-0 shrink-[999] truncate">
            <span aria-hidden="true">{"· "}</span><span data-role-chip>{@role_label}</span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ── Field extraction ───────────────────────────────────────────────────────
  # Tolerant of both maps and structs; falls back gracefully so a partially
  # populated agent_participant never crashes the render.

  defp agent_identity(%{identity: identity}) when is_binary(identity) and identity != "",
    do: identity

  defp agent_identity(%{id: id}) when is_binary(id) and id != "", do: id
  defp agent_identity(%{id: id}) when not is_nil(id), do: to_string(id)
  defp agent_identity(_), do: "unknown"

  defp agent_name(%{name: name}) when is_binary(name) and name != "", do: name

  defp agent_name(%{display_name: name}) when is_binary(name) and name != "",
    do: name

  defp agent_name(%{identity: identity}) when is_binary(identity) and identity != "",
    do: identity

  defp agent_name(_), do: "Agent"

  # ── Role normalization ─────────────────────────────────────────────────────

  defp normalize_role(role) when is_binary(role) do
    trimmed = String.trim(role)

    case trimmed do
      "" -> "agent"
      label -> Map.get(@role_labels, String.downcase(label), label)
    end
  end

  defp normalize_role(_), do: "agent"
end
