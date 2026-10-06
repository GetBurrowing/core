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

    1. The agent avatar/initials centered on an `accent_color` background — the
       agent's own brand color when present, otherwise `bg-base-200` per spec.
    2. A small status dot in the bottom-right whose presence + tone reflects the
       `activity_state`. `:idle` hides the dot entirely; the active states use
       `animate-pulse` + `bg-success` so the meeting bar quietly signals which
       agents are working without a flicker storm.
    3. A role chip below the avatar with the agent's role label —
       'listener' / 'designer' / 'specialist', falling back to 'agent' when no
       role is supplied. Hero icons only.

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
    * `:accent_color` — optional hex color (e.g. `"#7c3aed"`) used as the tile
      background. When `nil`, falls back to `bg-base-200` so the tile remains
      legible against the meeting chrome.
    * `:avatar_url` — optional avatar image URL.
    * `:dock?` — render as the GALLERY AGENT DOCK tile rather than the short
      mixed "who's here" strip tile. The dock is a taller, bordered panel
      (see `meeting_live.html.heex`), so the activity badge is laid out as a
      full-width centered bar with its WORD VISIBLE instead of a corner glyph
      with the word suppressed. Defaults to `false`.
  """

  use Phoenix.Component

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

  attr(:accent_color, :string,
    default: nil,
    doc: "hex tile background; falls back to bg-base-200"
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
        "the centre shows the voice waveform instead of the avatar, on bg-base-200 " <>
        "whatever the accent colour (task 01a1117f stage 4)"
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
    # A voice tile keeps the `bg-base-200` ground even when the agent has an
    # accent colour (stage spec, deviation 3): the waveform bars are
    # `base-content /60`, whose contrast is measured on base-200 in both
    # themes and unmeasured on an arbitrary accent hex.
    accent_style =
      if assigns.voice?, do: nil, else: accent_background_style(assigns.accent_color)

    accent_active? = !is_nil(accent_style)

    assigns =
      assigns
      |> assign(:identity, identity)
      |> assign(:name, name)
      |> assign(:role_label, role_label)
      |> assign(:accent_style, accent_style)
      |> assign(:accent_active?, accent_active?)
      |> assign(:active?, assigns.activity_state != :idle)

    ~H"""
    <div
      id={"#{@id_prefix}-#{@identity}"}
      data-agent-tile
      data-agent={@identity}
      data-activity-state={Atom.to_string(@activity_state)}
      data-speaking={@speaking? && "true"}
      class={
        [
          "meeting-agent-tile group relative overflow-hidden rounded-lg",
          "aspect-video h-full shrink-0",
          # Same speaking affordance VideoTile draws. `ring-*` is an
          # outline-style paint, so it changes no geometry — the scope
          # fence on tile sizing/layout holds.
          @speaking? && "ring-2 ring-primary",
          # bg-base-200 is the spec fallback when no accent color is supplied.
          !@accent_active? && "bg-base-200",
          @class
        ]
      }
      style={@accent_style}
      {@rest}
    >
      <%!-- Avatar centered on the accent background, or — for an agent in
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

      <%!-- Role chip pinned below the avatar inside the tile. --%>
      <div class="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/60 to-transparent px-1.5 pb-0.5 pt-2">
        <div class="flex items-center gap-1 truncate text-[10px] font-medium text-white">
          <span class="hero-cpu-chip block size-3 shrink-0" aria-hidden="true" />
          <span data-role-chip class="truncate">{@role_label}</span>
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

  # ── Activity helpers ───────────────────────────────────────────────────────

  # ── Accent background ──────────────────────────────────────────────────────
  # The accent color is sourced from agent.color (free-form hex) and applied as
  # an inline style so the existing daisyui palette is not bypassed for tiles
  # without a color. We only accept short/long hex to keep the surface narrow.

  defp accent_background_style(nil), do: nil

  defp accent_background_style(color) when is_binary(color) do
    case String.trim(color) do
      "" ->
        nil

      hex ->
        if valid_hex?(hex) do
          "background-color: #{hex};"
        else
          nil
        end
    end
  end

  defp accent_background_style(_), do: nil

  defp valid_hex?(hex) do
    Regex.match?(~r/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/, hex)
  end
end
