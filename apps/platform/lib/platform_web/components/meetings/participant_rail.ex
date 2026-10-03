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
    (the hook owns its DOM), so `class`/`disabled` on it are patched from
    this assign only on its FIRST render — correct for a viewer who joins
    mid-meeting, but a press that lands on an ALREADY-mounted button
    cannot repaint those. The wrapping element below is NOT ignored, so
    `class`/`aria-disabled` on it stay live for the whole session; the
    button's own `disabled` attribute is a same-render baseline, not the
    mechanism this depends on for correctness — the real backstop is
    `AskFloor.claim/5` refusing the press server-side regardless of what
    the client shows.

    CORRECTION (task 01a0fa7e-afd7 stage 5): `phx-update=\"ignore\"`'s
    freeze above is narrower than it reads — it covers every attribute
    EXCEPT `data-*` ones. LiveView's own `DOM.mergeAttrs(fromEl, toEl,
    isIgnored: true)` still copies every `data-*` attribute from the
    fresh server render onto the live button on each patch, which is
    exactly why `data-pressed`/`data-held` below (the two attributes
    `MeetingPushToTalk` owns and mutates) kept reverting to this
    template's literal `\"false\"` moments after a real press — see that
    hook's `updated()` for the fix and the full mechanism writeup.
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
    Row id => failure message ("Couldn't remove <name>.") for a removal
    that did not land. Rendered via the shared feedback-line
    pattern (task 01a0f842 stage 5, canvas 01a0f846-cfb1) — an error icon,
    a 2px `border-error` rule, `text-base-content` words, and a ghost "Try
    again" button that re-sends the same `remove_agent_from_call` click.
    The button stays enabled throughout so the host can tap again.
    """
  )

  attr(:muting_ids, :any,
    default: %{},
    doc: """
    NET-NEW (task 01a0f842 stage 5, canvas 01a0f846-cfb1): `meeting_participants`
    row id => target mute state (`true` muting, `false` unmuting) for a
    mute/unmute toggle currently in flight. A MAP, not a MapSet like
    `removing_ids` — the row's "Muting…"/"Unmuting…" activity word and the
    button's own label need to say WHICH DIRECTION is in flight, not just
    that something is.
    """
  )

  attr(:muted_agent_ids, :any,
    default: MapSet.new(),
    doc: """
    `meeting_participants` row ids CONFIRMED muted by
    `Meetings.mute_agent_in_call/4` — a real `MutePublishedTrack` round
    trip, not a display flag. Drives the mute button's done state (slashed
    glyph, `aria-pressed=true`, "Unmute <name>") and the row's "Muted"
    activity word. Tolerant of any enumerable or `nil`, same as
    `removing_ids`.
    """
  )

  attr(:mute_errors, :map,
    default: %{},
    doc: """
    Row id => failure message ("Couldn't mute <name>. Try again") for a
    mute/unmute that did not land, mirroring `removal_errors` — same
    shared feedback-line pattern, same "the button stays enabled" rule.
    """
  )

  attr(:kick_confirm_id, :any,
    default: nil,
    doc: """
    Round 4 ("touch it" canvas 01a0fdf2-804d) — the `meeting_participants`
    row id currently showing the inline "Remove <name>? Cancel / Remove"
    confirm in place of its Kick (✕) control. UI-only state: confirming
    does not call a different handler than today's bare remove button
    did — `kick_confirm_open`/`kick_confirm_close` only toggle which of
    the ✕ / confirm pair is on screen, and the Remove choice inside the
    confirm fires the SAME `remove_agent_from_call` click `can_remove_
    agents?`'s button always has, so there is exactly one path that ever
    removes an agent from the call, same as before this stage.
    """
  )

  attr(:agent_removal_undo, :any,
    default: nil,
    doc: """
    `%{agent_id:, agent_name:, ref:}` or `nil` — the SAME assign
    `MeetingLive` already sets on a successful removal and reads back in
    `undo_remove_agent` (task 01a0e906 stage 4), now ALSO rendered here as
    an inline "<name> left the call" + Undo row in the Agents list (round
    4, canvas 01a0fdf2-804d's "gone" state), alongside its pre-existing
    toast elsewhere on the page. The removed row itself is gone from
    `@agents` by the time this is set (`refresh_participants/1` already
    ran), so this draws as its OWN list item rather than literally the
    departed row staying in place — same undo, same 8-second window,
    different presentation of the same fact.
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
      <%!-- Round 4: ALSO rendered with zero agents left when there is a
           removal to undo — kicking the one agent in the room must not
           make the Undo for that exact kick vanish along with the
           section it lived in. --%>
      <section
        :if={@agents != [] or @agent_removal_undo}
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
                #
                # Item 1 (task 01a0f842 stage 1, canvas 01a0f846-cfb1): the
                # row no longer gets its OWN ring on press — only `z-[60]`
                # survives here, to lift the row above the dim while held.
                # The ring moved onto the Ask key itself (see its own
                # `data-[pressed=true]:ring-*` below), per the canvas's
                # "one ring only, on the key under the finger."
                "group relative flex flex-col gap-1 rounded-lg px-2 py-1.5 text-xs min-h-11 hover:bg-base-300/40 transition-colors",
                agent_row_align_class(info),
                @hold_to_talk? && "data-[pressed=true]:z-[60]"
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
              <%!-- `min-w-[32px]`, not `min-w-0` (task 01a0febf stage 6 —
                 Dalton's layout-shift bug, canvases 01a0febf-652b and
                 01a0ff1c). `min-w-0` gave this column NO floor, so once
                 the status-chip slot below claimed its (previously
                 unreserved) width out of an already-full row, this was
                 the only item with anywhere left to go and collapsed all
                 the way to 0 — confirmed by live DOM measurement on two
                 separate builds (PR #1174, #1176), same numbers both
                 times. `min-w-[32px]` keeps `truncate` working (a flex
                 item still needs an explicit floor below its content
                 size for `truncate` to engage at all) while guaranteeing
                 the name never fully disappears even if something else
                 in this row someday grows again. This is the SECOND
                 layer of the fix — the reserved status-chip slot below
                 is the one that actually stops the row's total width
                 from changing; this floor is the backstop if it didn't. --%>
              <div class="min-w-[32px] flex-1">
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
                <%!-- Mute (task 01a0f842 stage 5, canvas 01a0f846-cfb1,
                   states table): pending and done each claim this SAME
                   word slot wholesale, the same way `leaving?` already
                   does above — the canvas gives mute its own single word
                   per state ("Muting…"/"Unmuting…", "Muted"), not a
                   suffix on whatever the agent happened to be doing when
                   the host clicked. `mute_target` is `true`/`false` while
                   in flight (the DIRECTION), `nil` once settled; `muting?`
                   folds that into a plain boolean for the class/`:if`
                   branches below. --%>
                <% mute_target = mute_pending_target(@muting_ids, p.id) %>
                <% muting? = not is_nil(mute_target) %>
                <% muted_done? = !muting? and muted_by_host?(@muted_agent_ids, p.id) %>
                <% override_word? = leaving? or muting? or muted_done? %>
                <div
                  data-role="agent-activity-word"
                  class={[
                    "flex flex-wrap items-baseline gap-x-1 text-[11px] font-medium",
                    if(override_word?, do: "text-base-content/60", else: info.text)
                  ]}
                >
                  <span
                    :if={leaving?}
                    data-role="meeting-agent-leaving"
                    class="whitespace-nowrap text-base-content/60"
                  >
                    Leaving…
                  </span>
                  <span
                    :if={!leaving? and muting?}
                    data-role="meeting-agent-muting"
                    class="whitespace-nowrap text-base-content/60"
                  >
                    {if mute_target, do: "Muting…", else: "Unmuting…"}
                  </span>
                  <%!-- `:if={!leaving? and !muting? and muted_done?}`, not an
                     `else` branch of the clause above: `muting?` and
                     `muted_done?` already exclude each other
                     (`muted_done?` is computed `!muting? and ...`), but
                     spelling both guards out here keeps this `<span>`
                     correct even if a future edit reorders the ones above
                     it. --%>
                  <span
                    :if={!leaving? and !muting? and muted_done?}
                    data-role="meeting-agent-muted"
                    class="whitespace-nowrap text-base-content/60"
                  >
                    Muted
                  </span>
                  <span
                    :if={!override_word?}
                    data-role="agent-activity-primary"
                    class="whitespace-nowrap"
                  >
                    {info.primary}
                  </span>
                  <span :if={!override_word? and info.note} data-role="agent-activity-reason">
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
                  data-held="false"
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
                      # it does can leak back out into the row. `relative`
                      # anchors the hold-threshold underline (below) to
                      # THIS frame rather than the row's own `relative` —
                      # without it the underline's `absolute inset-x-0
                      # bottom-0` would size itself against the row, not
                      # the 88px key (item 1, task 01a0f842 stage 1).
                      "group/ptt btn btn-xs w-[88px] h-11 min-h-11 flex-shrink-0 justify-center gap-1 px-2 overflow-hidden relative",
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
                      # Item 1 (task 01a0f842 stage 1, canvas 01a0f846-cfb1):
                      # pressed INVERTS the rest fill instead of repainting
                      # it unchanged — that identical repaint was the whole
                      # regression Harper reported ("doesn't feel tactile").
                      # Black fill (`primary-content`), cyan label/glyph
                      # (`primary`), cyan ring — the largest colour change
                      # available without moving the fixed frame. The
                      # colour swap itself is forced instant (no fade) by
                      # the plain-CSS override in app.css keyed off this
                      # same `data-role` — DaisyUI's `.btn` ships its own
                      # `transition-duration: 0.2s` for these properties in
                      # the utilities layer (see `.meeting-hold-target`'s
                      # comment for why `!important` is what beats that),
                      # and this stage wants the inversion to land in the
                      # SAME FRAME as the press, not fade into it.
                      #
                      # Round 3 (task 01a0fa7e-afd7): `ring-2` -> `ring-[3px]`
                      # and a dedicated `ring-offset-2` against the inverted
                      # (black) fill — per the dispatch's own menu of
                      # strengthenings ("a more obvious ring/glow"). The
                      # offset matters more than the extra pixel here: at
                      # `ring-2` with no offset the ring sits flush against
                      # the button's own edge and partially reads as the
                      # button's border, not a separate "something changed"
                      # signal; the offset (rendered in the inverted
                      # `primary-content` fill it now sits on, via
                      # `ring-offset-primary-content`) puts a visible gap
                      # between the button's edge and the ring.
                      "data-[pressed=true]:bg-primary-content data-[pressed=true]:text-primary",
                      "data-[pressed=true]:ring-[3px] data-[pressed=true]:ring-primary",
                      "data-[pressed=true]:ring-offset-2 data-[pressed=true]:ring-offset-primary-content",
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
                      class="hero-signal absolute inset-y-0 left-0 size-3.5 transition-opacity duration-75 group-data-[held=true]/ptt:opacity-0"
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
                       anything it depends on.

                       Item 1 (task 01a0f842 stage 1, canvas 01a0f846-cfb1):
                       this swap now keys off `data-held`, not
                       `data-pressed` — `data-held` only flips true once
                       `MeetingPushToTalk`'s hold-threshold timer actually
                       fires (`HOLD_THRESHOLD_MS`, 380ms), where
                       `data-pressed` flips the instant the pointer goes
                       down. The canvas wants the waveform to replace the
                       glyph exactly when the hold threshold is crossed —
                       the same moment the underline below finishes
                       drawing and the heard card opens — not at 0ms. --%>
                    <%!-- `gap-0.5` (2px): both reference canvases set
                       `.bars { gap: 2px }`; this was `gap-px` (1px). --%>
                    <span
                      class="absolute inset-0 flex items-center gap-0.5 opacity-0 transition-opacity duration-75 group-data-[held=true]/ptt:opacity-100"
                      data-role="meeting-agent-hold-waveform"
                      aria-hidden="true"
                    >
                      <%!-- Fidelity fix: both reference canvases draw these
                         bars at `width: 3px` and full-strength
                         `currentColor` (no opacity reduction), with
                         `transition: height .06s`. This span had drifted
                         to `w-0.5` (2px — Tailwind has no bare 3px step,
                         hence the arbitrary value), a flat `opacity-70`
                         dimming never present in either mock, and
                         `duration-75` (75ms) against the mock's 60ms. --%>
                      <span
                        :for={_bar <- 1..12}
                        data-ptt-bar
                        class="h-full w-[3px] origin-center rounded-full bg-current transition-transform duration-[60ms]"
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
                  <%!-- Item 1 (task 01a0f842 stage 1, canvas 01a0f846-cfb1):
                     the hold-threshold underline. Draws left-to-right
                     across the key's bottom edge over exactly
                     `HOLD_THRESHOLD_MS` (meeting_push_to_talk.js, 380ms)
                     so it answers "has my press counted yet" — the one
                     question the key could not answer before this stage.
                     Positioned/sized/coloured and timed entirely in
                     app.css, not Tailwind's `group-data` variant stack:
                     the reduced-motion override needs to flip WHICH
                     attribute drives the width (`data-pressed` vs
                     `data-held`), and two same-specificity Tailwind
                     utilities fighting over one property would depend on
                     generator output order rather than a controlled
                     cascade. --%>
                  <span
                    class="pointer-events-none absolute inset-x-0 bottom-0"
                    data-role="meeting-agent-hold-underline"
                    aria-hidden="true"
                  >
                  </span>
                </button>
              </div>

              <%!-- RESERVED STATUS-CHIP SLOT (task 01a0febf stage 6 —
                 Dalton's layout-shift bug, canvases 01a0febf-652b-7001-83da-
                 c15b1c4ea846 and 01a0ff1c-37ab-7001-a91c-b61e0b1e7499,
                 "1c" in his test matrix). Two independent live-browser
                 measurements on two separate builds (PR #1174, then its
                 fix PR #1176 which deliberately left this ONE alone) found
                 the same numbers: pressing Ask inserted the "Talking…"
                 span below as a BARE EXTRA flex sibling with no width of
                 its own reserved ahead of time, into a row that already
                 had zero slack. The name column (the only item without a
                 `flex-shrink-0` floor) absorbed the insertion by
                 collapsing to 0, and what the name couldn't absorb spilled
                 out as real overflow — a horizontal scrollbar on desktop,
                 the Ask button itself drifting left on phone far enough to
                 cover the name it displaced. This is NOT a static
                 flexbox-read question; it only shows up as rendered pixel
                 measurement, which is why a prior static read missed it.

                 The fix is the standard reserve-space-for-a-toggle
                 pattern: an INVISIBLE sizer, same markup/classes as the
                 chip it is sizing, always rendered so this slot's width
                 never depends on `@pressed_agent_id` / `held_by_other?`.
                 The two real cues are absolutely positioned on top of it
                 (`inset-0` against this slot's own `relative`), so
                 whichever one is showing changes TEXT CONTENT in place —
                 never the row's total width. "Held by <name>" can run
                 longer than "Talking…"; it `truncate`s inside this same
                 footprint rather than growing it, which is what the two
                 cues sharing one reserved slot requires — they are
                 mutually exclusive (`held_by_other?` is defined as
                 `aid != @pressed_agent_id`), so only one ever paints. --%>
              <div class="relative flex-shrink-0" data-role="meeting-agent-status-chip-slot">
                <span
                  aria-hidden="true"
                  data-role="meeting-agent-status-chip-sizer"
                  class="invisible inline-flex items-center gap-1 rounded-full px-1.5 py-0.5 text-[10px] font-semibold"
                >
                  <span class="size-3" aria-hidden="true"></span> Talking…
                </span>
                <%!-- The visible held cue, server-driven so it names WHICH
                   agent is being addressed while the key is down (per the
                   mock's "Asking <name>…"). The control's own highlight is
                   client-side; this is the roster-level confirmation. --%>
                <span
                  :if={@pressed_agent_id == aid and is_binary(aid)}
                  data-role="meeting-agent-talking"
                  class="absolute inset-0 inline-flex items-center gap-1 rounded-full bg-primary/15 px-1.5 py-0.5 text-[10px] font-semibold text-primary"
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
                  class="absolute inset-0 inline-flex items-center gap-1 truncate rounded-full bg-base-300 px-1.5 py-0.5 text-[10px] font-medium text-base-content/60"
                >
                  Held by {held_by}
                </span>
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

              <.media_slots
                name={p.display_name || "Agent"}
                mic_state={mic_state(@muted, p)}
                camera_state={camera_state(@camera_off, p)}
                can_mute?={@can_remove_agents? and is_binary(aid)}
                participant_id={p.id}
                mute_target={mute_target}
                muted_by_host?={muted_done?}
              />

              <%!-- KICK (round 4, canvas 01a0fdf2-804d — "a ✕ beside Ask.
                 Inline Cancel/Remove confirm, then 'Burrow left the call'
                 with an Undo action"). Replaces the old bare "Remove from
                 meeting" icon button (task 01a0e906 stage 3) with the SAME
                 permission gate and the SAME `remove_agent_from_call`
                 click underneath a confirm step — `@kick_confirm_id` is
                 the only new thing here, and it is pure client-visible
                 state (`kick_confirm_open`/`kick_confirm_close`), never a
                 second removal path. Always visible at every width, same
                 reasoning as before: hover does not exist on touch, and
                 the phone People sheet is where hosts look. --%>
              <div
                :if={@can_remove_agents?}
                class="relative flex-shrink-0 self-center"
                data-role="meeting-agent-kick-wrap"
              >
                <button
                  :if={@kick_confirm_id != p.id}
                  type="button"
                  phx-click="kick_confirm_open"
                  phx-value-participant-id={p.id}
                  data-role="meeting-agent-kick"
                  disabled={leaving?}
                  aria-label={"Remove #{p.display_name || "this agent"} from the meeting"}
                  title="Remove from meeting"
                  class="btn btn-ghost btn-xs btn-square text-base-content/60 hover:border hover:border-error hover:bg-error/10 hover:text-error focus-visible:border focus-visible:border-error focus-visible:bg-error/10 focus-visible:text-error max-sm:min-h-11 max-sm:min-w-11"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>

                <%!-- The confirm. A small anchored popover rather than a
                   modal — the canvas's own mockup keeps it INLINE on the
                   row, not a dialog that steals focus from the call. --%>
                <div
                  :if={@kick_confirm_id == p.id}
                  data-role="meeting-agent-kick-confirm"
                  class="absolute right-0 top-full z-20 mt-1 flex items-center gap-1.5 whitespace-nowrap rounded-lg border border-error bg-base-200 px-2 py-1.5 shadow-lg"
                  role="status"
                >
                  <span class="text-xs text-base-content">
                    Remove {p.display_name || "this agent"}?
                  </span>
                  <button
                    type="button"
                    phx-click="kick_confirm_close"
                    data-role="meeting-agent-kick-cancel"
                    class="btn btn-ghost btn-xs"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    phx-click="remove_agent_from_call"
                    phx-value-participant-id={p.id}
                    data-role="meeting-agent-kick-remove"
                    class="btn btn-error btn-xs"
                  >
                    Remove
                  </button>
                </div>
              </div>
            </div>

            <%!-- REMOVE / MUTE failure lines (task 01a0f842 stage 5, canvas
                 01a0f846-cfb1, "Palette" row for `error`). Replaces the old
                 `text-xs text-error` removal sentence outright: small red
                 text on this rail's light `base-200` measured about
                 3.4:1 — clears the 3:1 floor for an icon or a rule, FAILS
                 the 4.5:1 floor small TEXT needs. The colour signal now
                 lives only on the 2px `border-error` rule and the icon;
                 the sentence itself is `text-base-content`, same token
                 the Ask control's own feedback line below already uses
                 for the identical reason. Each is a full-width SIBLING of
                 the row (not nested in the name column, where the old
                 removal sentence lived truncated at the column's width),
                 with a ghost "Try again" that re-sends the EXACT same
                 click (`remove_agent_from_call` / `toggle_agent_mute`) —
                 a retry is indistinguishable, to either handler, from the
                 host's first attempt. --%>
            <div
              :if={removal_error(@removal_errors, p.id)}
              data-role="meeting-agent-remove-error"
              class="flex w-full items-start gap-1.5 border-l-2 border-error pl-1.5 text-xs leading-[1.4] text-base-content"
              role="status"
            >
              <span
                class="hero-exclamation-circle mt-0.5 size-3.5 shrink-0 text-error"
                aria-hidden="true"
              >
              </span>
              <span class="min-w-0 flex-1 break-words">{removal_error(@removal_errors, p.id)}</span>
              <button
                type="button"
                phx-click="remove_agent_from_call"
                phx-value-participant-id={p.id}
                data-role="meeting-agent-remove-retry"
                class="btn btn-ghost btn-xs shrink-0 text-base-content/80 hover:bg-base-300 hover:text-base-content"
              >
                Try again
              </button>
            </div>

            <div
              :if={mute_error(@mute_errors, p.id)}
              data-role="meeting-agent-mute-error"
              class="flex w-full items-start gap-1.5 border-l-2 border-error pl-1.5 text-xs leading-[1.4] text-base-content"
              role="status"
            >
              <span
                class="hero-exclamation-circle mt-0.5 size-3.5 shrink-0 text-error"
                aria-hidden="true"
              >
              </span>
              <span class="min-w-0 flex-1 break-words">{mute_error(@mute_errors, p.id)}</span>
              <button
                type="button"
                phx-click="toggle_agent_mute"
                phx-value-participant-id={p.id}
                data-role="meeting-agent-mute-retry"
                class="btn btn-ghost btn-xs shrink-0 text-base-content/80 hover:bg-base-300 hover:text-base-content"
              >
                Try again
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

          <%!-- Round 4 (canvas 01a0fdf2-804d) — the "gone" state: "Burrow
               left the call" with Undo, reusing the SAME
               `@agent_removal_undo` assign and the SAME `undo_remove_agent`
               handler `MeetingLive`'s pre-existing toast already uses
               (task 01a0e906 stage 4). The removed row itself is gone from
               `@agents` by the time this assign is set — a successful
               removal's `handle_async` clause runs `refresh_participants/1`
               in the same breath it sets this — so this draws as its OWN
               list item, appended after the real rows, rather than
               literally the departed row staying in place. Same undo,
               same 8-second window, honestly a different list position
               than the mockup's single-row demo implied. --%>
          <li
            :if={@agent_removal_undo}
            data-role="meeting-agent-left"
            class="flex items-center gap-2 rounded-lg border border-dashed border-edge px-2 py-1.5 text-xs text-base-content/60"
          >
            <span class="min-w-0 flex-1 truncate">
              {@agent_removal_undo.agent_name} left the call
            </span>
            <button
              type="button"
              phx-click="undo_remove_agent"
              data-role="meeting-agent-left-undo"
              class="btn btn-ghost btn-xs shrink-0 text-base-content hover:bg-base-300"
            >
              Undo
            </button>
          </li>
        </ul>
      </section>

      <%!-- ── Section 2: Hosts / humans ─────────────────────────────────── --%>
      <section
        data-section="humans"
        class={["px-2 py-2", (@agents != [] or @agent_removal_undo) && "border-t border-edge"]}
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
           and stops is the wrong reading here. It stays on THIS card: it
           is the OUTGOING mic level ("you are being captured"), a
           different fact from what Burrow heard.

           ROUND 3 (task 01a0fa7e-afd7, canvas 01a0fa80-da74): the dashed
           "HEARD box" (`meeting-ask-heard-box`) that used to sit here,
           carrying the live transcript text and growing with every word,
           is RETIRED as a heard-text holder. That auto-growth inside a
           CENTRED card was the reflow Harper's round-3 report named —
           every word visibly moved the card, and the card sits over the
           whole stage, so it moved everything under it too. The live
           text now lives in its own fixed-size, absolutely-positioned
           overlay (`MeetingAskHeardOverlay`, rendered as a sibling of
           this veil below) that never grows and is never a sibling in
           anyone's layout flow. This card keeps only the label and the
           meter above, plus the interrupted-error line below — the
           outcome choreography (`MeetingAskFloorVeil._flyCard`), not the
           live heard text. --%>
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
          <div class="flex h-6 items-center gap-1" data-role="meeting-ask-meter">
            <span
              :for={_bar <- 1..12}
              data-ptt-bar
              class="h-full w-1 origin-center rounded-full bg-primary opacity-70 transition-transform duration-75"
              style="transform: scaleY(0.08)"
            >
            </span>
          </div>

          <%!-- Task 01a0f842 stage 2, canvas 01a0f846-cfb1, item 2 — the
               INLINE failure line for a rejection/outcome that arrives
               while this card is open. Per the direction's "Interrupted"
               state, a refusal never closes the card silently: it shows
               here, inside the still-open card, for a couple of seconds,
               and only THEN does `MeetingAskFloorVeil._close()` run.

               Same icon-plus-rule pattern as the row's own
               `meeting-agent-hold-feedback` line above (error only — this
               card has nothing to say in the neutral/warning tones that
               line uses), and `phx-update="ignore"`-equivalent by virtue
               of living inside the veil's own `phx-update="ignore"` root:
               `MeetingAskFloorVeil` owns `data-open` and the text node
               directly, so a re-render mid-message cannot wipe it. --%>
          <div
            class="hidden items-start gap-1.5 border-l-2 border-error pl-1.5 text-xs leading-[1.4] text-base-content data-[open=true]:flex"
            data-role="meeting-ask-error"
            data-open="false"
            role="status"
          >
            <span
              class="hero-exclamation-circle mt-0.5 size-3.5 shrink-0 text-error"
              aria-hidden="true"
            >
            </span>
            <span data-role="meeting-ask-error-text" class="min-w-0 flex-1 break-words"></span>
          </div>
        </div>
      </div>

      <%!-- Task 01a0fa7e-afd7, design canvas 01a0fa80-da74 ("Burrow round
           3: floating heard text and hittable rail"). The floating
           "what Burrow heard" overlay — ONE per rendered rail, same
           singleton reasoning as the veil above, and entirely client-
           driven by `MeetingAskHeardOverlay` off the SAME
           `meeting:push-to-talk-*` window events, so it opens/closes in
           lockstep with the veil without either hook holding a reference
           to the other.

           OUT OF PAGE FLOW, ALWAYS. `fixed` positioning with `left`/
           `top`/`width` set entirely by the hook's `_reposition` (there
           is no Tailwind breakpoint variant here on purpose — the
           desktop anchor depends on WHICH row is held, which no media
           query can express) is what makes "nothing in the rail, the row
           or the stage ever moves" true regardless of transcript length:
           this element is never a sibling in anyone else's flex/grid
           flow, so it has nothing to push.

           FIXED SIZE FROM OPEN. The inner window below is a hard 72px
           (3 lines at 16px/1.5) with `overflow-hidden`; the flex-col
           `justify-end` wrapper inside it is what makes new text push
           old text up and out the top for free, with no JS scroll
           management — see the hook's moduledoc.

           `pointer-events-none` on the container AND `[data-role=
           "meeting-ask-heard-overlay"] *` in `app.css` on every
           descendant (canvas: "nothing in it takes a click") — this is
           read-only, and the hook's own overlap check
           (`_wouldOverlapAControl`) is what keeps it off the Ask key,
           mute/remove buttons and any "Try again" line in the first
           place; `pointer-events-none` is the backstop for the case
           that check cannot see coming (a control added later without
           updating the selector list there).

           `phx-update="ignore"`: the hook owns the inline position
           styles and the status/text nodes' content directly — those are
           never in this template's markup at all, so no patch can touch
           them.

           CORRECTION (task 01a0fa7e-afd7 stage 5/6, round 2 of this
           task's review): `data-open`/`data-placement` are NOT actually
           protected by `phx-update="ignore"`, despite this comment
           previously claiming the hook "owns" them the same way it owns
           the inline styles. `DOM.mergeAttrs(fromEl, toEl, isIgnored:
           true)` still copies every `data-*` attribute the fresh server
           render carries onto this ignored element on each patch — this
           template's own literals above (`data-open="false"`,
           `data-placement="desktop"`) are exactly what land back on the
           live element when that happens, which is precisely why a real
           transcript chunk could arrive while `data-open` had been
           transiently stomped back to `"false"` mid-hold. Same mechanism
           `MeetingPushToTalk`'s own `ask_floor_holders` doc above was
           already corrected for; see `MeetingAskHeardOverlay.updated()`
           for the fix. --%>
      <div
        :if={@hold_to_talk?}
        id={"#{@id_prefix}-ask-heard-overlay"}
        phx-hook="MeetingAskHeardOverlay"
        phx-update="ignore"
        class="pointer-events-none fixed z-50 flex flex-col gap-1 rounded-box bg-base-300 p-3 shadow-md opacity-0 transition-opacity duration-150 data-[open=true]:opacity-100"
        data-role="meeting-ask-heard-overlay"
        data-open="false"
        data-placement="desktop"
        aria-hidden="true"
      >
        <span
          data-role="meeting-ask-heard-status"
          class="text-[12px] font-medium text-base-content/60"
        >
          Listening while you hold
        </span>
        <%!-- Round 4 ("touch it" canvas 01a0fdf2-804d): grows from one
             line up to ~7 (168px at the 24px/line `leading-6` below),
             THEN scrolls — `overflow-y-auto`, not `overflow-hidden`, so
             the viewer can scroll back up inside it while still holding
             (the hook's own scroll listener is what keeps new text
             pinned to the bottom unless they have scrolled away; see its
             moduledoc). The old `flex-col justify-end`/hard-72px/
             `overflow-hidden` trio relied on CLIPPING the top to fake
             "oldest falls off" — real scrolling needs normal top-to-
             bottom flow instead, so `justify-end` is gone too. The
             top-fade mask lives in `app.css` (`::before` on the
             `-window-wrap` data-role just below, NOT on this scrolling
             div — see that wrapper's own comment for why) rather than
             here, since it has to sit at a fixed height regardless of how
             tall the box has grown. --%>
        <%!-- The fade mask lives on THIS wrapper (`-window-wrap`), not on the
             scrolling `-window` div it surrounds. `-window` is both the
             positioning context the old `::before` anchored to AND the
             `overflow-y-auto` box `_scrollToBottom`/`_onWindowScroll` drive
             — an absolutely-positioned descendant of a scroll container is
             part of that container's scrollable overflow region, so a mask
             anchored to `-window` scrolled away WITH the text instead of
             staying pinned to the top of the viewport: `top: 0` meant "top
             of the content," which moves off-screen the moment `scrollTop`
             advances, not "top of what's visible." The wrapper never
             scrolls, so a mask anchored to it (see app.css) stays pinned to
             the visible top edge regardless of how far `-window` has
             scrolled. --%>
        <div class="relative" data-role="meeting-ask-heard-window-wrap">
          <div
            class="max-h-[168px] overflow-y-auto"
            data-role="meeting-ask-heard-window"
          >
            <div
              data-role="meeting-ask-heard-text"
              class="text-base leading-6 text-base-content [overflow-wrap:anywhere]"
            >
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

  attr(:can_mute?, :boolean,
    default: false,
    doc: """
    Render the mic slot as a real HOST MUTE BUTTON instead of the
    read-only well (task 01a0f842 stage 5, canvas 01a0f846-cfb1). Passed
    in by the caller as `@can_remove_agents? and is_binary(aid)` — the
    SAME `can_remove_agents?`-style host gate the remove button uses —
    never computed here, so this component stays ignorant of which row
    shape (agent vs. human) called it. `false` (every human row, and an
    agent row viewed by a non-host) renders the EXISTING read-only glyph
    unchanged: per the canvas's own self-critique against a second icon,
    "the existing glyph becomes the button for hosts," not a second
    control beside it.
    """
  )

  attr(:participant_id, :any,
    default: nil,
    doc: "The `meeting_participants` row id the mute button addresses, when `can_mute?`."
  )

  attr(:mute_target, :any,
    default: nil,
    doc: """
    `true`/`false` while a mute/unmute toggle for this row is in flight
    (the DIRECTION it is headed), `nil` when idle/settled. See
    `agent_row_info`'s sibling assign of the same name in the template
    above for where this is resolved.
    """
  )

  attr(:muted_by_host?, :boolean,
    default: false,
    doc: """
    This row's mute has been CONFIRMED by `Meetings.mute_agent_in_call/4`
    — a real `MutePublishedTrack` round trip, not a display flag. Drives
    the button's `aria-pressed`, its slashed glyph, and its "Unmute
    <name>" label.
    """
  )

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
  #
  # Task 01a0f842 stage 5: the mic cell is now EITHER the read-only well
  # below OR `agent_mute_button/1`, gated on `@can_mute?` — never both, so
  # a host and a non-host never see two different elements claiming the
  # same cell at once.
  defp media_slots(assigns) do
    ~H"""
    <span class="sr-only" data-role="participant-state-summary">
      {state_sentence(@name, @mic_state, @camera_state)}
    </span>
    <span class="flex flex-shrink-0 items-center gap-1" data-role="media-slots">
      <.agent_mute_button
        :if={@can_mute?}
        name={@name}
        participant_id={@participant_id}
        mute_target={@mute_target}
        muted_by_host?={@muted_by_host?}
      />
      <span
        :if={!@can_mute?}
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

  attr(:name, :string, required: true)
  attr(:participant_id, :any, required: true)
  attr(:mute_target, :any, default: nil)
  attr(:muted_by_host?, :boolean, default: false)

  # HOST MUTE BUTTON (task 01a0f842 stage 5, canvas 01a0f846-cfb1). NET-NEW:
  # no agent mute control existed anywhere on main before this stage —
  # `toggle_intent_mute` in `intents_collapse.ex` is an unrelated
  # meeting-INTENT mute and shares nothing with this but the word "mute".
  #
  # Four states keyed off two assigns: `@mute_target` (in flight, with
  # direction) and `@muted_by_host?` (confirmed by a real LiveKit round
  # trip — see `Meetings.mute_agent_in_call/4`). Idle and Failed render
  # IDENTICALLY — "glyph returns to unmuted" is the canvas's own words for
  # Failed, and there is no fifth visual state to give it a look of its
  # own; the feedback line under the row (the template above) is what
  # tells a failed attempt apart from one that never happened.
  #
  # `size-6` well, `size-3.5` glyph — the SAME frame the read-only mic
  # slot uses, per the canvas's "the existing glyph becomes the button for
  # hosts" (not a second control — the canvas's own self-critique rejected
  # a first draft that gave mute its own button beside remove, for exactly
  # this reason). `rounded-full` overrides `btn-square`'s own
  # sharp corners to keep that circular footprint while gaining real
  # button semantics (focus ring, hover, keyboard activation, a real
  # disabled state). `max-sm:min-h-11 max-sm:min-w-11` matches the remove
  # button's own phone hit-area bump. No `--color-error` on any branch —
  # "no colour: muted is a setting, not an error" is the canvas's own
  # line for the done state, and idle/pending/failed have never used
  # error here either.
  defp agent_mute_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_agent_mute"
      phx-value-participant-id={@participant_id}
      disabled={not is_nil(@mute_target)}
      aria-pressed={to_string(is_nil(@mute_target) and @muted_by_host?)}
      aria-label={mute_button_label(@mute_target, @muted_by_host?, @name)}
      title={mute_button_label(@mute_target, @muted_by_host?, @name)}
      data-role="meeting-agent-mute"
      data-mute-state={mute_button_data_state(@mute_target, @muted_by_host?)}
      class="btn btn-ghost btn-square btn-xs size-6 min-h-0 rounded-full p-0 text-base-content/60 hover:bg-base-300 hover:text-base-content focus-visible:bg-base-300 focus-visible:text-base-content max-sm:min-h-11 max-sm:min-w-11 disabled:opacity-100"
    >
      <span
        :if={not is_nil(@mute_target)}
        class="loading loading-spinner loading-xs size-3.5"
        aria-hidden="true"
      >
      </span>
      <span
        :if={is_nil(@mute_target) and @muted_by_host?}
        class="hero-microphone-slash size-3.5 text-base-content"
        aria-hidden="true"
      >
      </span>
      <span
        :if={is_nil(@mute_target) and !@muted_by_host?}
        class="hero-microphone size-3.5 text-base-content/60"
        aria-hidden="true"
      >
      </span>
    </button>
    """
  end

  # The mute button's accessible label/tooltip across all four states.
  # Pattern-matched on `mute_target` first (in flight always wins, same
  # as the row's own "Muting…"/"Unmuting…" word above), then on
  # `muted_by_host?` for the settled idle/done pair. Failed has no clause
  # of its own: it resolves through the same `nil`/`false` path idle does,
  # which is exactly "glyph returns to unmuted" from the canvas's states
  # table.
  defp mute_button_label(true, _muted?, name), do: "Muting #{name}…"
  defp mute_button_label(false, _muted?, name), do: "Unmuting #{name}…"
  defp mute_button_label(nil, true, name), do: "Unmute #{name}"
  defp mute_button_label(nil, false, name), do: "Mute #{name}"

  defp mute_button_data_state(true, _muted?), do: "muting"
  defp mute_button_data_state(false, _muted?), do: "unmuting"
  defp mute_button_data_state(nil, true), do: "muted"
  defp mute_button_data_state(nil, false), do: "unmuted"

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

  # Mute (task 01a0f842 stage 5). `muting_ids` is a MAP (id => target
  # mute state), not a MapSet like `removing_ids` — see that attr's doc
  # for why the direction matters here and didn't for removal.
  defp mute_pending_target(pending, id) when is_map(pending), do: Map.get(pending, id)
  defp mute_pending_target(_pending, _id), do: nil

  # Tolerant of any enumerable (a `MapSet`, a list from a test) and of
  # `nil`, same reasoning as `removing?/2` above.
  defp muted_by_host?(nil, _id), do: false
  defp muted_by_host?(%MapSet{} = ids, id), do: MapSet.member?(ids, id)
  defp muted_by_host?(ids, id) when is_list(ids), do: id in ids
  defp muted_by_host?(_ids, _id), do: false

  defp mute_error(errors, id) when is_map(errors) do
    case Map.get(errors, id) do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> nil
    end
  end

  defp mute_error(_errors, _id), do: nil

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
