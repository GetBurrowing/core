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

  alias PlatformWeb.Components.Meetings.AgentActivityBadge

  import PlatformWeb.AvatarComponents
  import PlatformWeb.Components.Meeting.VoiceWaveform, only: [voice_waveform: 1]

  alias Platform.Agents.Agent
  alias Platform.Agents.ColorPalette
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

  attr(:speaking_identities, :any,
    default: nil,
    doc: """
    `MapSet` of raw LiveKit identities the room reports as speaking
    (MeetingLive's `@speaking_identities`, from `activeSpeakersChanged`).
    A voice-present agent row (`MeetingLive.voice_present_agent?/1`) whose
    `MeetingLive.agent_gallery_identity/1` is in it, and whose activity
    word would otherwise read Idle, reads "Speaking" instead (task 01a1117f
    stage 5): a LiveKit voice worker's audio never passes through core, so
    core's own `:speaking` store state never fires for it. `nil` means
    nobody is speaking.
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
      |> assign(:speaking, assigns[:speaking_identities] || MapSet.new())

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
      <%!-- VERBATIM PORT of the approved Ask mockup (shared in
           Burrow's Meeting System space, not checked in). The DOM and
           class names below are the mockup's own: `.row > .av, .who > .nm +
           .st(.i/.l), .tools > .ask(.ring, .bars i×4, .lbl .off/.on) +
           .kick, .tr.live(.hd .dot, .vp > .tx > p), .tr.sent(.hd, .sum),
           .confirm, .gone`. Its CSS is `assets/css/meeting_ask.css`, scoped
           under `.meeting-ask` (this section). Do not restyle these elements
           with utilities: every value lives in that file, and every
           deviation from the mockup is listed there and in the PR that
           introduced it.

           Interaction state is data attributes, not pseudo-classes:
           `data-held`/`data-sent` on the row and `data-held` on `.ask` are
           set by `MeetingPushToTalk` (sticky across patches), and
           `data-kick` is rendered here from `@kick_confirm_id` /
           `@agent_removal_undo`.

           ALSO rendered with zero agents left when there is a removal to
           undo, so the Undo for the last agent's kick does not vanish with
           the section it lived in. --%>
      <section
        :if={@agents != [] or @agent_removal_undo}
        data-section="agents"
        class="meeting-ask"
      >
        <div class="sec">Agents</div>

        <ul role="list">
          <li
            :for={{p, info, aid} <- @agents_with_info}
            class="row"
            data-agent-slot={agent_slot(@agents_by_id, aid)}
            data-participant-id={p.id}
            data-participant-identity={MeetingLive.gallery_identity(p)}
            data-participant-type="agent"
            data-kick={
              if @can_remove_agents? and @kick_confirm_id == p.id, do: "confirm", else: "none"
            }
          >
            <% name = p.display_name || "Agent" %>
            <% held_by = if is_binary(aid), do: Map.get(@ask_floor_holders, aid) %>
            <% held_by_other? = is_binary(held_by) and aid != @pressed_agent_id %>
            <% agent_key = aid || "unresolved" %>
            <% leaving? = removing?(@removing_ids, p.id) %>
            <% mute_target = mute_pending_target(@muting_ids, p.id) %>
            <% muting? = not is_nil(mute_target) %>
            <% muted_done? = !muting? and muted_by_host?(@muted_agent_ids, p.id) %>
            <% own_pressed? = @hold_to_talk? and is_binary(aid) and aid == @pressed_agent_id %>
            <% can_mute? = @can_remove_agents? and is_binary(aid) %>
            <% mic = mic_state(@muted, p) %>
            <% ask_disabled? = held_by_other? or not is_binary(aid) %>

            <%!-- `.av`: the mockup's initials circle. The 8px `.avs` badge
                 (deviation, decision 2 option A) carries the old trailing
                 status dot and, for a non-host, the read-only mic state —
                 `--ok` when the agent is connected and its mic is on,
                 `--m` otherwise. The sr-only nodes keep both facts for a
                 screen reader. --%>
            <%!-- `data-voice` (task 01a1117f stage 4): an agent in the call
                 by voice shows the voice waveform glyph, a 32px rounded
                 square, in place of the initials circle. The square is what
                 says not-a-person; meeting_ask.css PART 2 reshapes `.av` for
                 it. A pending or text-only agent keeps its initials. --%>
            <% voice? = MeetingLive.voice_present_agent?(p) %>
            <div
              class="av"
              data-role="agent-activity-avatar"
              data-activity-state={info.ring_state}
              data-voice={voice? && "true"}
            >
              <.agent_row_face
                voice?={voice?}
                id={"#{@id_prefix}-wave-#{p.id}"}
                identity={MeetingLive.agent_gallery_identity(p)}
                name={name}
              />
              <%!-- The activity sentence ("Octavius is Delayed, waiting on
                   GitHub") for assistive tech; the visible word is `.st`. --%>
              <span class="sr-only">{info.label}</span>
              <span
                class="avs"
                data-role="agent-status-dot"
                data-tone={badge_tone(p, @agents_by_id, @agent_activity, mic, muted_done?)}
                aria-hidden="true"
              >
              </span>
              <span
                :if={!can_mute?}
                class="sr-only"
                role="img"
                aria-label={mic_label(mic)}
                data-role="mic-indicator"
                data-mic-state={to_string(mic)}
              >
              </span>
              <span class="sr-only" data-role="participant-state-summary">
                {state_sentence(name, mic, :unavailable)}
              </span>
            </div>

            <div class="who">
              <div class="nm" data-role="participant-name">{name}</div>
              <%!-- `.st`: ONE 17px line. `.i` is the agent's state word;
                   `.l` ("Listening…") crossfades over it while the row is
                   held. The state word's parts are `<bdi>`s, not spans,
                   because the mockup's `.st span` rule absolutely
                   positions every span inside `.st`. --%>
              <div
                class="st"
                data-role="agent-activity-word"
                title={info.delay_reason}
              >
                <span class="i">
                  <bdi :if={leaving?} data-role="meeting-agent-leaving">Leaving…</bdi>
                  <bdi :if={!leaving? and muting?} data-role="meeting-agent-muting">
                    {if mute_target, do: "Muting…", else: "Unmuting…"}
                  </bdi>
                  <bdi :if={!leaving? and !muting? and muted_done?} data-role="meeting-agent-muted">
                    Muted
                  </bdi>
                  <bdi
                    :if={!leaving? and !muting? and !muted_done? and held_by_other?}
                    data-role="meeting-agent-held-by"
                  >
                    Held by {held_by}
                  </bdi>
                  <bdi
                    :if={!leaving? and !muting? and !muted_done? and !held_by_other?}
                    data-role="agent-activity-primary"
                  >
                    {info.primary}
                  </bdi>
                  <bdi
                    :if={!leaving? and !muting? and !muted_done? and !held_by_other? and info.note}
                    data-role="agent-activity-reason"
                  >
                    {"· " <> info.note}
                  </bdi>
                  <bdi
                    :if={
                      !leaving? and !muting? and !muted_done? and !held_by_other? and
                        info.delay_reason
                    }
                    data-role="agent-activity-delay-reason"
                  >
                    {"· " <> info.delay_reason}
                  </bdi>
                </span>
                <%!-- aria-hidden: shown only by CSS opacity while held; the
                     held state is announced by `meeting-ptt-live-region`. --%>
                <span
                  class="l"
                  aria-hidden="true"
                  data-role={
                    if own_pressed?, do: "meeting-agent-talking", else: "meeting-agent-listening"
                  }
                >
                  Listening…
                </span>
              </div>
            </div>

            <div class="tools">
              <%!-- The Ask key. `phx-update="ignore"`: the hook owns its
                   `data-held`/`data-pressed`. The wrapper is NOT ignored, so
                   `pointer-events-none` there blocks a press once someone
                   else holds this agent's floor; `AskFloor.claim/5` is the
                   server-side backstop. --%>
              <div
                :if={@hold_to_talk?}
                class={["contents", held_by_other? && "pointer-events-none"]}
                data-role="meeting-agent-hold-wrap"
                aria-disabled={ask_disabled?}
              >
                <button
                  id={"#{@id_prefix}-#{agent_key}"}
                  phx-hook="MeetingPushToTalk"
                  phx-update="ignore"
                  type="button"
                  class="ask"
                  disabled={ask_disabled?}
                  data-role="meeting-agent-hold-to-talk"
                  data-agent-id={aid}
                  data-agent-name={p.display_name || "this agent"}
                  data-pressed="false"
                  data-held="false"
                  aria-label={"Ask #{p.display_name || "this agent"}"}
                  title={"Ask #{p.display_name || "this agent"}"}
                >
                  <span class="ring"></span>
                  <span class="bars"><i></i><i></i><i></i><i></i></span><span class="lbl"><span
                    class="off"
                    data-role="meeting-agent-hold-label"
                  >Ask</span><span
                    class="on"
                    data-role="meeting-agent-hold-label-listen"
                    aria-hidden="true"
                  >Listen</span></span>
                </button>
              </div>

              <%!-- Host mute (deviation, decision 2 option A): the old mic
                   well's button, in the mockup's `.kick` look. --%>
              <button
                :if={can_mute?}
                type="button"
                class="kick"
                phx-click="toggle_agent_mute"
                phx-value-participant-id={p.id}
                disabled={muting?}
                aria-pressed={to_string(!muting? and muted_done?)}
                aria-label={mute_button_label(mute_target, muted_done?, name)}
                title={mute_button_label(mute_target, muted_done?, name)}
                data-role="meeting-agent-mute"
                data-mute-state={mute_button_data_state(mute_target, muted_done?)}
              >
                <span :if={muting?} class="loading loading-spinner loading-xs" aria-hidden="true">
                </span>
                <span
                  :if={!muting? and muted_done?}
                  class="hero-microphone-slash size-4"
                  aria-hidden="true"
                >
                </span>
                <span
                  :if={!muting? and !muted_done?}
                  class="hero-microphone size-4"
                  aria-hidden="true"
                >
                </span>
              </button>

              <button
                :if={@can_remove_agents?}
                type="button"
                class="kick"
                phx-click="kick_confirm_open"
                phx-value-participant-id={p.id}
                disabled={leaving?}
                data-role="meeting-agent-kick"
                title={"Remove #{p.display_name || "this agent"} from this call"}
                aria-label={"Remove #{p.display_name || "this agent"} from the meeting"}
              >
                ✕
              </button>
            </div>

            <%!-- `.tr.live`: what the agent is hearing, while held. The hook
                 writes the live transcript into `.tx p` and sizes `.vp`/`.tx`
                 to it (cap 140px, newest line at the bottom). --%>
            <div
              :if={@hold_to_talk?}
              id={"#{@id_prefix}-#{agent_key}-live"}
              phx-update="ignore"
              class="tr live"
              data-role="meeting-ask-live"
              aria-hidden="true"
            >
              <div class="hd"><span class="dot"></span>Listening… release to send</div>
              <div class="vp">
                <div class="tx">
                  <p data-role="meeting-ask-live-text"></p>
                </div>
              </div>
            </div>
            <%!-- `.tr.sent`: shown for 2.2s after a release that actually
                 sent (held past the 380ms threshold), with the first lines. --%>
            <div
              :if={@hold_to_talk?}
              id={"#{@id_prefix}-#{agent_key}-sent"}
              phx-update="ignore"
              class="tr sent"
              data-role="meeting-ask-sent"
              aria-hidden="true"
            >
              <div class="hd">✓ Sent to {name}</div>
              <div class="sum" data-role="meeting-ask-sent-summary"></div>
            </div>

            <div
              :if={@can_remove_agents? and @kick_confirm_id == p.id}
              class="confirm"
              data-role="meeting-agent-kick-confirm"
              role="status"
            >
              <span class="q">Remove {name}?</span>
              <button
                type="button"
                class="mbtn"
                phx-click="kick_confirm_close"
                data-role="meeting-agent-kick-cancel"
              >
                Cancel
              </button>
              <button
                type="button"
                class="mbtn danger"
                phx-click="remove_agent_from_call"
                phx-value-participant-id={p.id}
                data-role="meeting-agent-kick-remove"
              >
                Remove
              </button>
            </div>

            <%!-- Failure and coaching lines (no mockup state): full-width
                 grid rows under the row, hidden unless there is something
                 to say. --%>
            <div
              :if={removal_error(@removal_errors, p.id)}
              data-role="meeting-agent-remove-error"
              class="fb flex w-full items-start gap-1.5 border-l-2 border-error pl-1.5 text-xs leading-[1.4]"
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
                class="mbtn shrink-0"
              >
                Try again
              </button>
            </div>

            <div
              :if={mute_error(@mute_errors, p.id)}
              data-role="meeting-agent-mute-error"
              class="fb flex w-full items-start gap-1.5 border-l-2 border-error pl-1.5 text-xs leading-[1.4]"
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
                class="mbtn shrink-0"
              >
                Try again
              </button>
            </div>

            <%!-- `phx-update="ignore"`: `MeetingPushToTalk` owns this line's
                 `data-open`/`data-tone` and text. --%>
            <div
              :if={@hold_to_talk?}
              id={"#{@id_prefix}-#{agent_key}-feedback"}
              phx-update="ignore"
              data-role="meeting-agent-hold-feedback"
              data-open="false"
              data-tone="neutral"
              class="fb group/feedback hidden w-full items-start gap-1.5 border-l-2 border-transparent pl-1.5 text-xs leading-[1.4] data-[open=true]:flex data-[tone=error]:border-error data-[tone=warning]:border-warning"
              role="status"
            >
              <span
                class="hero-information-circle mt-0.5 hidden size-3.5 shrink-0 group-data-[tone=neutral]/feedback:block"
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

          <%!-- The mockup's "gone" state. The removed agent has already left
               `@agents`, so this is its own `.row` with the same three
               columns (hidden by `[data-kick="gone"] > :not(.gone)`) so it
               keeps the row's exact geometry. Same `undo_remove_agent`
               handler and 8-second window as the page toast. --%>
          <li
            :if={@agent_removal_undo}
            class="row"
            data-agent-slot={ColorPalette.slot_for(Map.get(@agent_removal_undo, :slot))}
            data-kick="gone"
            data-role="meeting-agent-left"
          >
            <%!-- Inert, `visibility:hidden` copies of the row's own
                 children (the mockup hides them in place), so the gone row
                 keeps the live row's exact grid. --%>
            <div class="av" aria-hidden="true">{initials(@agent_removal_undo.agent_name)}</div>
            <div class="who" aria-hidden="true">
              <div class="nm">{@agent_removal_undo.agent_name}</div>
              <div class="st"><span class="i">Idle</span><span class="l">Listening…</span></div>
            </div>
            <div class="tools" aria-hidden="true">
              <button :if={@hold_to_talk?} type="button" class="ask" tabindex="-1">
                <span class="ring"></span>
                <span class="bars"><i></i><i></i><i></i><i></i></span><span class="lbl"><span class="off">Ask</span><span class="on">Listen</span></span>
              </button>
              <span :if={@can_remove_agents?} class="kick"></span>
              <span :if={@can_remove_agents?} class="kick">✕</span>
            </div>
            <div :if={@hold_to_talk?} class="tr live" aria-hidden="true">
              <div class="hd"><span class="dot"></span>Listening… release to send</div>
              <div class="vp">
                <div class="tx">
                  <p></p>
                </div>
              </div>
            </div>
            <div :if={@hold_to_talk?} class="tr sent" aria-hidden="true">
              <div class="hd">✓ Sent to {@agent_removal_undo.agent_name}</div>
              <div class="sum"></div>
            </div>
            <div class="gone">
              {@agent_removal_undo.agent_name} left the call<button
                type="button"
                class="mbtn"
                phx-click="undo_remove_agent"
                data-role="meeting-agent-left-undo"
              >Undo</button>
            </div>
          </li>
        </ul>

        <%!-- "Ask Burrow to leave" (task 01a0f31d stage 4): a second entry
             point into the SAME `remove_agent_from_call` action, shown only
             with exactly one agent present. Kept (decision 2), below the
             list, in the mockup's `.btn` look. --%>
        <div
          :if={@can_remove_agents? and length(@agents) == 1}
          data-role="meeting-ask-agent-leave-wrapper"
        >
          <% [only_active_agent] = @agents %>
          <button
            type="button"
            phx-click="remove_agent_from_call"
            phx-value-participant-id={only_active_agent.id}
            data-role="meeting-ask-agent-leave"
            disabled={removing?(@removing_ids, only_active_agent.id)}
            class="mbtn leave"
          >
            Ask Burrow to leave
          </button>
        </div>
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
          <span class="hero-users size-3.5 text-subtle"></span>
          <span class="text-[11px] font-semibold uppercase tracking-widest text-base-content">
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
                class="truncate text-xs font-medium text-base-content"
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
                class="truncate text-[11px] text-subtle"
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
            class="px-2 py-1.5 text-xs text-subtle"
          >
            No people yet.
          </li>
        </ul>
      </section>

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
           CENTRED card was the reflow the round-3 product review named —
           every word visibly moved the card, and the card sits over the
           whole stage, so it moved everything under it too. The live
           text now lives in the held row's own `.tr.live` popover (the
           mockup's, see the Agents section above; the round-3 floating
           `MeetingAskHeardOverlay` was retired by the verbatim port). This
           card keeps only the label and the
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
    </div>
    """
  end

  # The row's identity slot (task 01a1557a rung 3 stage 3): the agent's stored
  # `color` through `ColorPalette.slot_for/1`, the same resolution
  # `Chat.agent_slot_map_for_participants/1` gives the chat row and the gallery
  # tile, so all three surfaces carry one `data-agent-slot`. nil, blank,
  # unknown or an unresolved agent is "blue".
  defp agent_slot(agents_by_id, aid) when is_binary(aid) and is_map(agents_by_id) do
    case Map.get(agents_by_id, aid) do
      %{color: color} -> ColorPalette.slot_for(color)
      _ -> ColorPalette.slot_for(nil)
    end
  end

  defp agent_slot(_agents_by_id, _aid), do: ColorPalette.slot_for(nil)

  # The face at an agent row's avatar position: the voice waveform for an
  # agent in the call by voice, the mockup's initials otherwise (task
  # 01a1117f stage 4). The glyph inherits this section's text colour (`--t`
  # on the fixed-dark `.meeting-ask` surface); see `VoiceWaveform`'s
  # moduledoc for why that, and not `base-content`.
  attr(:voice?, :boolean, required: true)
  attr(:id, :string, required: true)
  attr(:identity, :string, required: true)
  attr(:name, :string, required: true)

  defp agent_row_face(assigns) do
    ~H"""
    <.voice_waveform :if={@voice?} id={@id} identity={@identity} bars={4} size={:rail} />
    <span :if={!@voice?} aria-hidden="true">{initials(@name)}</span>
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
      class="btn btn-ghost btn-square btn-xs size-6 min-h-0 rounded-full p-0 text-subtle hover:bg-base-300 hover:text-base-content focus-visible:bg-base-300 focus-visible:text-base-content max-sm:min-h-11 max-sm:min-w-11 disabled:opacity-100"
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
        class="hero-microphone size-3.5 text-subtle"
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
  defp glyph_tone(:unavailable), do: "text-subtle"
  defp glyph_tone(_state), do: "text-subtle"

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

  # ── Verbatim-port helpers (meeting Ask row) ─────────────────────────────

  # The mockup's `.av` shows ONE uppercase initial ("B" for Burrow, and
  # "S" even for "Sam Taylor").
  defp initials(name) when is_binary(name) do
    case name |> String.trim() |> String.first() do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end

  defp initials(_name), do: "?"

  # The `.avs` badge's tone, in the mockup's two colours: `ok` (`--ok`) when
  # the agent is connected (`agent_status_dot_class/3` answers success or
  # warning) and its mic is on, `m` (`--m`) otherwise.
  defp badge_tone(p, agents_by_id, activity, mic, muted_by_host?) do
    connected? =
      MeetingLive.agent_status_dot_class(p, agents_by_id, activity) in [
        "bg-success",
        "bg-warning"
      ]

    if connected? and mic != :off and not muted_by_host?, do: "ok", else: "m"
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

  # ── One composed row ────────────────────────────────────────────────────
  #
  # Everything the template needs for one agent, computed once. Takes the
  # whole `assigns` rather than five positional arguments because it now
  # reads four of them and the call site is inside a template.
  defp agent_row_info(assigns, participant) do
    agent_id = agent_id_of(participant)
    absent = %{state: :idle, entered_at: nil, age_s: 0}

    ring_entry = Map.get(assigns.ring_activity, agent_id, absent)

    word_entry =
      assigns.word_activity
      |> Map.get(agent_id, absent)
      |> voice_speaking_word(participant, assigns.speaking)

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

  # A voice worker's speech reaches the room straight from LiveKit, never
  # through core's audio dispatch, so core's `:speaking` store state cannot
  # see it and the word stayed "Idle" while the glyph beside it moved (task
  # 01a1117f stage 5). The room's own active-speaker set is the fact here.
  # It replaces ONLY `:idle`: a working or delayed word is the more useful
  # thing to read, and is left as it is.
  defp voice_speaking_word(%{state: :idle} = entry, participant, speaking) do
    if MeetingLive.voice_present_agent?(participant) and
         MapSet.member?(speaking, MeetingLive.agent_gallery_identity(participant)) do
      %{entry | state: :speaking}
    else
      entry
    end
  end

  defp voice_speaking_word(entry, _participant, _speaking), do: entry

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
