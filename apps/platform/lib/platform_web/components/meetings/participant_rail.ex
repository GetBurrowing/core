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
         * host badge (`hero-shield-check`) when
           `participant.id == meeting.host_participant_id`

    2. **Agents** (bottom) — separated from section 1 by a
       `border-base-300` divider with a small "Agents" label. One row
       per `participant_type == "agent"` carrying:
         * avatar
         * display name
         * the state word ("Thinking" / "Writing" / "Couldn't" /
           "Idle") as small text below the name, matching the ring
           and corner glyph on the avatar
         * status dot keyed off THIS MEETING's agent activity, with the
           global `agents.status` column only as an offline fallback
           (task 01a04a98)

  The human rows used to carry a server-side speaking ring driven by a
  speaking-ids assign that NOTHING ever wrote — it was `MapSet.new()`
  at both of its assignment sites and no handler ever added an id.
  Task 01a04a98 deleted the assign, this component's attr, and the
  ring, rather than leave a declared-but-never-written signal
  rendering. Active-speaker highlight for HUMAN video tiles remains a
  client-side LiveKit concern (`meeting_client.js`), which is the
  decided carve-out.

  Hero icons only. Tap targets `min-h-11` to keep mobile usable from
  the drawer (stage 4 ships the toggle behavior).

  ## The type scale is pinned, not inherited (task 01a05b14 stage 5)

  Every row carries its own size utility — `text-xs` on the row and
  the name, `text-[11px]` on the sub-line and the section heading —
  with NO breakpoint variant on any of them. The rows used to say
  `text-sm` and let the name inherit it, which is the shell's body
  scale and roughly twice the approved target's 12px name. The target
  draws the rail at 12px name / 10-11px sub-line / uppercase 10-11px
  heading at EVERY width: the sub-`lg` drawer is the same rail
  narrowed, not a different screen, so the size must not depend on
  the viewport. `call_shell_test.exs` refutes a `sm:`/`lg:` prefix on
  any of these utilities, and the stage-5 capture measured
  `getComputedStyle(name).fontSize` equal at 1280 and 390.
  """
  use Phoenix.Component

  import PlatformWeb.Components.Meetings.AgentActivityBadge

  alias PlatformWeb.Components.Meetings.AgentActivityBadge

  import PlatformWeb.AvatarComponents

  alias Platform.Meetings.AgentActivity
  alias PlatformWeb.MeetingLive

  attr(:participants, :list, required: true)
  attr(:agents_by_id, :map, required: true)
  attr(:meeting, :any, required: true)

  attr(:agent_activity, :any,
    default: nil,
    doc: "%Platform.Meetings.AgentActivity{} (or a resolved map) for this meeting"
  )

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
        <%!-- The Agents section below has carried a heading since it
             shipped; this one did not, so the People pane opened on an
             unlabelled list of faces. Same glyph-plus-uppercase pair,
             `hero-users` rather than `hero-cpu-chip` because these are
             people. Rendered unconditionally — the section itself is
             unconditional (it has an empty state), so a heading that
             hid with the list would leave "No people yet." floating
             under nothing. --%>
        <div class="flex items-center gap-1.5 px-2 pb-1.5" data-role="humans-heading">
          <span class="hero-users size-3.5 text-base-content/50"></span>
          <span class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
            In this call
          </span>
        </div>

        <ul class="flex flex-col gap-0.5" role="list">
          <li
            :for={p <- @humans}
            data-participant-id={p.id}
            data-participant-type="user"
            data-host={to_string(MeetingLive.host?(p, @meeting))}
            class="group flex items-center gap-2 rounded-lg px-2 py-1.5 text-xs min-h-11 transition-colors hover:bg-base-300/40"
          >
            <.human_avatar
              name={p.display_name || "Unknown participant"}
              avatar_url={p.avatar_url}
              seed={p.participant_id || p.id}
              size="sm"
              class="flex-shrink-0"
            />
            <div class="min-w-0 flex-1">
              <div
                class="truncate text-xs font-medium text-base-content/90"
                data-role="participant-name"
              >
                {p.display_name || "Unknown participant"}
              </div>
              <%!-- Stage 4 of task 019f2483: participants joined via a
                   guest invite carry a `" (guest)"` suffix on their
                   display_name (see `Platform.Meetings.guest_livekit_token/2`
                   → `meetings.ex:1269`). Surface that as a small
                   sub-line so hosts can visually distinguish invited
                   guests from account-holding humans without reading
                   the suffix. --%>
              <div
                :if={MeetingLive.via_guest_link?(p)}
                class="truncate text-[11px] text-base-content/50"
                data-role="participant-via-guest-link"
              >
                via guest link
              </div>
            </div>

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
            class="group flex items-center gap-2 rounded-lg px-2 py-1.5 text-xs min-h-11 hover:bg-base-300/40 transition-colors"
          >
            <%!-- ONE construction for all four states.

                 Was: a bare `agent_avatar`, a role chip on line 2
                 rendering the literal string "agent", and a badge
                 gated on `!= :idle` with a substitute status dot on
                 the other branch. Three of Saru's four visual cues
                 were absent exactly when a viewer most needs to read
                 the row, and a state was representable by whichever
                 of two mutually-exclusive branches happened to fire.
                 The state now lives ON the face — ring around it,
                 glyph in its corner — with the WORD directly under
                 the name, and `:idle` is drawn like any other state.

                 `agent_avatar/1`, not `human_avatar/1`: this section
                 is agents by construction, and the human component
                 would give them two initials over the seeded human
                 palette and stamp them `data-avatar-kind="human"`.
                 `agent_activity_avatar/1` renders it internally. --%>
            <.agent_activity_avatar
              state={AgentActivity.for_agent(@agent_activity, agent_id_of(p))}
              name={p.display_name || "Agent"}
              avatar_url={p.avatar_url}
            />
            <div class="min-w-0 flex-1">
              <div
                class="truncate text-xs font-medium text-base-content/90"
                data-role="participant-name"
              >
                {p.display_name || "Agent"}
              </div>
              <div
                data-role="agent-activity-word"
                class={[
                  "truncate text-[11px] font-medium",
                  activity_meta(@agent_activity, p).text
                ]}
              >
                {activity_meta(@agent_activity, p).word}
              </div>
            </div>

            <%!-- REACHABILITY, a different fact from the activity above:
                 is this agent connected at all. It is a real signal, so
                 it moves to the row's trailing edge rather than being
                 dropped when the activity ring took over the avatar —
                 matching the trailing dot on the human rows. --%>
            <span
              class={[
                "size-[7px] flex-shrink-0 rounded-full",
                MeetingLive.agent_status_dot_class(p, @agents_by_id, @agent_activity)
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

  # The agent id an activity signal is addressed to.
  #
  # `AgentActivity` keys on `agents.id`, which for an agent participant
  # row is `participant_id` — the same field
  # `MeetingLive.agent_status_dot_class/3` matches on. Anything that is
  # not an agent participant returns nil and resolves `:idle`, so a
  # human row can never pick up an agent's badge by coincidence.
  defp agent_id_of(%{participant_type: "agent", participant_id: agent_id})
       when is_binary(agent_id),
       do: agent_id

  defp agent_id_of(_participant), do: nil

  # The state word and its colour come from `AgentActivityBadge`'s own
  # table — the same one that decides the ring and the glyph — so the
  # word under the name cannot drift from the ring around the face.
  # Rendering the badge component here just to scrape the word would
  # put a second ring in the row, so the table is read directly.
  defp activity_meta(agent_activity, participant) do
    agent_activity
    |> AgentActivity.for_agent(agent_id_of(participant))
    |> AgentActivityBadge.activity_meta()
  end
end
