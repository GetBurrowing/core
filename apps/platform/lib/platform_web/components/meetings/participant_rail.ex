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
       `border-edge` divider with a small "Agents" label. One row
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

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.AgentDelayReason
  alias Platform.Meetings.Room
  alias Platform.Meetings.VoiceSeatCache
  alias PlatformWeb.MeetingLive

  attr(:participants, :list, required: true)
  attr(:agents_by_id, :map, required: true)
  attr(:meeting, :any, required: true)

  attr(:agent_activity, :any,
    default: nil,
    doc: "%Platform.Meetings.AgentActivity{} (or a resolved map) for this meeting"
  )

  attr(:now, :any,
    default: nil,
    doc: """
    The clock the row ages are computed against (task 01a06e07 stage 3).
    Threaded in from a `%DateTime{}` assign the caller's own `:tick`
    updates every second (`AgentActivity.tick_interval_ms/0`) — a real,
    top-level LiveView assign that changes, which is what makes LiveView
    re-diff this component on the next tick. Reading `DateTime.utc_now/0`
    INSIDE this function would recompute a fresh age on every call, but
    nothing would tell the diff to re-render it, so ages would freeze at
    whatever the last assign-driven render happened to compute. Defaults to
    `DateTime.utc_now/0` only so a caller that renders this once (a test,
    a static capture) still gets a correct — just not ticking — answer.
    """
  )

  def participant_rail(assigns) do
    {humans, agents} = MeetingLive.partition_participants(assigns.participants)
    now = assigns[:now] || DateTime.utc_now()
    resolved_activity = AgentActivity.resolve_for_render(assigns[:agent_activity], now)

    # The Room lookup `delay_reason/3` needs (reply budget, agent chain) is
    # a DB read. Skipping it whenever nobody in the row set is actually
    # `:computing`/`:typing` keeps that cost bounded by "is anyone working
    # right now", not paid on every idle-room tick — the same bounding
    # instinct `Platform.Meetings.VoiceSeatCache`'s moduledoc argues for.
    working? =
      Enum.any?(resolved_activity, fn {_id, %{state: s}} -> s in [:computing, :typing] end)

    room = if working?, do: room_for(assigns.meeting), else: nil

    assigns =
      assigns
      |> assign(:humans, humans)
      |> assign(:agents, agents)
      |> assign(:resolved_activity, resolved_activity)
      |> assign(:current_room, room)

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
        class="border-t border-edge px-2 pb-2 pt-2"
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
            <% info = agent_row_info(@resolved_activity, p, @agents_by_id, @current_room) %>
            <.agent_activity_avatar
              state={info.state}
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
              <%!-- Task 01a06e07 stage 3: the age and the delay/failure
                   reason live HERE, in the same slot and colour the word
                   already had — no new token, no new node kind. The word
                   + age pairing is kept on one line (`whitespace-nowrap`);
                   the trailing reason is its own span in the same
                   `flex-wrap` row so it drops to a second line rather than
                   being clipped — the node used to carry `truncate`, which
                   is exactly the clip this stage removes. --%>
              <div
                data-role="agent-activity-word"
                class={["flex flex-wrap items-baseline gap-x-1 text-[11px] font-medium", info.text]}
              >
                <span data-role="agent-activity-primary" class="whitespace-nowrap">
                  {info.primary}
                </span>
                <span :if={info.reason} data-role="agent-activity-reason">
                  {"· " <> info.reason}
                </span>
              </div>
            </div>

            <%!-- REACHABILITY, a different fact from the activity above:
                 is this agent connected at all. It is a real signal, so
                 it moves to the row's trailing edge rather than being
                 dropped when the activity ring took over the avatar —
                 matching the trailing dot on the human rows. Deliberately
                 still reads `@agent_activity` (the pre-ceiling struct/map),
                 not `@resolved_activity`: this is a DIFFERENT fact
                 (connected at all, not what it is doing), the same
                 pre-ceiling `for_agent/2` `MeetingLive.agent_status_dot_class/3`
                 always used, and out of this stage's scope. --%>
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

  # ── Task 01a06e07 stage 3: the ceiling-aware render path ────────────────
  #
  # One resolved entry, one composed row — everything the template needs
  # for one agent's word/ring/glyph, computed once instead of the three
  # separate re-derivations the old `activity_meta/2` call sites implied.
  #
  # `resolved_activity` is `AgentActivity.resolve_for_render/2`'s output —
  # already ceiling-capped for a real struct, or a synthetic `age_s: 0`
  # entry for a bare test-fixture map (see that function's doc). Idle/
  # absent agents fall back to the same `age_s: 0` shape so `compose_word/4`
  # never has to special-case a missing entry.
  defp agent_row_info(resolved_activity, participant, agents_by_id, room) do
    agent_id = agent_id_of(participant)
    entry = Map.get(resolved_activity, agent_id, %{state: :idle, entered_at: nil, age_s: 0})
    meta = AgentActivityBadge.activity_meta(entry.state)
    agent = Map.get(agents_by_id, agent_id)

    {primary, reason} = compose_word(entry, meta, agent, room)

    %{state: entry.state, text: meta.text, primary: primary, reason: reason}
  end

  # `:computing` / `:typing` — the word carries the age IN THE SAME SLOT
  # (`Thinking · 3s`), never a separate counter node, per the stage spec's
  # "one working state, one word". The delay clause, when
  # `AgentDelayReason.for_agent/1` has one, is a SEPARATE trailing span so
  # it alone can wrap — see the template.
  defp compose_word(%{state: state, age_s: age_s}, meta, agent, room)
       when state in [:computing, :typing] do
    {"#{meta.word} · #{age_s}s", delay_reason(agent, room, age_s)}
  end

  # `:failed` — the word carries NO counter (the stage spec: "Couldn't
  # carries its reason, not a counter"); the reason is the same trailing
  # span every other state's delay clause uses.
  defp compose_word(%{state: :failed} = entry, meta, agent, _room) do
    {meta.word, failed_reason(agent, entry)}
  end

  # `:idle`, `:heard`, and the unreachable `:listening` fallback: the bare
  # word, no counter, no reason — matches the stage spec's "Heard and Idle
  # carry NO counter" and `AgentActivityBadge`'s own refusal to draw
  # `:listening` as anything but idle.
  defp compose_word(_entry, meta, _agent, _room), do: {meta.word, nil}

  # Why is a still-working agent taking a while, IF there is an honest
  # thing to say (see `AgentDelayReason` — a specific cause shows
  # immediately, the generic "still running a tool" only past its own
  # age threshold, and `nil` when neither applies).
  #
  # A participant with no resolved `Agent{}` (guest surfaces pass
  # `agents_by_id: %{}`; a bare test fixture has none) can only offer the
  # `age_s` fact — every other fact needs the agent row `Meetings`/
  # `VoiceSeatCache` read against, and reporting a specific cause we did
  # not actually check would be a worse lie than reporting none.
  defp delay_reason(nil, _room, age_s), do: AgentDelayReason.for_agent(%{age_s: age_s})

  defp delay_reason(%Agent{} = agent, room, age_s) do
    facts =
      %{
        age_s: age_s,
        runtime_offline?: Meetings.runtime_offline?(agent),
        no_voice_worker?: not VoiceSeatCache.seated?(agent)
      }
      |> Map.merge(room_facts(room, agent))

    AgentDelayReason.for_agent(facts)
  end

  # Reply-budget and agent-chain facts need the LIVE CALL's `Room` (a
  # different schema from the `Meeting` this component is handed — see
  # `Platform.Meetings.reply_budget_exhausted?/2`'s @doc). `nil` room
  # (no active call row, or nobody working this render — see
  # `participant_rail/1`'s `working?` gate) means those two facts are
  # simply not offered, not that they are false.
  defp room_facts(%Room{} = room, %Agent{} = agent) do
    %{
      reply_budget_exhausted?: Meetings.reply_budget_exhausted?(room, agent),
      reply_budget_reset_in_s: Meetings.reply_budget_reset_in_s(room, agent),
      agent_chain_too_deep?: Meetings.agent_chain_too_deep?(room)
    }
  end

  defp room_facts(_room, _agent), do: %{}

  defp room_for(%{chat_space_id: space_id}) when is_binary(space_id),
    do: Meetings.get_active_room(space_id)

  defp room_for(_meeting), do: nil

  # Why an agent past the ceiling `Couldn't` — one real, checkable cause
  # (`Meetings.runtime_offline?/1`, the same fact `AgentDelayReason` offers
  # for a still-working agent) ahead of the honest default: how long
  # nothing has answered, from the SAME `age_s` the ceiling itself capped
  # on. No `Agent{}` to check (guest surfaces, bare test fixtures) falls
  # straight to the duration — see `delay_reason/3`'s identical reasoning.
  defp failed_reason(nil, %{age_s: age_s}), do: "no response for " <> format_duration(age_s)

  defp failed_reason(%Agent{} = agent, %{age_s: age_s}) do
    if Meetings.runtime_offline?(agent) do
      "agent went offline"
    else
      "no response for " <> format_duration(age_s)
    end
  end

  # Only the ceiling's own reads ever pass an `age_s` big enough to need
  # minutes (a `:computing`/`:typing` counter is always < 120 by
  # construction — past that it has already become `:failed`), so seconds
  # only shows below a minute and minutes above it; nothing here has ever
  # needed to mix the two.
  defp format_duration(age_s) when is_integer(age_s) and age_s < 60, do: "#{age_s}s"
  defp format_duration(age_s) when is_integer(age_s), do: "#{div(age_s, 60)}m"
  defp format_duration(_age_s), do: "0s"
end
