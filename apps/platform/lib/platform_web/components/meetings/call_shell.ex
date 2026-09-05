defmodule PlatformWeb.Components.Meetings.CallShell do
  @moduledoc """
  The call shell shared by BOTH meeting surfaces — `/meetings`
  (`PlatformWeb.MeetingLive`) and the in-chat quickmeet panel
  (`PlatformWeb.Live.Chat.Partials.meeting_panel/1`).

  Exports two pieces:

    * `call_rail/1` — the 312px right rail: a three-up tab strip
      (People / Canvas / Transcript) over a scrolling pane.
    * `call_controls/1` — Mute / Camera / Share / Leave.

  ## Why ONE implementation and not one per surface

  The rail's content is already three existing components that take
  plain attrs — `ParticipantRail`, `CandidateRail` and (on
  `/meetings`) the intents bar. None of them reach into
  `MeetingLive`'s socket. The only genuine divergence between the two
  surfaces is the LiveKit video grid (different DOM ids, different
  `data-local-video-dock` reparent contracts) and the control EVENT
  NAMES. The grid stays per-surface; the rail and the controls are
  shared, and the event names are parameters.

  ## Function components, NOT LiveComponents. Load-bearing.

  `pushEvent` from a JS hook IGNORES `phx-target`. Extracting this
  markup into a `LiveComponent` would silently kill every hook-pushed
  event while the mouse paths kept working, and `mix test` cannot see
  it. Live pushes that travel through markup in this neighbourhood:

    * `meeting_share_button.js` → `meeting_toggle_screen_share`,
      `meeting_screen_share_state`
    * `meeting_client.js` → `meeting_left`
    * `meeting_captions.js` → `meeting_captions_hydrate`

  Function components render into the parent LiveView's own target, so
  all three keep working. **Do not convert any of this to a
  LiveComponent, here or later.**

  ## Control event names diverge, so they are attrs

  `MeetingLive` owns `toggle_captions_meeting`,
  `meeting_start_screen_share`, `meeting_screen_share_state` and
  `toggle_participant_rail`. `Platform.Chat.MeetingHooks` owns the
  quickmeet's `meeting_toggle_mic` / `meeting_toggle_camera` /
  `meeting_leave`. `call_controls/1` therefore takes `mic_event`,
  `camera_event`, `share_event` and `leave_event` as REQUIRED string
  attrs rather than hardcoding either vocabulary — a component that
  hardcoded one surface's names would be a component only one surface
  could use.

  ## Tab state belongs to the caller

  `active_tab` and `tab_event` are attrs, so each surface owns its own
  assign and its own handler. There is no state in here.

  ## `Listening` is off the rail — decided, not deferred

  This rail does NOT render a `Listening` row, and as of Saru's ruling
  on the target canvas (01a05b11-54ff card 6, 2026-09-02) it never
  will: every agent in a call is always listening, so a badge that is
  on for everyone all the time takes a row from a state that actually
  turns over. The original reason — `AgentActivity` declares
  `:listening` and nothing in the system can set it — still holds and
  `AgentActivityBadge.meta/1` still falls it through to idle, but the
  row is removed from the target rather than waiting on a producer.
  Only `Thinking`, `Writing`, `Couldn't` and idle are drawn.

  ## Design tokens (Saru, design-direction canvas)

  Semantic slots only — no raw hex anywhere in here, because the
  approved embed's inline CSS is hardcoded dark-mode and the rail
  follows the theme:

    * `primary` — active-tab underline
    * `success` — speaking / live cues
    * `warning` — invite honesty banner
    * `error` — `Couldn't`, and Leave
    * `info` — `Thinking` AND `Writing` (Saru, 2026-09-02: both mean
      "working, nothing is asked of you"; motion tells them apart)
    * `neutral` / `base-300` — idle rows and dashed controls

  Radii come from `--radius-box` / `--radius-field` via `rounded-box`
  and `rounded-field`; section labels are 10px / `0.09em` uppercase.
  """

  use Phoenix.Component

  import PlatformWeb.Components.Meetings.CandidateRail
  import PlatformWeb.Components.Meetings.ParticipantRail
  import PlatformWeb.Components.Meetings.TranscriptPane

  @tabs [
    {"people", "People"},
    {"canvas", "Canvas"},
    {"transcript", "Transcript"}
  ]

  @doc """
  The tab identifiers this rail knows about, in render order.

  Exposed so a caller can validate an incoming tab param against the
  same list the strip renders from rather than repeating the strings.
  """
  def tabs, do: @tabs

  attr(:id, :string, default: "call-rail")
  attr(:class, :string, default: nil)

  attr(:width_class, :string,
    default: "w-[312px]",
    doc: """
    The rail's width utility, as an ATTR rather than a baked-in
    `w-[312px]` (task 01a05b14 stage 6).

    312px is the DESKTOP figure from the approved target. It is not a
    property of the rail: the in-chat quickmeet mounts this inside a
    384px panel and a `<lg` viewport mounts it as a full-bleed drawer,
    and in both of those a fixed 312px column is wrong. Passing the
    width through `class` instead does NOT work — two width utilities
    on one element resolve by CSS SOURCE order, not by attribute order,
    so `class="w-full"` loses to the baked-in arbitrary value
    non-deterministically. Stage 5 measured this rail at `width: 0` on
    a 390px viewport; this attr is half of why that is fixed.
    """
  )

  attr(:active_tab, :string,
    default: "people",
    doc: ~s(one of "people" | "canvas" | "transcript"; anything else falls back to people)
  )

  attr(:tab_event, :string,
    required: true,
    doc: "event pushed on tab click, with `phx-value-tab` carrying the tab id"
  )

  # ── People pane ──────────────────────────────────────────────────
  attr(:participants, :list, default: [])
  attr(:agents_by_id, :map, default: %{})
  attr(:meeting, :any, default: nil)
  attr(:agent_activity, :any, default: nil)

  attr(:now, :any,
    default: nil,
    doc: """
    Forwarded verbatim to `ParticipantRail.participant_rail/1` (task
    01a06e07 stage 3) — see that attr's doc. Both callers of `call_rail/1`
    (`/meetings` and the quickmeet panel) own their own 1-second
    `:agent_activity_tick` and should pass the `DateTime` assign it
    maintains — that changing top-level assign is what makes LiveView
    re-diff the rail on the next tick. A caller that omits it still
    renders a correct rail (`participant_rail/1` falls back to
    `DateTime.utc_now/0`); it just will not tick between unrelated
    re-renders.
    """
  )

  attr(:invite_rows, :list,
    default: [],
    doc: """
    `PlatformWeb.MeetingLive.invite_rows/2` output — one
    `%{agent, state, capability}` per agent of the meeting's space,
    invitable first. The section renders whenever `invite_event` is set,
    rows or none (task 01a0691d).
    """
  )

  attr(:invite_event, :string,
    default: nil,
    doc: """
    event pushed when an agent is invited, with `phx-value-agent-id`. nil
    means the viewer may not invite, and the invite section is absent
    """
  )

  # ── Canvas pane ──────────────────────────────────────────────────
  attr(:candidates, :list, default: [])
  attr(:candidates_closed, :list, default: [])
  attr(:candidate_events, :map, default: %{})
  attr(:candidate_error, :string, default: nil)

  # ── Transcript pane ──────────────────────────────────────────────
  attr(:captions_available, :boolean,
    default: true,
    doc: """
    Whether captions can reach this surface at all. False when the media
    plane that emits `TranscriptionReceived` is not configured, in which
    case the pane says so outright instead of showing a "nothing yet" line
    that implies a transcriber is listening.
    """
  )

  slot(:transcript,
    doc: "stage 5 fills this; the pane renders an empty-state line when the slot is absent"
  )

  slot(:people_extra, doc: "surface-specific rows appended below the People pane")

  slot(:canvas_extra,
    doc: """
    Surface-specific rows appended below `CandidateRail` in the Canvas
    pane. `/meetings` passes its `IntentsCollapse` bar here rather than
    the component being re-rendered in a second place: the producer
    watches the intent queue and the candidate cards in the same pane.
    """
  )

  def call_rail(assigns) do
    assigns = assign(assigns, :active, normalize_tab(assigns.active_tab))

    ~H"""
    <aside
      id={@id}
      class={[
        "flex flex-shrink-0 flex-col border-l border-base-300 bg-base-200/40",
        @width_class,
        @class
      ]}
      data-component="call-rail"
      data-active-tab={@active}
    >
      <div class="flex border-b border-base-300" role="tablist" data-role="call-rail-tabs">
        <button
          :for={{id, label} <- tabs()}
          type="button"
          role="tab"
          phx-click={@tab_event}
          phx-value-tab={id}
          aria-selected={to_string(id == @active)}
          data-role="call-rail-tab"
          data-tab={id}
          data-active={to_string(id == @active)}
          class={[
            "relative flex-1 px-2 py-2.5 text-[11px] font-medium transition-colors",
            if(id == @active,
              do: "text-base-content",
              else: "text-base-content/55 hover:text-base-content/80"
            )
          ]}
        >
          {label}
          <%!-- The active marker is an inset bottom bar on `primary`,
               per the approved target and Saru's slot list. A real
               element rather than a border so the inactive tabs do not
               reserve a border box and shift the label by a pixel. --%>
          <span
            :if={id == @active}
            class="absolute inset-x-0 bottom-0 h-0.5 bg-primary"
            aria-hidden="true"
            data-role="call-rail-tab-marker"
          >
          </span>
        </button>
      </div>

      <div
        class="min-h-0 flex-1 overflow-y-auto"
        role="tabpanel"
        data-role="call-rail-pane"
        data-pane-tab={@active}
      >
        <%= case @active do %>
          <% "people" -> %>
            <.participant_rail
              participants={@participants}
              agents_by_id={@agents_by_id}
              meeting={@meeting}
              agent_activity={@agent_activity}
              now={@now}
            />
            {render_slot(@people_extra)}
            <.invite_section
              :if={@invite_event}
              id={@id}
              invite_rows={@invite_rows}
              invite_event={@invite_event}
            />
          <% "canvas" -> %>
            <.candidate_rail
              candidates={@candidates}
              closed={@candidates_closed}
              events={@candidate_events}
              error={@candidate_error}
            />
            <%!-- Honest empty state (task 01a05b14 stage 5). `candidate_rail`
                 renders NOTHING when it has no open card, no closed card
                 and no error, which on a quickmeet with no canvas_extra
                 left a blank tabpanel that read as "loading". The two
                 wordings name the actual condition: a call with no
                 `meetings` row can never form a card (candidates are
                 keyed by meeting), whereas a live meeting simply has none
                 yet. Neither says or implies that anything is being
                 captured. --%>
            <p
              :if={@candidates == [] and @candidates_closed == [] and is_nil(@candidate_error)}
              class="text-base-content/40 p-3 text-xs"
              data-role="call-rail-canvas-empty"
            >
              <%= if @meeting do %>
                No cards in this call yet. A card appears here when an agent forms one from
                what is said.
              <% else %>
                This call has no meeting record, so no cards can form from it.
              <% end %>
            </p>
            {render_slot(@canvas_extra)}
          <% "transcript" -> %>
            <%!-- Only the OVERRIDE renders inside the case. The JS-owned
                 pane is mounted unconditionally below the case, because a
                 branch that unmounts it on People/Canvas destroys the hook
                 and with it every line received so far (task 01a06524). --%>
            <div :if={@transcript != []} class="p-3" data-role="call-rail-transcript">
              {render_slot(@transcript)}
            </div>
        <% end %>

        <%!-- The transcript pane, mounted ONCE and never unmounted while
             the rail lives (task 01a06524 stage 1).

             WHY OUTSIDE THE `case`. `meeting:caption` is a client-side DOM
             CustomEvent; the lines exist only in the DOM the
             `MeetingTranscript` hook writes. If this host were rendered
             inside the "transcript" branch, switching to People would
             remove the element, LiveView would call `destroyed()` on the
             hook, and switching back would mount a fresh, empty pane —
             thirty seconds of scrollback gone because the reader glanced
             at the roster. So the host persists and this OUTER div, which
             LiveView owns and re-renders freely, carries `hidden` whenever
             the tab is not Transcript. The flip cannot live on the host
             itself: under `phx-update="ignore"` non-`data-*` attributes
             are PRESERVED across renders, so a class change there would
             never reach the DOM.

             VIEWER-LOCAL STATE, DELIBERATELY NOTHING NEW. The pane renders
             whenever the Transcript tab is selected and there is no second
             show/hide toggle: choosing the tab IS the opt-in (Saru's canvas
             01a068fc, "Three calls"). A separate switch inside a tab that
             exists to show one thing would be a control with nothing to do.
             The tab is `:active_meeting_tab`, already per-socket on both
             surfaces (`meeting_live.ex` and `chat/meeting_hooks.ex`), never
             broadcast, never persisted — the same viewer-local shape as
             `:captions_visible`, which remains the OVERLAY's toggle and is
             a different job (a glance over the video versus reading).

             The explicit `:transcript` slot (an archived transcript) wins:
             when it is given the JS pane is not mounted at all, since
             nothing would ever write into it. --%>
        <div
          :if={@transcript == []}
          data-role="meeting-transcript-wrap"
          data-active={to_string(@active == "transcript")}
          hidden={@active != "transcript"}
          class="flex h-full min-h-0 flex-col"
        >
          <.transcript_pane id={"#{@id}-transcript"} captions_available={@captions_available} />
        </div>
      </div>
    </aside>
    """
  end

  @doc """
  The People tab's "Invite an agent" section (task 01a0691d stage 2).

  Rendered UNCONDITIONALLY whenever the rail was given an `invite_event`:
  the list being empty is the state this section exists to explain, not a
  reason to remove it. The block used to vanish when no agent was
  invitable, which on the founder's screen read as "this feature does not
  exist" — the rail showed PARTICIPANTS (2) and nothing else.

  Every roster agent is a row, and every row explains itself. The rows
  come server-built from `PlatformWeb.MeetingLive.invite_rows/2`, invitable
  first, and this component decides nothing about capability: it only
  draws the state it is handed. Per state (design canvas
  01a064fc-5c89-7001-9ea1-491f076b6746, "Where this lives now"):

    * `:invitable`, capability `:capable` — "Voice runtime online", Invite.
    * `:invitable`, capability `:unknown` — NO second line, Invite. A hedge
      on a row that usually works teaches people to ignore hedges
      (01a0554f's ruling, kept).
    * `:pending` — "Invite sent, no answer yet", and the button reads
      Waiting in `info`. Still clickable: an undelivered invite has to be
      recoverable from the row that made it.
    * `:incapable` — "No voice runtime online", no control.
    * `:in_call` — "Already in the call", no control; the agent is listed
      above under In this call too.

  Since task 01a05553 the rows are the whole ACTIVE AGENT ROSTER, not the
  meeting's chat space, because a meeting's space starts empty and so the
  list did too. A row for an agent that is not in that space carries
  `in_space?: false` and is marked "not in space" beside the name — as
  INFORMATION, in the muted token, next to a button that still works.
  Membership is not a permission here and must not be drawn as one; the
  founder read the previous screen's disabled rows as a permissions rule and
  went looking for a setting that does not exist. Capability keeps the
  second line; membership is a marker on the first, so a row can say both
  without either being mistaken for the other.

  Blocked rows are plain `<li>`s: no `<button>`, no `phx-click`, no hover
  fill (`base-300` is a raised surface, not a hover colour). Muted, never
  `warning`: warning on this rail means something is asking a human for a
  response, which an agent that cannot join is not. `info` appears on
  Waiting and nowhere else. The words "listening" and "hidden" do not
  appear here; the approved target canvas drew a third group titled
  "No voice — hidden", and this section is the reversal of that.

  The heading is the rail's own 11px section style, not `text-xs`: the
  approved type scale (01a05b14 stage 5) pins every rail heading to
  `text-[11px]` unconditionally.
  """
  attr(:id, :string, required: true)
  attr(:invite_rows, :list, default: [])
  attr(:invite_event, :string, required: true)

  def invite_section(assigns) do
    ~H"""
    <section
      id={"#{@id}-agent-invite"}
      class="px-3 pb-3 pt-2 text-xs"
      data-role="meeting-agent-invite"
    >
      <div class="px-1 pb-1.5">
        <span class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
          Invite an agent
        </span>
      </div>

      <ul class="flex flex-col" role="list">
        <li
          :for={row <- @invite_rows}
          class="flex items-center gap-2 px-1 py-1.5"
          data-role="meeting-agent-invite-row"
          data-invite-state={row.state}
          data-agent-id={row.agent.id}
        >
          <span class="min-w-0 flex-1">
            <span class="flex min-w-0 items-baseline gap-1.5">
              <span
                class={[
                  "min-w-0 truncate text-[13px] leading-tight",
                  if(row.state in [:incapable, :in_call],
                    do: "text-base-content/50",
                    else: "text-base-content"
                  )
                ]}
                data-role="meeting-agent-invite-name"
              >
                {row.agent.name || row.agent.slug}
              </span>
              <span
                :if={not in_space?(row)}
                class="shrink-0 text-[10px] uppercase tracking-wide text-base-content/40"
                data-role="meeting-agent-invite-membership"
              >
                not in space
              </span>
            </span>
            <span
              :if={invite_reason(row)}
              class="block truncate text-[11px] text-base-content/50"
              data-role="meeting-agent-invite-reason"
            >
              {invite_reason(row)}
            </span>
          </span>

          <button
            :if={row.state in [:invitable, :pending]}
            type="button"
            phx-click={@invite_event}
            phx-value-agent-id={row.agent.id}
            data-role="meeting-agent-invite-button"
            data-agent-id={row.agent.id}
            data-invite-pending={row.state == :pending && "true"}
            aria-label={invite_label(row)}
            class="btn btn-ghost btn-xs shrink-0 font-normal text-base-content/70 hover:text-base-content"
          >
            <span
              :if={row.state == :pending}
              class="text-info"
              data-role="meeting-agent-invite-pending"
            >
              Waiting
            </span>
            <span :if={row.state != :pending}>Invite</span>
          </button>
        </li>

        <li
          :if={@invite_rows == []}
          class="rounded-box border border-dashed border-base-300 px-3 py-2.5 text-[11px] leading-relaxed text-base-content/50"
          data-role="meeting-agent-invite-empty"
        >
          No active agents yet. Every active agent appears here, whether or not it is already in
          this space.
        </li>
      </ul>
    </section>
    """
  end

  # Membership of the meeting's chat space (task 01a05553). Absent key reads
  # as "a member", i.e. draws NO marker: the flag arrived after this component
  # did, and a caller still passing the old three-key row should render the
  # row it always rendered rather than sprout a label about a space it never
  # said anything about.
  defp in_space?(row), do: Map.get(row, :in_space?, true)

  # The second line per state — the canvas's "exact line each shows". nil
  # is a real answer: an `:invitable` row of `:unknown` capability draws no
  # reason element at all.
  defp invite_reason(%{state: :invitable, capability: :capable}), do: "Voice runtime online"
  defp invite_reason(%{state: :invitable}), do: nil
  defp invite_reason(%{state: :pending}), do: "Invite sent, no answer yet"
  defp invite_reason(%{state: :incapable}), do: "No voice runtime online"
  defp invite_reason(%{state: :in_call}), do: "Already in the call"

  defp invite_label(%{state: :pending, agent: agent}),
    do:
      "Invite #{agent.name || agent.slug} to the meeting again — the first invite has not been answered"

  defp invite_label(%{agent: agent}), do: "Invite #{agent.name || agent.slug} to the meeting"

  @doc """
  Mute / Camera / Share / Leave.

  NARROW SURFACES DROP THE LABEL TEXT, NEVER A CONTROL (task 01a05b14
  stage 2). Each label is a `.call-control-label` span and app.css
  hides it inside a container narrower than 390px. That is a CONTAINER
  query, not a media query and not an attr: the trigger is how wide
  the BAR is, and the same 1280px viewport gives this component a
  712px bar on `/meetings` and a 319px one inside the quickmeet's
  `w-80` panel. A viewport breakpoint cannot tell those apart, and the
  shipped 1280 capture that showed Leave clipped by the panel edge is
  what that confusion looks like. `aria-label` is on every button and
  is untouched, so the accessible name and every `data-role` selector
  survive the degradation.

  Every event name is a REQUIRED attr. The two surfaces genuinely
  disagree on the vocabulary (see the moduledoc), and a component that
  picked one of them would be a component only one surface could use.
  """
  attr(:class, :string, default: nil)
  attr(:mic_event, :string, required: true)
  attr(:camera_event, :string, required: true)
  attr(:share_event, :string, required: true)
  attr(:leave_event, :string, required: true)
  attr(:mic_on, :boolean, default: true)
  attr(:camera_on, :boolean, default: true)
  attr(:sharing, :boolean, default: false)

  # ── Per-button identity overrides ────────────────────────────────
  #
  # The `data-role` values and the Share button's id/hook are a
  # CONTRACT, not decoration. `/meetings` already ships
  # `data-role="meeting-mic"` / `"meeting-camera"` /
  # `"meeting-screen-share"` / `"meeting-leave"` and a Share button
  # carrying `phx-hook="MeetingShareButton"`; that hook calls
  # `getDisplayMedia()` inside the click gesture and pushes
  # `meeting_screen_share_state` back to the PARENT LiveView. Hardcoding
  # this component's own role names would have silently dropped the hook
  # and every selector built on those roles, so both are attrs.
  attr(:mic_role, :string, default: "call-control-mic")
  attr(:camera_role, :string, default: "call-control-camera")
  attr(:share_role, :string, default: "call-control-share")
  attr(:leave_role, :string, default: "call-control-leave")
  attr(:share_id, :string, default: nil)

  attr(:share_hook, :string,
    default: nil,
    doc: ~s(JS hook mounted on the Share button; `/meetings` passes "MeetingShareButton")
  )

  attr(:share_click?, :boolean,
    default: true,
    doc: """
    Whether the Share button carries a `phx-click` AT ALL (task
    01a05b14 stage 6).

    The in-chat quickmeet passes `false`, and a shipped test REFUTES
    the attribute there: `meeting_share_button.js` calls
    `event.preventDefault()` + `stopPropagation()` as defence-in-depth
    against a double toggle, and its own moduledoc says the attribute
    is "stripped on the server side". `/meetings` leaves it true —
    the two surfaces genuinely disagree here, like the event names,
    so it is an attr and not a decision baked into the component.

    `share_event` is still passed when this is false: the hook pushes
    that name ITSELF through `pushEvent` when there is no LiveKit room
    yet, so the name stays part of the contract even with no
    `phx-click` in the markup.
    """
  )

  attr(:show_leave, :boolean,
    default: true,
    doc: "hide Leave on a surface where the viewer has not joined the call yet"
  )

  attr(:rest, :global)

  slot(:before_leave,
    doc: """
    Surface-specific controls rendered between Share and Leave.
    `/meetings` passes its push-to-talk button here (task 01a03f4e
    stage 5, re-homed in the merge with #910); the quickmeet has no
    push-to-talk producer and passes nothing. A slot rather than an
    attr because the button carries its own hook, id and
    `phx-update="ignore"` subtree, none of which this component should
    know about.
    """
  )

  def call_controls(assigns) do
    ~H"""
    <div
      class={["flex items-center justify-center gap-2", @class]}
      data-component="call-controls"
      {@rest}
    >
      <button
        type="button"
        phx-click={@mic_event}
        data-role={@mic_role}
        data-active={to_string(@mic_on)}
        data-on={to_string(@mic_on)}
        aria-pressed={to_string(!@mic_on)}
        aria-label={if @mic_on, do: "Mute microphone", else: "Unmute microphone"}
        class="btn btn-sm rounded-field gap-2 border-base-300 bg-base-200 font-normal text-base-content/80"
      >
        <span
          class={["size-4", if(@mic_on, do: "hero-microphone", else: "hero-microphone-slash")]}
          aria-hidden="true"
        >
        </span>
        <span class="call-control-label">{if @mic_on, do: "Mute", else: "Unmute"}</span>
      </button>

      <button
        type="button"
        phx-click={@camera_event}
        data-role={@camera_role}
        data-active={to_string(@camera_on)}
        data-on={to_string(@camera_on)}
        aria-pressed={to_string(!@camera_on)}
        aria-label={if @camera_on, do: "Turn camera off", else: "Turn camera on"}
        class="btn btn-sm rounded-field gap-2 border-base-300 bg-base-200 font-normal text-base-content/80"
      >
        <span
          class={["size-4", if(@camera_on, do: "hero-video-camera", else: "hero-video-camera-slash")]}
          aria-hidden="true"
        >
        </span>
        <span class="call-control-label">Camera</span>
      </button>

      <button
        type="button"
        id={@share_id}
        phx-hook={@share_hook}
        phx-click={@share_click? && @share_event}
        data-role={@share_role}
        data-active={to_string(@sharing)}
        data-on={to_string(@sharing)}
        aria-pressed={to_string(@sharing)}
        aria-label={if @sharing, do: "Stop sharing your screen", else: "Share your screen"}
        class="btn btn-sm rounded-field gap-2 border-base-300 bg-base-200 font-normal text-base-content/80"
      >
        <span class="hero-arrow-up-tray size-4" aria-hidden="true"></span>
        <span class="call-control-label">{if @sharing, do: "Stop sharing", else: "Share"}</span>
      </button>

      {render_slot(@before_leave)}

      <button
        :if={@show_leave}
        type="button"
        phx-click={@leave_event}
        data-role={@leave_role}
        aria-label="Leave the call"
        class="btn btn-sm rounded-field gap-2 border-error/40 bg-error/15 font-normal text-error hover:bg-error/25"
      >
        <span class="hero-arrow-right-start-on-rectangle size-4" aria-hidden="true"></span>
        <span class="call-control-label">Leave</span>
      </button>
    </div>
    """
  end

  # An unrecognised tab renders People rather than an empty rail: a
  # stale bookmark or a bad param should cost the user the tab they
  # asked for, not the whole pane.
  defp normalize_tab(tab) when is_binary(tab) do
    if Enum.any?(@tabs, fn {id, _} -> id == tab end), do: tab, else: "people"
  end

  defp normalize_tab(_), do: "people"
end
