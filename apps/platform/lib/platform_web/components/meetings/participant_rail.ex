defmodule PlatformWeb.Components.Meetings.ParticipantRail do
  @moduledoc """
  Sectioned participant rail for `PlatformWeb.MeetingLive` (ADR 0042,
  task 019e2475-4395 stage 1).

  Renders TWO sections:

    1. **Agents** (top, task 01a0f31d stage 2 — moved above People per
       the approved design canvas, "Burrow meeting controls: design
       direction", 01a0f31f-46e8). One row per
       `participant_type == "agent"` carrying:
         * avatar
         * display name
         * the state word ("Thinking" / "Writing" / "Speaking" /
           "Delayed" / "Couldn't" / "Idle") as small text below the
           name, matching the ring and corner glyph on the avatar
         * a second line, on `:delayed` and only on `:delayed`, carrying
           the cause
         * status dot keyed off THIS MEETING's agent activity, with the
           global `agents.status` column only as an offline fallback
           (task 01a04a98)
         * the same two media slots, with the camera slot drawn as
           UNAVAILABLE rather than off

    2. **Hosts/humans** (bottom) — separated from section 1 by a
       `border-edge` divider (rendered only when the Agents section is
       non-empty, same as before the reorder) with a small "In this
       call" label. One row per `participant_type == "user"` carrying:
         * avatar (`human_avatar` component, sm)
         * display name
         * host badge (`hero-shield-check`) when
           `participant.id == meeting.host_participant_id`
         * a fixed mic slot and a fixed camera slot (see
           "Two slots on every row" below)

  `MeetingLive.partition_participants/1` still returns `{humans, agents}`
  — unchanged by the stage 2 reorder above, which touched only the
  TEMPLATE's section order, not this tuple or `roster_count/1` (the "N
  people · M agents" bar text depends on that order and is out of scope
  for the reorder).

  ## Two slots on every row (task 01a0740c stage 3)

  Both slots render on every row of both sections, always, in the same
  trailing position. An indicator that disappears in one of its states
  is indistinguishable from an indicator that failed to render, and a
  roster is read by scanning a column.

  The mic slot used to read `MeetingLive.mic_on?/1`, which read
  `attention_config["mic_on"]`, which `MeetingLive` hardcoded to `%{}`
  on every live presence row — so the rail told every viewer that every
  participant was muted, permanently, and had done since it shipped.
  Both slots now read the per-identity MapSets that
  `handle_event("media_states", ...)` folds from LiveKit
  (`:muted_identities`, `:camera_off_identities`, task 01a0740c stages
  1-2), keyed with the same `MeetingLive.gallery_identity/1` the video
  tiles use. `mic_on?/1` is deleted; this was its only caller.

  ### Off is drawn three ways

  A slashed glyph, a red-tinted well, and an accessible label — never a
  hue shift alone, because a mic that changes only its tint is how
  somebody joins a call believing they are muted when they are not.

  ALL THREE NOW DRAW. They did not always. `hero-microphone-slash`
  generated NO CSS for as long as this indicator existed, because
  `assets/vendor/heroicons.js` emitted one class per file in
  `deps/heroicons/optimized` and the Heroicons set ships
  `microphone.svg` with no `microphone-slash.svg` at any of the four
  sizes, so the muted mic well painted its error tint around an empty
  centre. FE-19 (`01a07486-7985-7001-87ce-277681791f52`) closed that:
  the glyph is vendored at
  `apps/platform/assets/icons/24/outline/microphone-slash.svg`, and the
  Tailwind plugin now reads TWO roots, the Heroicons set first and
  `assets/icons` second, so a same-named local file wins. It is
  `assets/icons` and not `deps/heroicons/optimized` because
  `apps/platform/.gitignore` excludes `/deps/`: a file dropped there is
  untracked, survives neither `mix deps.get` nor a cached Docker layer,
  and fails silently (green locally, blank in the container).

  Two checks hold that fix in place.
  `test/platform_web/hero_icon_resolution_guard_test.exs` asserts every
  `hero-*` class used under `lib` resolves against those same two
  roots, so a call site that invents a class the icon set has no file
  for is red at `mix test` instead of blank in production.
  `e2e/tests/meeting_mute_glyph.spec.ts` reads
  `getComputedStyle(el).maskImage` on the rendered muted-mic element in
  a browser, because a class-attribute, `display` or `opacity` check
  passes perfectly on the blank version of this indicator.

  The CAMERA never shared the mic's fate: `video-camera-slash.svg`
  ships in all four sizes and always drew its slash for real.

  ### Tokens

  `--color-error` for OFF on both axes, `--color-base-content` at
  reduced opacity for ON, `--color-base-300` for the well. NOT
  `--color-warning`, which on this screen means "a human is being asked
  for something", and NOT `--color-success`, which is reserved for
  SPEAKING. The mic-on state used to be `text-success`; that was the
  violation, and replacing it is part of this stage.

  ## Two readings of one activity value (task 01a07400 stage 3)

  This component resolves its activity TWICE per render, and the reason
  is a design ruling rather than an optimisation it forgot to make.

  `:heard` — a two-second receipt that a transcript segment reached an
  agent's runtime — is applied by `AgentActivity.resolve_at/2` as an
  OVERLAY that replaces the state underneath it. Saru's design direction
  (canvas `01a07402-99e3`) rules that on this rail it must not replace
  the WORD:

  > "`heard` must not swap the word. … If a 2s state replaces the word, a
  > rail of four agents strobes through Heard/Idle/Heard and becomes
  > unreadable exactly when the room is busiest."

  So the ring and the word answer to different readings. `ring_activity`
  is the heard-inclusive one and paints the avatar; `word_activity` comes
  from `AgentActivity.without_heard/1` and chooses everything textual.
  An agent that is Thinking when a human talks over it keeps saying
  "Thinking" while its ring flashes — which is exactly the moment the
  reading matters most.

  Core makes the same call one layer down: stage 2 stopped `:heard` from
  overlaying `:speaking` at all, so an agent whose own audio is playing
  is never masked by a receipt for the voice talking over it.

  ## Where the store-backed states enter

  `:speaking` (asserted by core when it dispatches audio) and
  `:thinking`/`:composing` (declared by the agent's own runtime) live in
  ETS keyed by MEETING id, not in the `%AgentActivity{}` value. They are
  reachable only through `AgentActivity.resolve_at/3`, which is why this
  component resolves with a meeting id when it has one and falls back to
  the pure `resolve_at/2` reading when it does not.

  `:delayed` is applied on top of either, from facts gathered here — see
  the `:delays` attr and `gather_delay_facts/4`.

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
  alias PlatformWeb.Components.Meetings.CandidateDisplay

  import PlatformWeb.AvatarComponents
  import PlatformWeb.CoreComponents, only: [icon: 1]

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

  attr(:muted_identities, :any,
    default: nil,
    doc: """
    `MapSet` of LiveKit identities whose microphone is off, folded from
    the client's `media_states` push (task 01a0740c stage 2). Keyed with
    `MeetingLive.gallery_identity/1`, the same string the gallery tiles
    match on. `nil` normalises to an empty set so a caller that renders
    this component without the assign gets "nobody is muted" rather than
    a match error — which is also what a caller SHOULD get before the
    LiveKit room has reported anything.
    """
  )

  attr(:camera_off_identities, :any,
    default: nil,
    doc: """
    `MapSet` of LiveKit identities whose camera is off. Same source,
    same keying, same nil handling as `:muted_identities`. Ignored for
    agent rows, whose camera slot is UNAVAILABLE by construction.
    """
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

  attr(:delays, :any,
    default: nil,
    doc: """
    `%{agent_id => Platform.Meetings.AgentActivity.Delayed.t()}`, overriding
    the delays this component would otherwise infer (task 01a07400 stage 3).

    `nil` — the production path — means gather the facts and infer. The
    override exists because inferring a SPECIFIC cause is not possible
    without touching the database: every one of
    `AgentDelayReason.specific_for_agent/1`'s four clauses is derived from a
    resolved `%Agent{}` (a runtime row, a voice seat, a say ledger), so a
    component test holding a bare participant fixture can reach `:computing`
    but can never reach `:delayed`. Passing the delays directly is what lets
    the two-line row be proven without a sandbox, and it keeps the
    inference — the expensive half — in one place a caller can opt out of.
    """
  )

  attr(:hold_to_talk?, :boolean,
    default: false,
    doc: """
    Render a per-agent PRESS-AND-HOLD control on every agent row (the
    sponsor prototype's model: you hold a specific agent to talk to it,
    and the card comes back bylined to that agent). Each control hosts the
    `MeetingPushToTalk` hook, carries the agent id it addresses, and
    pushes `push_to_talk_press` / `push_to_talk_release`.

    `false` — the default — is what every surface without a push-to-talk
    producer gets (the in-chat quickmeet, and the desktop People tab when
    the desktop LEFT rail already carries the controls). Rendering the
    control on two rosters at once would put two hooks with the same DOM
    id in one document, so exactly one roster per viewport sets this.
    """
  )

  attr(:id_prefix, :string,
    default: "meeting-agent-ptt",
    doc: """
    Prefix for each hold control's DOM id (`\#{id_prefix}-\#{agent_id}`).
    Distinct per rendered roster so the desktop left rail and the People
    tab never collide even if both are briefly in the document during a
    viewport change.
    """
  )

  attr(:pressed_agent_id, :any,
    default: nil,
    doc: """
    The agent id currently being held by THIS viewer, or nil. Drives the
    visible \"Talking…\" cue and the live-region announcement; the
    control's own pressed styling is client-side (the hook sets
    `data-pressed`), so the row highlights the instant the key goes down
    without waiting for this to round-trip.
    """
  )

  attr(:ask_floor_holders, :map,
    default: %{},
    doc: """
    `agent_id => display_name` for every agent whose floor is CURRENTLY
    claimed by someone, meeting-wide (task 01a0cf5c stage 1,
    `Platform.Meetings.AskFloor`). Drives the \"Held by <name>\" cue and
    the visual disable on every OTHER agent's hold-to-talk row — a row
    where `aid == @pressed_agent_id` is THIS viewer's own hold and never
    reads as held-by-other, however this map answers.

    The hold-to-talk `<button>` itself carries `phx-update=\"ignore\"`
    (the hook owns its DOM), so it is patched from this assign only on
    its FIRST render — correct for a viewer who joins mid-meeting, but a
    press that lands on an ALREADY-mounted button cannot repaint the
    button's own attributes. The wrapping element below is NOT ignored,
    so `class`/`aria-disabled` on it stay live for the whole session;
    the button's own `disabled` attribute is a same-render baseline, not
    the mechanism this depends on for correctness — the real backstop is
    `AskFloor.claim/5` refusing the press server-side regardless of what
    the client shows.
    """
  )

  attr(:can_remove_agents?, :boolean,
    default: false,
    doc: """
    Render the "Remove from meeting" icon button on every AGENT row (task
    01a0e906 stage 3, Saru's canvas 01a0e99d-2af5). `MeetingLive` passes
    `host?(current_participant, meeting)`; nothing else sets it, so the
    chat quick-meet (`Chat.Partials`, via `CallShell.call_rail/1`) renders
    no button — removal from the quick-meet is out of scope. This is a
    DISPLAY gate only: `Meetings.remove_agent_from_call/3` re-checks the
    host on every click, so a forged event from a non-host changes nothing.
    Never rendered on a human row, including the host's own.
    """
  )

  attr(:removing_ids, :any,
    default: MapSet.new(),
    doc: """
    `meeting_participants` row ids (`p.id`) whose removal is in flight. Such
    a row reads "Leaving…" in place of its activity word and its remove
    button is disabled, until `{:participant_left, _}` drops the row.
    """
  )

  attr(:removal_errors, :map,
    default: %{},
    doc: """
    Row id => failure message ("Couldn't remove <name>. Try again") for a
    removal that did not land. Rendered under the row name in `text-error`;
    the button stays enabled so the host can tap again.
    """
  )

  def participant_rail(assigns) do
    {humans, agents} = MeetingLive.partition_participants(assigns.participants)
    now = assigns[:now] || DateTime.utc_now()

    # TWO readings of the same value, for the reason `AgentActivity.
    # without_heard/1` documents: `:heard` overwrites the state underneath
    # it, and Saru's direction rules that a heard flash must not swap the
    # word. `ring` paints the avatar; `word` chooses the word.
    {ring, word} = resolve_both(assigns[:agent_activity], meeting_id_of(assigns.meeting), now)

    # The Room lookup the delay facts need (reply budget, agent chain) is a
    # DB read. Skipping it whenever nobody in the row set is in a state a
    # delay could even qualify keeps that cost bounded by "is anyone working
    # right now", not paid on every idle-room tick — the same bounding
    # instinct `Platform.Meetings.VoiceSeatCache`'s moduledoc argues for.
    # Gated on the WORD reading: an agent whose ring is mid-heard-flash is
    # still working underneath, and must not lose its delay clause for two
    # seconds because a transcript segment happened to land.
    working? =
      Enum.any?(word, fn {_id, %{state: s}} -> s in AgentActivity.delayable_states() end)

    room = if working?, do: room_for(assigns.meeting), else: nil
    facts_by_agent = gather_delay_facts(agents, word, assigns.agents_by_id, room)

    # `delays_from_facts/1` drops every agent with nothing SPECIFIC to say,
    # so a `:delayed` that reaches the screen always carries a real cause —
    # there is no reason-less one to write a fallback branch for.
    delays = assigns[:delays] || AgentActivity.delays_from_facts(facts_by_agent)

    assigns =
      assigns
      |> assign(:humans, humans)
      |> assign(:agents, agents)
      |> assign(:ring_activity, AgentActivity.apply_delays(ring, delays))
      |> assign(:word_activity, AgentActivity.apply_delays(word, delays))
      |> assign(:delay_facts, facts_by_agent)
      |> assign(:current_room, room)
      |> assign(:muted, assigns[:muted_identities] || MapSet.new())
      |> assign(:camera_off, assigns[:camera_off_identities] || MapSet.new())

    # Precomputed HERE, not with a `<% info = agent_row_info(assigns, p) %>`
    # inside the `<li>` as before, because the row's OWN class attribute
    # now needs `info.delay_reason` — see `agent_row_shape_class/1` below
    # — and a HEEx tag's attributes are evaluated before any `<% %>` block
    # inside its body. Composed once per agent from the same `assigns` the
    # inline call used, so nothing about how a row is computed changes.
    agents_with_info = Enum.map(agents, &{&1, agent_row_info(assigns, &1), agent_id_of(&1)})
    assigns = assign(assigns, :agents_with_info, agents_with_info)

    ~H"""
    <div data-component="participant-rail" class="flex flex-col">
      <%!-- Held-state announcement. A persistent `aria-live` region whose
           TEXT changes, so a screen reader hears "Talking to <name>…" when
           the viewer presses an agent's row and silence when they let go.
           The visible cue lives on the row itself; this is its non-visual
           twin. --%>
      <span
        :if={@hold_to_talk?}
        class="sr-only"
        role="status"
        aria-live="polite"
        data-role="meeting-ptt-live-region"
      >
        {pressed_agent_announcement(assigns)}
      </span>
      <%!-- ── Section 1: Agents ─────────────────────────────────────────── --%>
      <section
        :if={@agents != []}
        data-section="agents"
        class="px-2 pb-2 pt-2"
      >
        <%!-- Same pairing and the same `/60` reasoning as the humans
             heading below: the icon stays `/50` (a non-text glyph, 3:1
             floor), the label is `/60` (rendered text, 4.5:1 floor). --%>
        <div class="flex items-center gap-1.5 px-2 pb-1.5">
          <span class="hero-cpu-chip size-3.5 text-base-content/50"></span>
          <span class="text-[11px] font-semibold uppercase tracking-widest text-base-content/60">
            Agents
          </span>
        </div>

        <ul class="flex flex-col gap-0.5" role="list">
          <li
            :for={{p, info, aid} <- @agents_with_info}
            data-participant-id={p.id}
            data-participant-identity={MeetingLive.gallery_identity(p)}
            data-participant-type="agent"
            data-pressed="false"
            class={
              [
                # Task 01a0f324 stage 3 (item 3b, canvas "signature element"):
                # `flex-col` so the feedback line below can be a genuine
                # SECOND line under the existing row, full row width, rather
                # than squeezed onto the same flex line as the avatar/name/
                # button. `relative` gives the pressed-state `z-[60]` below
                # somewhere to take effect — z-index has no effect on a
                # statically positioned box. `MeetingPushToTalk` mirrors its
                # own `data-pressed` onto THIS element (closest
                # `[data-participant-type="agent"]`) whenever the row's Ask
                # button is pressed/released/rejected, since a CSS selector
                # can only read an ancestor's own attribute, never a
                # descendant's, and this row needs to react to its button's
                # state.
                "group relative flex flex-col gap-1 rounded-lg px-2 py-1.5 text-xs min-h-11 hover:bg-base-300/40 transition-colors",
                agent_row_align_class(info),
                @hold_to_talk? &&
                  "data-[pressed=true]:z-[60] data-[pressed=true]:ring-2 data-[pressed=true]:ring-base-content"
              ]
            }
          >
            <div class="flex w-full items-center gap-2">
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
              <%!-- Task 01a0cf5c stage 1. `aid != @pressed_agent_id` is
                 what tells THIS viewer's own hold apart from someone
                 else's: `@ask_floor_holders` carries every held agent
                 meeting-wide, including the one THIS viewer is
                 currently holding, and that row must keep showing
                 "Talking…" below rather than being disabled out from
                 under the person actually pressing it.

                 `info`/`aid` are already bound above via the
                 `agents_with_info` destructure (task 01a0cf5d stage 3) —
                 not re-derived here — because the row's own class
                 attribute needs `info.delay_reason` before any `<% %>`
                 block in the body would run. --%>
              <% held_by = if is_binary(aid), do: Map.get(@ask_floor_holders, aid) %>
              <% held_by_other? = is_binary(held_by) and aid != @pressed_agent_id %>
              <%!-- Task 01a0d3cd stage 1 (Saru's canvas 01a0d3cf-a424, finding
                 2: "render it disabled, never absent"). `aid` is `nil` only
                 for a participant `agent_id_of/1` could not resolve to a
                 binary id — unreachable today for a real agent row (every
                 branch of `MeetingLive.meeting_participant_view_model/1`
                 that sets `participant_type: "agent"` also sets a binary
                 `participant_id`, so `aid` is always binary here in
                 production; a bare test fixture is the only way to reach
                 this), but the control used to vanish with zero trace on
                 that branch instead of degrading. `agent_key` gives the
                 DOM ids something stable to interpolate either way. --%>
              <% agent_key = aid || "unresolved" %>
              <%!-- Task 01a0cf5c stage 2, canvas 01a0cf5e-9cb0: `--color-primary`
                 is reserved for the veil's meter and this ring, nowhere
                 else in the held state — so it fires only for the agent
                 THIS viewer is holding, never for `held_by_other?`. --%>
              <.agent_activity_avatar
                state={info.ring_state}
                name={p.display_name || "Agent"}
                avatar_url={p.avatar_url}
                label={info.label}
                held?={is_binary(aid) and aid == @pressed_agent_id}
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
                <%!-- Task 01a0e906 stage 3: while this row's removal is in
                   flight the WORD is "Leaving…" at the canvas's `/60` rest
                   tone, replacing the activity reading, until
                   `{:participant_left, _}` drops the row. --%>
                <% leaving? = removing?(@removing_ids, p.id) %>
                <div
                  data-role="agent-activity-word"
                  class={[
                    "flex flex-wrap items-baseline gap-x-1 text-[11px] font-medium",
                    if(leaving?, do: "text-base-content/60", else: info.text)
                  ]}
                >
                  <span
                    :if={leaving?}
                    data-role="meeting-agent-leaving"
                    class="whitespace-nowrap text-base-content/60"
                  >
                    Leaving…
                  </span>
                  <span :if={!leaving?} data-role="agent-activity-primary" class="whitespace-nowrap">
                    {info.primary}
                  </span>
                  <span :if={!leaving? and info.note} data-role="agent-activity-reason">
                    {"· " <> info.note}
                  </span>
                </div>
                <%!-- `:delayed` is the ONLY state that changes the row's shape,
                   and Saru's direction (canvas 01a07402-99e3) says why it
                   earns that: it is the one state carrying information the
                   first line cannot hold. The reason gets the whole second
                   line at the rail's ~224px rather than competing with the
                   name for the first.

                   TRUNCATION ORDER — "the reason truncates LAST" — is
                   implemented by the reason not truncating AT ALL: no
                   `truncate` here, and `break-words` so a long clause wraps
                   instead of clipping or overflowing. The NAME above keeps
                   its `truncate`, so the name is what yields first, which is
                   the ordering the direction asks for in its strongest form.

                   Colour is `base-content` at reduced opacity, NOT the
                   state's own `info`: the direction calls this line "prose,
                   subordinate to the name it explains", and it is the reason
                   for a state whose word is already carrying the colour. --%>
                <div
                  :if={info.delay_reason}
                  data-role="agent-activity-delay-reason"
                  class="break-words text-[11px] font-normal text-base-content/60"
                >
                  {info.delay_reason}
                </div>
                <%!-- The one use of the `error` slot on this control (canvas
                   01a0e99d-2af5): a removal that did not land. --%>
                <div
                  :if={removal_error(@removal_errors, p.id)}
                  data-role="meeting-agent-remove-error"
                  class="break-words text-xs text-error"
                >
                  {removal_error(@removal_errors, p.id)}
                </div>
              </div>

              <%!-- PER-AGENT HOLD-TO-TALK (per the prototype). Press and hold
                 this agent's row to speak directed at it; the card that
                 forms comes back bylined to this agent. The `data-agent-id`
                 is what the `MeetingPushToTalk` hook sends with
                 `push_to_talk_press`, so the server knows WHO up front
                 instead of working it out from the words afterwards.

                 A real <button>, so it is keyboard-reachable (the hook
                 binds Space/Enter to press/release), with an `aria-label`
                 naming the agent. `phx-update="ignore"`: the hook owns the
                 waveform bars' inline transforms and this row re-renders on
                 every activity tick. The id carries `@id_prefix` so the
                 desktop left rail and the People tab never collide.

                 WRAPPED in a plain `<div>` that does NOT carry
                 `phx-update="ignore"` (task 01a0cf5c stage 1): the button
                 itself is frozen after its first mount, so a press that
                 claims this agent's floor from ANOTHER already-connected
                 client can never repaint the button's own `class` or
                 `disabled`. The wrapper can, and `pointer-events-none`
                 there is what actually stops a mouse/touch press on an
                 already-mounted button once someone else holds the floor —
                 the button's own `disabled=` below is a same-render
                 baseline for a viewer who joins AFTER the floor is already
                 held (see `seed_ask_floor_holders/2` in `MeetingLive`), not
                 the live mechanism. Either way `AskFloor.claim/5` is the
                 real backstop: a keyboard Space/Enter reaching the server
                 anyway (pointer-events does not block a keydown) is
                 refused there and answered through
                 `push_to_talk_rejected`, same as any other refusal.

                 GATED ON `@hold_to_talk?` ALONE (task 01a0d3cd stage 1) —
                 NOT `@hold_to_talk? and is_binary(aid)` as before. Harper's
                 "I still don't see the ASK button" report (01a0d3cd) sent
                 this rail's whole gating shape under review; Saru's
                 direction (canvas 01a0d3cf-a424, finding 2) is explicit
                 that a persistent control must render disabled at a
                 boundary rather than disappear, because a control that
                 vanishes silently is indistinguishable from one that was
                 never built. `is_binary(aid)` is still live evidence — a
                 real agent row always has one, per
                 `MeetingLive.meeting_participant_view_model/1` — so it now
                 only disables the button (`agent_key` covers the DOM ids)
                 instead of removing the whole wrapper from the DOM. --%>
              <% ask_disabled? = held_by_other? or not is_binary(aid) %>
              <div
                :if={@hold_to_talk?}
                class={["contents", held_by_other? && "opacity-50 pointer-events-none"]}
                data-role="meeting-agent-hold-wrap"
                aria-disabled={ask_disabled?}
              >
                <button
                  id={"#{@id_prefix}-#{agent_key}"}
                  phx-hook="MeetingPushToTalk"
                  phx-update="ignore"
                  type="button"
                  disabled={ask_disabled?}
                  data-role="meeting-agent-hold-to-talk"
                  data-agent-id={aid}
                  data-agent-name={p.display_name || "this agent"}
                  data-pressed="false"
                  aria-label={"Ask #{p.display_name || "this agent"}"}
                  title={"Ask #{p.display_name || "this agent"}"}
                  class={
                    [
                      # `btn` alone, no `btn-ghost`: Saru's direction (canvas
                      # 01a0d3cf-a424) makes this the ONE filled, labelled
                      # control in the rail — everything else stays quiet text
                      # on `--color-base-200` so the Ask column is the thing a
                      # viewer's eye catches without reading. No radius utility
                      # here on purpose: `.btn`'s own `border-radius` already
                      # resolves to `--radius-field` (10px), which is Marlowe's
                      # no-pill rule and a DELIBERATE departure from the mock's
                      # pill geometry — the mock's prominence and wording are
                      # kept, its corner radius is not (canvas, "Signature
                      # element" section).
                      #
                      # Item 3a (task 01a0f324 stage 3) — FIXED FRAME, per the
                      # canvas's "signature element": `w-[88px] h-11` is
                      # constant across every state (idle, holding, refused,
                      # disabled/held-by-other) and appears nowhere else in
                      # this class list keyed to `data-pressed` or
                      # `data-rejected` — that invariant is what stops the
                      # control growing ~36px into neighbouring row content
                      # the moment the waveform (below) used to widen from
                      # `w-0` to `w-9`. `overflow-hidden` clips the 72px
                      # interior's own content swap to the frame so nothing
                      # it does can leak back out into the row.
                      "group/ptt btn btn-xs w-[88px] h-11 min-h-11 flex-shrink-0 justify-center gap-1 px-2 overflow-hidden",
                      # The shared touch utility (`touch-action: none`, no callout,
                      # no selection) — the same class the old single button wore,
                      # so a long press on a phone holds instead of raising the OS
                      # text-selection menu and the hook's pointer capture is not
                      # arming a control the browser has already claimed for
                      # scrolling.
                      "meeting-hold-target",
                      # Rest vs. disabled fill (canvas palette table). Rest is
                      # `--color-primary` (cyan) with a BLACK label — deliberately
                      # `text-primary-content`, not `text-base-content`: this app's
                      # own brand rule pairs `--color-primary` with
                      # `--color-primary-content` specifically because the latter
                      # is pinned black in BOTH themes (see `--color-primary-content`
                      # doc in app.css), while `--color-base-content` flips to
                      # near-white in the dark theme — which is exactly the
                      # white-on-cyan the canvas rules out. Disabled drops to
                      # `--color-base-300` fill / `--color-neutral` label, per the
                      # same table, and never loses the "Ask" word.
                      if(ask_disabled?,
                        do: "bg-base-300 text-neutral",
                        else: "bg-primary text-primary-content hover:bg-primary/90"
                      ),
                      # Held/pressed follows the EXISTING hold-to-talk ladder,
                      # unchanged by this stage — only the rest/disabled base
                      # above is new.
                      "data-[pressed=true]:bg-primary data-[pressed=true]:text-primary-content",
                      "data-[rejected=no-microphone]:text-error",
                      "data-[rejected=microphone-muted]:text-error",
                      "data-[rejected=pointer-lost]:text-error",
                      # `held-by-other` (task 01a0cf5c stage 1): the SERVER
                      # refused because another presser already has this
                      # agent's floor — see `MeetingPushToTalk._serverReject`.
                      "data-[rejected=held-by-other]:text-error"
                    ]
                  }
                >
                  <%!-- Item 3a interior (task 01a0f324 stage 3): the 72px
                     interior slot that swaps content while the OUTER frame
                     above stays fixed. Idle/disabled/refused shows the
                     16px `hero-signal` glyph; holding shows the 36px
                     waveform instead — the two are absolutely positioned
                     over the SAME `w-9 h-3` box so swapping between them
                     never nudges the label that follows. `relative` on the
                     slot plus `absolute inset-0`/`inset-y-0 left-0` on its
                     two children is what makes that overlap possible; a
                     plain `hidden`/`flex` toggle would have removed the
                     icon from flow and let the label creep left to fill
                     the gap, moving the ONE thing (the label) the canvas
                     needs to stay put while its neighbour changes. --%>
                  <span class="relative h-3 w-9 shrink-0" data-role="meeting-agent-hold-indicator">
                    <span
                      class="hero-signal absolute inset-y-0 left-0 size-3.5 transition-opacity duration-75 group-data-[pressed=true]/ptt:opacity-0"
                      aria-hidden="true"
                    >
                    </span>
                    <%!-- The waveform, hidden until the key is down. Twelve
                       bars, scaled on the Y axis by the hook; `currentColor`
                       keeps them on whatever token the button is wearing so
                       the armed and refused states carry through without JS
                       naming a colour.

                       Task 01a0d3cd stage 4 gave this a fixed `w-9`, fading
                       it in with `opacity` alone rather than the FULL width
                       (`~35px`) it used to occupy unconditionally. Task
                       01a0f324 stage 3 finishes that job: `w-9` used to be
                       the WAVEFORM's own final width sitting inside a
                       button with no width of its own, so growing from `w-0`
                       to `w-9` still grew the whole control by the same
                       36px into neighbouring row content — the button just
                       had nothing to clip it against. Now the OUTER button
                       is a fixed 88px frame (see its `class=` above) and
                       this span is `absolute inset-0` inside the shared
                       `w-9` slot next to the icon, so its opacity fade
                       moves nothing outside itself. The bars' own `scaleY`
                       transforms (`ptt_waveform.js`) never read the
                       container's width, so none of this costs the hook
                       anything it depends on. --%>
                    <span
                      class="absolute inset-0 flex items-center gap-px opacity-0 transition-opacity duration-75 group-data-[pressed=true]/ptt:opacity-100"
                      data-role="meeting-agent-hold-waveform"
                      aria-hidden="true"
                    >
                      <span
                        :for={_bar <- 1..12}
                        data-ptt-bar
                        class="h-full w-0.5 origin-center rounded-full bg-current opacity-70 transition-transform duration-75"
                        style="transform: scaleY(0.08)"
                      >
                      </span>
                    </span>
                  </span>
                  <%!-- The label (task 01a0d3cd stage 2, canvas 01a0d3cf-a424
                     finding 1: "Label the button... the word is the fix").
                     An icon-only ghost button in a column of avatars reads as
                     a status glyph, not a control — this is what makes it
                     legible as a button at all. Public Sans 13 medium,
                     `shrink-0 whitespace-nowrap` so "Ask" never truncates or
                     wraps at any rail width, per the canvas's Type section. --%>
                  <span
                    class="shrink-0 whitespace-nowrap text-[13px] font-medium"
                    data-role="meeting-agent-hold-label"
                  >
                    Ask
                  </span>
                </button>
              </div>

              <%!-- The visible held cue, server-driven so it names WHICH agent
                 is being addressed while the key is down (per the mock's
                 "Asking <name>…"). The control's own highlight is
                 client-side; this is the roster-level confirmation. --%>
              <span
                :if={@pressed_agent_id == aid and is_binary(aid)}
                data-role="meeting-agent-talking"
                class="inline-flex flex-shrink-0 items-center gap-1 rounded-full bg-primary/15 px-1.5 py-0.5 text-[10px] font-semibold text-primary"
              >
                <span class="hero-signal size-3 animate-pulse" aria-hidden="true"></span> Talking…
              </span>

              <%!-- The OTHER side of the same cue: someone ELSE holds this
                 agent's floor (task 01a0cf5c stage 1, canvas 01a0cf5e-9cb0
                 — "a visible owner when the floor is taken... the second
                 person's button must say so before they start talking,
                 not after"). Named from `@ask_floor_holders`, which every
                 connected client updates off the SAME room-topic broadcast
                 that landed the claim, so this appears everywhere at once,
                 not only for whoever tries to press next. --%>
              <span
                :if={held_by_other?}
                data-role="meeting-agent-held-by"
                class="inline-flex flex-shrink-0 items-center gap-1 truncate rounded-full bg-base-300 px-1.5 py-0.5 text-[10px] font-medium text-base-content/60"
              >
                Held by {held_by}
              </span>

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

              <.media_slots
                name={p.display_name || "Agent"}
                mic_state={mic_state(@muted, p)}
                camera_state={camera_state(@camera_off, p)}
              />

              <%!-- REMOVE FROM MEETING (task 01a0e906 stage 3, Saru's canvas
                 01a0e99d-2af5). NEUTRAL, not red: removing an agent destroys
                 nothing — it can be invited back, and stage 4's Undo is the
                 guard, so there is no confirm dialog and no row menu. Always
                 visible at every width (never hover-revealed: hover does not
                 exist on touch, and the phone People sheet is where hosts
                 look). The payload carries ONLY the row id; the actor is read
                 off the LiveView socket and `Meetings.remove_agent_from_call/3`
                 re-checks the host. --%>
              <button
                :if={@can_remove_agents?}
                type="button"
                phx-click="remove_agent_from_call"
                phx-value-participant-id={p.id}
                data-role="meeting-agent-remove"
                disabled={leaving?}
                aria-label={"Remove #{p.display_name || "this agent"} from the meeting"}
                title="Remove from meeting"
                class="btn btn-ghost btn-xs btn-square flex-shrink-0 self-center text-base-content/60 hover:bg-base-300 hover:text-base-content focus-visible:bg-base-300 focus-visible:text-base-content max-sm:min-h-11 max-sm:min-w-11"
              >
                <.icon name="hero-user-minus" class="size-4" />
              </button>
            </div>

            <%!-- Item 4 (task 01a0f324 stage 3) — the Ask control's feedback
                 line. Replaces the old floating `[data-role="meeting-agent-
                 hold-coach"]` tooltip, which was `max-w-56` + `fixed`, so
                 any copy longer than the early-release nudge clipped. This
                 is a plain block, a SIBLING of the row above (not inside
                 it, not `position: fixed`), so it renders directly under
                 Burrow's row at the row's own full width and grows
                 downward with the text — no `truncate`, no `max-w-*`.

                 Per the canvas's self-critique, the SENTENCE stays
                 `text-base-content` always (small coloured text fails the
                 AA floor on `base-200`); the colour signal lives only on
                 the leading icon and the 2px left rule, switched by
                 `data-tone` (`error` for "couldn't hear", `warning` for
                 "went offline"/disconnect, `neutral` for the early-release
                 nudge). Three icon spans rather than one swapped glyph:
                 heroicons are CSS masks keyed to a fixed class name (see
                 task 01a07486 — `hero-microphone-slash` silently generated
                 no CSS because Heroicons never shipped that file), so the
                 glyph itself cannot be swapped by a data-attribute
                 selector; only which of three fixed, real icons
                 (`hero-information-circle` / `hero-exclamation-circle` /
                 `hero-exclamation-triangle`, all confirmed present under
                 `deps/heroicons`) is shown can.

                 `phx-update="ignore"`: `MeetingPushToTalk` owns this
                 element's `data-open`/`data-tone` and its text node
                 directly (`_showFeedback`/`_hideFeedback`), same reasoning
                 as the button and the veil — a re-render on the next
                 activity tick must not wipe it mid-message. --%>
            <div
              :if={@hold_to_talk?}
              id={"#{@id_prefix}-#{agent_key}-feedback"}
              phx-update="ignore"
              data-role="meeting-agent-hold-feedback"
              data-open="false"
              data-tone="neutral"
              class="group/feedback hidden w-full items-start gap-1.5 border-l-2 border-transparent pl-1.5 text-xs leading-[1.4] text-base-content data-[open=true]:flex data-[tone=error]:border-error data-[tone=warning]:border-warning"
              role="status"
            >
              <span
                class="hero-information-circle mt-0.5 hidden size-3.5 shrink-0 text-base-content/60 group-data-[tone=neutral]/feedback:block"
                aria-hidden="true"
              >
              </span>
              <span
                class="hero-exclamation-circle mt-0.5 hidden size-3.5 shrink-0 text-error group-data-[tone=error]/feedback:block"
                aria-hidden="true"
              >
              </span>
              <span
                class="hero-exclamation-triangle mt-0.5 hidden size-3.5 shrink-0 text-warning group-data-[tone=warning]/feedback:block"
                aria-hidden="true"
              >
              </span>
              <span data-role="meeting-agent-hold-feedback-text" class="min-w-0 flex-1 break-words">
              </span>
            </div>
          </li>
        </ul>
      </section>

      <%!-- ── Section 2: Hosts / humans ─────────────────────────────────── --%>
      <section
        data-section="humans"
        class={["px-2 py-2", @agents != [] && "border-t border-edge"]}
      >
        <%!-- The Agents section above has carried a heading since it
             shipped; this one did not, so the People pane opened on an
             unlabelled list of faces. Same glyph-plus-uppercase pair,
             `hero-users` rather than `hero-cpu-chip` because these are
             people. Rendered unconditionally — the section itself is
             unconditional (it has an empty state), so a heading that
             hid with the list would leave "No people yet." floating
             under nothing. --%>
        <%!-- The icon stays `/50` — it is a decorative glyph, WCAG 1.4.11's
             3:1 non-text floor, which `/50` clears on both themes (4.70:1
             dark, 3.89:1 light). The LABEL is rendered text at 11px and
             needs the 4.5:1 text floor; `/50` measured 3.89:1 against the
             rail's actual painted background in the light theme (painted
             via canvas, not read off the `--color-base-200` token comment,
             which is `oklch(96% 0 0)` blended under this section's own
             `bg-base-200/40` — the two composite to the same colour). `/60`
             clears both themes (5.53:1 light, 6.44:1 dark) and is the same
             tone the sub-line and the delay-reason text already use. --%>
        <div class="flex items-center gap-1.5 px-2 pb-1.5" data-role="humans-heading">
          <span class="hero-users size-3.5 text-base-content/50"></span>
          <span class="text-[11px] font-semibold uppercase tracking-widest text-base-content/60">
            In this call
          </span>
        </div>

        <ul class="flex flex-col gap-0.5" role="list">
          <li
            :for={p <- @humans}
            data-participant-id={p.id}
            data-participant-identity={MeetingLive.gallery_identity(p)}
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
              <%!-- `/60`, not `/50` — measured against the rail's actual
                   painted background, `/50` is 3.89:1 in the light theme at
                   this 11px size, under the 4.5:1 AA text floor; `/60` is
                   5.53:1 light / 6.44:1 dark. See the humans-heading note
                   above for how this was measured. --%>
              <div
                :if={MeetingLive.via_guest_link?(p)}
                class="truncate text-[11px] text-base-content/60"
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

            <.media_slots
              name={p.display_name || "Unknown participant"}
              mic_state={mic_state(@muted, p)}
              camera_state={camera_state(@camera_off, p)}
            />
          </li>

          <li
            :if={@humans == []}
            class="px-2 py-1.5 text-xs text-base-content/40"
          >
            No people yet.
          </li>
        </ul>
      </section>

      <%!-- ── Ask Burrow to leave (task 01a0f31d stage 4) ───────────────────
           A second, more discoverable UI ENTRY POINT into the SAME
           remove-agent action task 01a0e906 already shipped (the per-row
           "Remove from meeting" icon button above, `remove_agent_from_call`
           / `Meetings.remove_agent_from_call/3`, the 8-second Undo toast) —
           not a second action. Reuses `@can_remove_agents?` verbatim: the
           identical `MeetingLive.host?/2` display gate the per-row icon
           already reads, re-checked host-side the same way on click.

           Rendered ONLY when exactly one agent is active in the call.
           `@agents` is the SAME list `partition_participants/1` produced
           above for the Agents section — a row leaves it the moment
           `Meetings.remove_agent_from_call/3` closes it (see the per-row
           "Leaving…" doc above), so this reads "active" for free, with no
           second query. Burrow is the singleton default assistant this
           control is named for; at 0 or 2+ active agents it is not clear
           which agent "Ask Burrow to leave" would target, so the control
           hides outright rather than becoming a picker — the per-row icons
           remain the only removal path with more than one agent present.

           Neutral ghost styling, `text-base-content` on the rail's own
           `base-200`, never red/error tokens and never "Kick" — removing
           an agent destroys nothing, it can be re-invited, and the
           existing Undo toast is the guard, same reasoning as the per-row
           icon's own comment. No confirm dialog, no row menu.

           `disabled` mirrors the per-row button's own `leaving?` gate so
           this control cannot fire a second request while the single
           agent's removal is already in flight. --%>
      <div
        :if={@can_remove_agents? and length(@agents) == 1}
        class="px-2 pb-2 pt-1"
        data-role="meeting-ask-agent-leave-wrapper"
      >
        <% [only_active_agent] = @agents %>
        <button
          type="button"
          phx-click="remove_agent_from_call"
          phx-value-participant-id={only_active_agent.id}
          data-role="meeting-ask-agent-leave"
          disabled={removing?(@removing_ids, only_active_agent.id)}
          class="btn btn-ghost btn-sm w-full justify-start gap-2 text-base-content/80 hover:bg-base-300 hover:text-base-content focus-visible:bg-base-300 focus-visible:text-base-content"
        >
          <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Ask Burrow to leave
        </button>
      </div>

      <%!-- Task 01a0cf5c stage 2, canvas 01a0cf5e-9cb0 ("Design direction:
           hold to ask"). The dimmed veil and centred "Asking <agent>…"
           card, ONE per rendered rail (not one per agent row — a viewer
           can only be holding one button at a time). Entirely client-
           driven by `MeetingAskFloorVeil`, off the `meeting:push-to-talk-*`
           window events `MeetingPushToTalk` dispatches, NOT off a
           LiveView assign: the 380ms early-release threshold and the
           live meter have to be exact to the millisecond, which a round
           trip through the server cannot promise. `phx-update="ignore"`,
           same reasoning as the hold button itself.

           The veil DIMS, it does not black out (`bg-[#171b25]/55` — the
           dark `--color-base-100` value the canvas names, at partial
           alpha, not the app's live theme token, because this is a scrim
           over live video and has to read the same regardless of the
           viewer's light/dark setting). `fixed inset-0`, so it covers
           the room (rails AND the video stage) regardless of where in
           the DOM this happens to sit — `ParticipantRail` only owns the
           rail, never the stage, so nothing shy of `fixed` could reach
           both. `pointer-events-none` throughout: this is choreography,
           not a modal, and the pointer is already captured on the held
           button (see `meeting_push_to_talk.js`'s pointer-capture
           notes), so nothing here needs to intercept a click.

           The card surface is `bg-base-300`, one step up from the room
           so it reads as raised, per the canvas's palette. The label and
           (in stage 3) the coaching-adjacent copy are utility weight
           (`text-xs` at `/60`); the meter is `bg-primary` — the ONE other
           place `--color-primary` appears in this state, alongside the
           held agent's own avatar ring above.

           The meter is 12 bars painted by `MeetingAskFloorVeil` off the
           SAME measured RMS level `MeetingPushToTalk.sample()` already
           computed for the button's own waveform (`meeting:push-to-talk-
           level`), reusing `paintBars` from `./lib/ptt_waveform` rather
           than a second `AnalyserNode` or a duration-filling progress
           bar — the canvas is explicit that a bar which fills to 100%
           and stops is the wrong reading here.

           The transcript line is scaffolding for stage 3 (OUT OF SCOPE
           here — "no live transcript text yet"): the empty node reserves
           the card's shape so stage 3 can wire live text into it without
           relayout, at the size/colour the canvas specifies for that
           text ahead of time (`text-base text-base-content`, one step up
           from the chat body's `text-sm`, no mono/display font — "it is
           speech, not data").

           Task 01a0e47c stage 3, design canvas 01a0e47d-3005: the
           transcript/meter pair sits inside its own dashed "HEARD box"
           (`meeting-ask-heard-box`), matching Harper's own mockup
           (canvas 01a0e47c-a1b4) rather than the flat card this used to
           be. `rounded-box border-dashed border-base-content/30
           bg-base-100` is the direction's own palette row, not
           `border-edge` (the dashed token `call_recap.ex`/`call_shell.ex`
           use elsewhere): the direction did the contrast math for THIS
           specific box on THIS specific fill and rejected the obvious
           choices for it by name ("cyan on white is 1.79:1 and fails as
           a visible border"). A screenshot render of `border-edge` here
           measured the same failure — `--edge` is `oklch(88% 0 0)` on
           `--color-base-100`'s `oklch(100% 0 0)` in the light theme, a
           12-point gap that reads as barely-there on the same white
           fill, where `base-content/30` (black at 30% opacity over
           white) is the direction's actual answer and the one that
           paints visibly. `base-content` at a fractional opacity is
           still a semantic slot, not a hand-picked hex — the same
           pattern `text-base-content/60` already uses throughout this
           file — so this is not a new one-off token, just the specific
           slot the direction names for this specific box. The step label inside it
           (`meeting-ask-step`) reads `CandidateDisplay.stage_label(:heard)`
           — the SAME "1 · heard" ladder rung `CandidateRail` now paints
           on the card this box becomes (see that module's `live_card/1`),
           so the number is not a running counter invented here: it is
           the one MeetingCandidate rung both surfaces already agree on.
           Per the direction's own self-critique, continuity is carried
           by the SAME OBJECT flying into the card
           (`MeetingAskFloorVeil._flyCard`), not by the numbers matching
           a sequence — the shared "1 · heard" label is what lets a
           viewer read that this box IS step 1 of the ladder the landed
           card keeps climbing, nothing more. --%>
      <div
        :if={@hold_to_talk?}
        id={"#{@id_prefix}-ask-veil"}
        phx-hook="MeetingAskFloorVeil"
        phx-update="ignore"
        class="pointer-events-none fixed inset-0 z-50 flex items-center justify-center bg-[#171b25]/55 opacity-0 transition-opacity duration-150 data-[open=true]:opacity-100"
        data-role="meeting-ask-veil"
        data-open="false"
        aria-hidden="true"
      >
        <div
          class="flex w-[calc(100%-2rem)] max-w-sm flex-col gap-3 rounded-2xl bg-base-300 p-4 shadow-xl"
          data-role="meeting-ask-card"
        >
          <span
            class="text-sm font-semibold text-base-content"
            data-role="meeting-ask-label"
          >
            Asking…
          </span>
          <div
            class="flex flex-col gap-2 rounded-box border border-dashed border-base-content/30 bg-base-100 p-3"
            data-role="meeting-ask-heard-box"
          >
            <span
              class="text-[10px] font-semibold uppercase tracking-wider text-base-content/60"
              data-role="meeting-ask-step"
            >
              {CandidateDisplay.stage_label(:heard)}
            </span>
            <p
              class="min-h-10 text-base text-base-content"
              data-role="meeting-ask-transcript"
            >
            </p>
            <div class="flex h-6 items-center gap-1" data-role="meeting-ask-meter">
              <span
                :for={_bar <- 1..12}
                data-ptt-bar
                class="h-full w-1 origin-center rounded-full bg-primary opacity-70 transition-transform duration-75"
                style="transform: scaleY(0.08)"
              >
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:mic_state, :atom, required: true)
  attr(:camera_state, :atom, required: true)

  # The trailing status cluster: an `sr-only` sentence, then the mic well,
  # then the camera well. Same order, same position, every row.
  #
  # The sentence is here because the icons ARE the payload of this
  # feature: a screen reader that only gets the name gets nothing. It is
  # `sr-only`, which is `position: absolute`, so it is not a flex item and
  # contributes no gap to the row it sits in. The per-icon `aria-label`s
  # are kept alongside it deliberately (the stage spec asks for both), so
  # a row announces the sentence and then the two labels; the redundancy
  # is the cost of the icons also being reachable one at a time.
  #
  # `title` is omitted on an UNAVAILABLE camera rather than set to the
  # label: `pointer-events-none` means the tooltip could never appear, and
  # an attribute whose behaviour is suppressed reads as a working one.
  defp media_slots(assigns) do
    ~H"""
    <span class="sr-only" data-role="participant-state-summary">
      {state_sentence(@name, @mic_state, @camera_state)}
    </span>
    <span class="flex flex-shrink-0 items-center gap-1" data-role="media-slots">
      <span
        class={["grid size-6 place-items-center rounded-full", well_class(@mic_state)]}
        role="img"
        aria-label={mic_label(@mic_state)}
        title={mic_title(@mic_state)}
        data-role="mic-indicator"
        data-mic-state={to_string(@mic_state)}
      >
        <span
          class={["size-3.5", mic_glyph(@mic_state), glyph_tone(@mic_state)]}
          aria-hidden="true"
        >
        </span>
      </span>

      <span
        class={[
          "grid size-6 place-items-center rounded-full",
          well_class(@camera_state),
          @camera_state == :unavailable && "pointer-events-none"
        ]}
        role="img"
        aria-label={camera_label(@camera_state)}
        title={camera_title(@camera_state)}
        data-role="camera-indicator"
        data-camera-state={to_string(@camera_state)}
      >
        <span
          class={["size-3.5", camera_glyph(@camera_state), glyph_tone(@camera_state)]}
          aria-hidden="true"
        >
        </span>
      </span>
    </span>
    """
  end

  # `:on` | `:off`. Agents are keyed the same way humans are: an agent
  # that has published no audio track at all is reported muted by
  # `meeting_client.js` (`_publicationMuted(null)` is `true`, "no
  # publication reads as off"), so a silent agent reads muted rather than
  # reading live.
  # Task 01a0e906 stage 3. Tolerant of any enumerable (a `MapSet` from
  # `MeetingLive`, a list from a test) and of `nil`, so a caller that omits
  # the attr never crashes the rail.
  defp removing?(nil, _id), do: false
  defp removing?(%MapSet{} = ids, id), do: MapSet.member?(ids, id)
  defp removing?(ids, id) when is_list(ids), do: id in ids
  defp removing?(_ids, _id), do: false

  defp removal_error(errors, id) when is_map(errors) do
    case Map.get(errors, id) do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> nil
    end
  end

  defp removal_error(_errors, _id), do: nil

  defp mic_state(muted, participant) do
    if MapSet.member?(muted, MeetingLive.gallery_identity(participant)),
      do: :off,
      else: :on
  end

  # `:on` | `:off` | `:unavailable`.
  #
  # AGENTS HAVE NO CAMERA, which is a different fact from a camera being
  # off. "Off" implies it could be on, so a roster that drew agents as
  # camera-off would read as every agent having disabled their video.
  # Matched on `participant_type` rather than on which section is
  # rendering, so the two sections cannot drift apart.
  defp camera_state(_camera_off, %{participant_type: "agent"}), do: :unavailable

  defp camera_state(camera_off, participant) do
    if MapSet.member?(camera_off, MeetingLive.gallery_identity(participant)),
      do: :off,
      else: :on
  end

  # OFF tints the well with `--color-error`. ON and UNAVAILABLE share the
  # neutral `--color-base-300` well the stage pins and are told apart by
  # GLYPH and tone, never by hue alone.
  defp well_class(:off), do: "bg-error/15"
  defp well_class(_state), do: "bg-base-300"

  # Not `text-success` for ON — success is reserved for SPEAKING — and not
  # `text-warning` for OFF, which on this screen means "a human is being
  # asked for something". Being muted asks nothing of anyone.
  defp glyph_tone(:off), do: "text-error"
  defp glyph_tone(:unavailable), do: "text-base-content/25"
  defp glyph_tone(_state), do: "text-base-content/60"

  # `hero-microphone-slash` resolves and paints, as of FE-19
  # (`01a07486-7985-7001-87ce-277681791f52`), against the vendored
  # `assets/icons/24/outline/microphone-slash.svg`. It emitted no CSS at all
  # before that: see the moduledoc for why the file lives under
  # `assets/icons` rather than in `deps/`.
  defp mic_glyph(:off), do: "hero-microphone-slash"
  defp mic_glyph(_state), do: "hero-microphone"

  # `hero-video-camera-slash` DOES compile — the slashed camera ships in
  # all four Heroicons sizes. UNAVAILABLE takes `hero-minus`, a shape
  # nobody reads as a camera, so an agent row differs from a human
  # camera-off row by glyph as well as by tone and by label.
  defp camera_glyph(:off), do: "hero-video-camera-slash"
  defp camera_glyph(:unavailable), do: "hero-minus"
  defp camera_glyph(_state), do: "hero-video-camera"

  defp mic_label(:off), do: "Microphone muted"
  defp mic_label(_state), do: "Microphone on"

  defp mic_title(:off), do: "Muted"
  defp mic_title(_state), do: "Mic on"

  defp camera_label(:off), do: "Camera off"
  defp camera_label(:unavailable), do: "No camera"
  defp camera_label(_state), do: "Camera on"

  defp camera_title(:off), do: "Camera off"
  defp camera_title(:unavailable), do: nil
  defp camera_title(_state), do: "Camera on"

  # The whole row state in plain words, for the `sr-only` line only. The
  # visible row says this with icons: five rows reading "unmuted, camera
  # on" is a wall of text announcing that nothing happened.
  defp state_sentence(name, mic_state, camera_state) do
    "#{name}, #{mic_word(mic_state)}, #{camera_word(camera_state)}"
  end

  defp mic_word(:off), do: "muted"
  defp mic_word(_state), do: "unmuted"

  defp camera_word(:off), do: "camera off"
  defp camera_word(:unavailable), do: "no camera"
  defp camera_word(_state), do: "camera on"

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

  # The `aria-live` text while an agent is held: "Talking to <name>…", or
  # empty when nobody is being addressed. The name is read off the same
  # `@agents` list the rows render from, so it cannot disagree with the
  # visible cue. Empty (not absent) when idle, so the region stays in the
  # document and its text is what changes.
  defp pressed_agent_announcement(%{pressed_agent_id: id, agents: agents})
       when is_binary(id) do
    case Enum.find(agents, fn p -> agent_id_of(p) == id end) do
      nil -> ""
      p -> "Talking to #{p.display_name || "the agent"}…"
    end
  end

  defp pressed_agent_announcement(_assigns), do: ""

  # ── Resolution: two readings of one value ───────────────────────────────
  #
  # `ring` is the heard-INCLUSIVE reading and paints the avatar; `word` is
  # the heard-FREE one and chooses the word under the name. See
  # `AgentActivity.without_heard/1` for why the two cannot be one.
  #
  # Store-backed states (`:speaking` from core, `:thinking`/`:composing`
  # pushed by the agent) live in ETS keyed by MEETING id, so they are only
  # reachable through `resolve_at/3`. A surface with no meeting id — a
  # caller that has not loaded one yet — degrades to the pure `resolve_at/2`
  # reading rather than guessing a key, which is the same answer this
  # component gave before those states existed.
  defp resolve_both(%AgentActivity{} = activity, meeting_id, now) do
    {resolve_one(activity, meeting_id, now),
     resolve_one(AgentActivity.without_heard(activity), meeting_id, now)}
  end

  # A caller holding an already-resolved map (test fixtures, and
  # `resolve_for_render/2`'s documented "accepts either" contract) has no
  # struct to strip and no timestamps to age, so the two readings are the
  # same map. A `:heard` in such a fixture therefore still shows the word
  # "Heard" — the fixture asserted a resolved state directly and there is no
  # underlying one recorded for it to fall back to.
  defp resolve_both(other, _meeting_id, now) do
    resolved = AgentActivity.resolve_for_render(other, now)
    {resolved, resolved}
  end

  defp resolve_one(activity, meeting_id, now) when is_binary(meeting_id),
    do: AgentActivity.resolve_at(activity, meeting_id, now)

  defp resolve_one(activity, _meeting_id, now), do: AgentActivity.resolve_at(activity, now)

  defp meeting_id_of(%{id: id}) when is_binary(id), do: id
  defp meeting_id_of(_meeting), do: nil

  # ── Delay facts ─────────────────────────────────────────────────────────
  #
  # Gathered ONCE per render for the agents a delay could actually qualify,
  # then used twice: `AgentActivity.delays_from_facts/1` promotes the four
  # SPECIFIC causes to the `:delayed` state, and `AgentDelayReason.
  # for_agent/1` renders whatever is left — in practice the generic "still
  # running a tool" — as the trailing note it has always been.
  #
  # That split is `Delayed`'s own ruling, not this component's: an agent
  # that is merely taking its time is working and slow, not blocked, and
  # promoting it would put "Delayed" on every ordinary turn past ten
  # seconds — the always-on badge shape canvas 01a05b11-54ff removed
  # `:listening` for, under a different word.
  defp gather_delay_facts(agents, word_activity, agents_by_id, room) do
    Enum.reduce(agents, %{}, fn participant, acc ->
      agent_id = agent_id_of(participant)
      entry = agent_id && Map.get(word_activity, agent_id)

      if entry && entry.state in AgentActivity.delayable_states() do
        Map.put(acc, agent_id, delay_facts(Map.get(agents_by_id, agent_id), room, entry.age_s))
      else
        acc
      end
    end)
  end

  # ── Row alignment (task 01a0cf5d stage 3) ────────────────────────────────
  #
  # The rail is 312px, wider than the mock's 224px, and the row's own type
  # sizes already meet or exceed the mock's — so "too small to read" is not
  # a width or font problem. Rendering the rail with REAL roster data (a
  # long agent name, a long `:delayed` reason) surfaced the actual defect:
  # `items-center` on a row whose two fixed-size ends (the 28px avatar, the
  # media-slot cluster) sit either side of a text column that can grow well
  # past them.
  #
  # `:delayed` is the ONLY state with an unbounded second line — the reason
  # clause deliberately never truncates (see the template's TRUNCATION
  # ORDER note) — so it is the only row that can balloon. Captured via CDP
  # at 312px with `Delayed.new!/1`'s realistic long-form text ("waiting on
  # GitHub for a workflow run that has been queued for several minutes
  # now"): the row grew to 130.6px, and `items-center` placed the avatar's
  # top edge 51.3px into it — dead centre of a paragraph, 45px away from
  # the name it identifies. The state lives ON the face precisely so a
  # viewer can read who-is-doing-what at a glance; centred alignment on a
  # tall row breaks that exact pairing, which reads as illegible even
  # though every character is full-size and full-contrast.
  #
  # Scoped to the one state that can grow: an ordinary row (name + one
  # working line) is at or near `min-h-11` regardless of alignment, so
  # `items-start` vs `items-center` there is a few px, not a defect.
  defp agent_row_align_class(%{delay_reason: reason}) when is_binary(reason),
    do: "items-start"

  defp agent_row_align_class(_info), do: "items-center"

  # ── One composed row ────────────────────────────────────────────────────
  #
  # Everything the template needs for one agent, computed once. Takes the
  # whole `assigns` rather than five positional arguments because it now
  # reads four of them and the call site is inside a template.
  defp agent_row_info(assigns, participant) do
    agent_id = agent_id_of(participant)
    absent = %{state: :idle, entered_at: nil, age_s: 0}

    ring_entry = Map.get(assigns.ring_activity, agent_id, absent)
    word_entry = Map.get(assigns.word_activity, agent_id, absent)

    meta = AgentActivityBadge.activity_meta(word_entry.state)
    agent = Map.get(assigns.agents_by_id, agent_id)
    facts = Map.get(assigns.delay_facts, agent_id, %{})

    {primary, note} = compose_word(word_entry, meta, agent, facts)

    # Present on `:delayed` entries and ONLY those — `apply_delays/2` puts
    # it there from a `%Delayed{}`, which cannot exist without a reason. No
    # nil-reason branch is written for it deliberately: a fallback here
    # would be dead code that hides the guarantee rather than relying on it.
    delay_reason = Map.get(word_entry, :reason)

    %{
      # The avatar follows the RING reading, so a heard flash paints it...
      ring_state: ring_entry.state,
      # ...while everything textual follows the WORD reading, so the flash
      # does not swap what the row says.
      state: word_entry.state,
      text: meta.text,
      primary: primary,
      note: note,
      delay_reason: delay_reason,
      label: sr_label(participant, meta, delay_reason)
    }
  end

  # The accessible sentence, composed HERE because this is the only place
  # that holds the name, the word and the reason at once.
  #
  # Saru's direction rules it must carry the reason — "Octavius is delayed,
  # waiting on GitHub", not just "delayed" — which is the whole point of
  # making motion the liveness axis and then not stranding a reader who
  # cannot perceive motion. It follows the WORD, not the ring, so a
  # two-second receipt is never announced as the agent's state.
  defp sr_label(participant, meta, nil),
    do: "#{participant.display_name || "Agent"} is #{meta.word}"

  defp sr_label(participant, meta, reason),
    do: "#{participant.display_name || "Agent"} is #{meta.word}, #{reason}"

  # `:delayed` — the bare word. The age counter is deliberately absent:
  # the direction's delayed wire carries no elapsed figure, because the
  # reason on the second line is the more useful answer to "how long has
  # this been stuck" and two numbers-and-clauses on one row is the clutter
  # the second line exists to avoid.
  defp compose_word(%{state: :delayed}, meta, _agent, _facts), do: {meta.word, nil}

  # The working states — the word carries the age IN THE SAME SLOT
  # (`Thinking · 3s`), never a separate counter node, per the stage spec's
  # "one working state, one word". The generic delay clause, when
  # `AgentDelayReason.for_agent/1` has one, is a SEPARATE trailing span so
  # it alone can wrap — see the template.
  #
  # `:thinking` and `:composing` join `:computing`/`:typing` here: they are
  # working states with an age, and the only difference is who observed
  # them.
  defp compose_word(%{state: state, age_s: age_s}, meta, _agent, facts)
       when state in [:computing, :typing, :thinking, :composing] do
    {"#{meta.word} · #{age_s}s", AgentDelayReason.for_agent(facts)}
  end

  # `:failed` — the word carries NO counter (the stage spec: "Couldn't
  # carries its reason, not a counter"); the reason is the same trailing
  # span every other state's delay clause uses.
  defp compose_word(%{state: :failed} = entry, meta, agent, _facts) do
    {meta.word, failed_reason(agent, entry)}
  end

  # `:idle`, `:heard`, `:speaking`, and the unreachable `:listening`
  # fallback: the bare word, no counter, no reason. `:speaking` joins them
  # because its duration is audible — a counter would caption something the
  # reader is already hearing.
  defp compose_word(_entry, meta, _agent, _facts), do: {meta.word, nil}

  # The facts behind "why is this agent taking a while" — gathered, not
  # judged. `AgentDelayReason` turns them into a clause and
  # `AgentActivity.Delayed` decides whether one is strong enough to be a
  # state; this function's only job is to read them from the four places
  # they live.
  #
  # A participant with no resolved `Agent{}` (guest surfaces pass
  # `agents_by_id: %{}`; a bare test fixture has none) can only offer the
  # `age_s` fact — every other fact needs the agent row `Meetings`/
  # `VoiceSeatCache` read against, and reporting a specific cause we did
  # not actually check would be a worse lie than reporting none. Such an
  # agent can therefore never reach `:delayed`, only the generic note.
  defp delay_facts(nil, _room, age_s), do: %{age_s: age_s}

  defp delay_facts(%Agent{} = agent, room, age_s) do
    %{
      age_s: age_s,
      runtime_offline?: Meetings.runtime_offline?(agent),
      no_voice_worker?: not VoiceSeatCache.seated?(agent)
    }
    |> Map.merge(room_facts(room, agent))
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
