defmodule PlatformWeb.Components.Meetings.ParticipantRail do
  @moduledoc """
  Sectioned participant rail for `PlatformWeb.MeetingLive` (ADR 0042,
  task 019e2475-4395 stage 1).

  Renders TWO sections:

    1. **Hosts/humans** (top) — one row per `participant_type == "user"`
       carrying:
         * avatar (`human_avatar` component, sm)
         * display name
         * mic indicator (`hero-microphone` /
           `hero-microphone-slash`)
         * speaking ring + `bg-primary/10` when the participant id is
           in `:speaking_participant_ids`
         * host badge (`hero-shield-check`) when
           `participant.id == meeting.host_participant_id`

    2. **Agents** (bottom) — separated from section 1 by a
       `border-base-300` divider with a small "Agents" label. One row
       per `participant_type == "agent"` carrying:
         * avatar
         * display name
         * role chip (`agent.metadata["role"]`, fallback `"agent"`) as
           small text below the name
         * status dot keyed off the agent's `status` field

  Hero icons only. Tap targets `min-h-11` to keep mobile usable from
  the drawer (stage 4 ships the toggle behavior).
  """
  use Phoenix.Component

  import PlatformWeb.AvatarComponents

  alias PlatformWeb.MeetingLive

  attr(:participants, :list, required: true)
  attr(:agents_by_id, :map, required: true)
  attr(:meeting, :any, required: true)
  attr(:speaking_participant_ids, :any, required: true)

  def participant_rail(assigns) do
    {humans, agents} = MeetingLive.partition_participants(assigns.participants)

    assigns =
      assigns
      |> assign(:humans, humans)
      |> assign(:agents, agents)

    ~H"""
    <div data-component="participant-rail" class="flex flex-col">
      <%!-- ── Section 1: Hosts / humans ─────────────────────────────────── --%>
      <section data-section="humans" class="px-2 py-2">
        <ul class="flex flex-col gap-0.5" role="list">
          <li
            :for={p <- @humans}
            data-participant-id={p.id}
            data-participant-type="user"
            data-host={to_string(MeetingLive.host?(p, @meeting))}
            data-speaking={to_string(MeetingLive.speaking?(p, @speaking_participant_ids))}
            class={[
              "group flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm min-h-11 transition-colors",
              if(MeetingLive.speaking?(p, @speaking_participant_ids),
                do: "bg-primary/10 ring-1 ring-primary/40",
                else: "hover:bg-base-300/40"
              )
            ]}
          >
            <.human_avatar
              name={p.display_name || "Unknown participant"}
              avatar_url={p.avatar_url}
              seed={p.participant_id || p.id}
              size="sm"
              class="flex-shrink-0"
            />
            <span
              class="min-w-0 flex-1 truncate font-medium text-base-content/90"
              data-role="participant-name"
            >
              {p.display_name || "Unknown participant"}
            </span>

            <%!-- Host badge --%>
            <span
              :if={MeetingLive.host?(p, @meeting)}
              class="hero-shield-check size-4 flex-shrink-0 text-primary"
              aria-label="Host"
              title="Host"
              data-role="host-badge"
            >
            </span>

            <%!-- Mic indicator --%>
            <span
              class={[
                "size-4 flex-shrink-0",
                if(MeetingLive.mic_on?(p),
                  do: "hero-microphone text-success",
                  else: "hero-microphone-slash text-base-content/40"
                )
              ]}
              aria-label={if MeetingLive.mic_on?(p), do: "Microphone on", else: "Microphone off"}
              title={if MeetingLive.mic_on?(p), do: "Mic on", else: "Mic off"}
              data-role="mic-indicator"
              data-mic-on={to_string(MeetingLive.mic_on?(p))}
            >
            </span>
          </li>

          <li
            :if={@humans == []}
            class="px-2 py-1.5 text-xs text-base-content/40"
          >
            No people yet.
          </li>
        </ul>
      </section>

      <%!-- ── Section 2: Agents ─────────────────────────────────────────── --%>
      <section
        :if={@agents != []}
        data-section="agents"
        class="border-t border-base-300 px-2 pb-2 pt-2"
      >
        <div class="flex items-center gap-1.5 px-2 pb-1.5">
          <span class="hero-cpu-chip size-3.5 text-base-content/50"></span>
          <span class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
            Agents
          </span>
        </div>

        <ul class="flex flex-col gap-0.5" role="list">
          <li
            :for={p <- @agents}
            data-participant-id={p.id}
            data-participant-type="agent"
            class="group flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm min-h-11 hover:bg-base-300/40 transition-colors"
          >
            <.human_avatar
              name={p.display_name || "Agent"}
              avatar_url={p.avatar_url}
              seed={p.participant_id || p.id}
              size="sm"
              class="flex-shrink-0"
            />
            <div class="min-w-0 flex-1">
              <div class="truncate font-medium text-base-content/90">
                {p.display_name || "Agent"}
              </div>
              <div class="truncate text-[11px] text-base-content/50" data-role="agent-role-chip">
                {MeetingLive.agent_role_chip(p, @agents_by_id)}
              </div>
            </div>

            <%!-- Status dot --%>
            <span
              class={[
                "size-2 flex-shrink-0 rounded-full",
                MeetingLive.agent_status_dot_class(p, @agents_by_id)
              ]}
              aria-hidden="true"
              data-role="agent-status-dot"
            >
            </span>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
