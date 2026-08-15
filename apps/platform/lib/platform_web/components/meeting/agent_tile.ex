defmodule PlatformWeb.Components.Meeting.AgentTile do
  @moduledoc """
  A single agent presence tile for a meeting bottom strip.

  Task: 019e2475-0037 — Meetings: bottom video strip (humans + agent presence tiles).
  Spec: docs/decisions/0042-meeting-system-with-collaborative-canvas.md (Layout → Bottom strip).

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
    * `:activity_state` — one of `:idle`, `:typing`, `:computing`, `:listening`.
      Drives whether the activity dot renders. Defaults to `:idle`.
    * `:accent_color` — optional hex color (e.g. `"#7c3aed"`) used as the tile
      background. When `nil`, falls back to `bg-base-200` so the tile remains
      legible against the meeting chrome.
    * `:avatar_url` — optional avatar image URL.
  """

  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  @activity_states [:idle, :typing, :computing, :listening]

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
  attr(:class, :any, default: nil, doc: "extra classes for the outer tile element")
  attr(:rest, :global)

  def agent_tile(assigns) do
    identity = agent_identity(assigns.agent_participant)
    name = agent_name(assigns.agent_participant)
    role_label = normalize_role(assigns.role)
    accent_style = accent_background_style(assigns.accent_color)
    accent_active? = !is_nil(accent_style)

    assigns =
      assigns
      |> assign(:identity, identity)
      |> assign(:name, name)
      |> assign(:role_label, role_label)
      |> assign(:accent_style, accent_style)
      |> assign(:accent_active?, accent_active?)
      |> assign(:active?, assigns.activity_state != :idle)
      |> assign(:activity_label, activity_label(assigns.activity_state))

    ~H"""
    <div
      id={"agent-tile-#{@identity}"}
      data-agent-tile
      data-agent={@identity}
      data-activity-state={Atom.to_string(@activity_state)}
      class={
        [
          "meeting-agent-tile group relative overflow-hidden rounded-lg",
          "aspect-video h-full shrink-0",
          # bg-base-200 is the spec fallback when no accent color is supplied.
          !@accent_active? && "bg-base-200",
          @class
        ]
      }
      style={@accent_style}
      {@rest}
    >
      <%!-- Avatar centered on the accent background. --%>
      <div class="absolute inset-0 flex items-center justify-center">
        <%!-- `agent_avatar/1`, not `human_avatar/1` — a tile is an agent by
             definition, and the human component would draw two initials over
             the seeded human palette under `data-avatar-kind="human"`. --%>
        <.agent_avatar
          name={@name}
          avatar_url={@avatar_url}
          size="lg"
          class="agent-tile-avatar"
        />
      </div>

      <%!-- Activity indicator: pulsing success dot when state != :idle. --%>
      <div
        :if={@active?}
        data-activity-indicator
        class="absolute bottom-1 right-1 size-2.5 rounded-full bg-success ring-2 ring-base-100 animate-pulse"
        title={"#{@name} is #{@activity_label}"}
      >
        <span class="sr-only">{@name} is {@activity_label}</span>
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

  defp activity_label(:typing), do: "typing"
  defp activity_label(:computing), do: "computing"
  defp activity_label(:listening), do: "listening"
  defp activity_label(_), do: "active"

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
