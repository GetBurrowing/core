defmodule PlatformWeb.Components.Meetings.CallShell do
  @moduledoc """
  The call shell shared by BOTH meeting surfaces — `/meetings`
  (`PlatformWeb.MeetingLive`) and the in-chat quickmeet panel
  (`PlatformWeb.Live.Chat.Partials.meeting_panel/1`).

  Exports two pieces:

    * `call_rail/1` — the 312px right rail: a tab strip over a scrolling
      pane. The active tab carries its word, the rest are icons — 312px
      does not hold four labels, measured rather than assumed.

      THE STRIP IS PER-CALLER, not a fixed four-up. It is derived from
      the slots the caller supplied (`served_tabs/1`): `/meetings` fills
      `<:chat>` and gets People / Chat / Canvas / Transcript, and the
      quickmeet — which cannot mount a second chat inside the chat
      surface — passes no chat slot and gets the three it serves. A
      shared list rendered a Chat tab the quickmeet could not fill.
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
    {"chat", "Chat"},
    {"canvas", "Canvas"},
    {"transcript", "Transcript"}
  ]

  @doc """
  Every tab identifier this rail KNOWS ABOUT, in render order.

  Exposed so a caller can validate an incoming tab param against the
  same list the strip renders from rather than repeating the strings.

  NOT the list any given rail renders. Since task 01a084bf stage 4 the
  strip is derived from the slots the CALLER actually supplied — see
  `served_tabs/1` — because a tab whose pane the caller cannot fill is a
  button that leads nowhere. `/meetings` serves all four; the in-chat
  quickmeet serves three.

  **NOTHING THAT RENDERS TABS SHOULD READ THIS LIST** (task 01a089fe
  stage 1), and as of stage 4 nothing does — see the census below. 01a084bf stage 4 carved out one exception here — the
  `/meetings` collapsed icon strip, on the grounds that it mirrors the
  expanded rail on the same socket and that socket serves all four. That
  was true when it was written and it is the wrong thing to depend on:
  the strip agreed with the rail only because `/meetings` supplies
  `<:chat>` unconditionally, so the moment that slot is gated the strip
  would keep drawing a button the rail refuses to select. The exception is
  withdrawn and the strip now derives like everything else; validating an
  incoming `?tab=` param against the tab VOCABULARY is what is left.

  ## Census: who reads the unfiltered list (task 01a089fe stage 4)

  Defect 1 mattered because it was LATENT, not because of Chat: any future
  slot-backed tab gets its `tab_served?/2` clause for free in the expanded
  rail and would be silently wrong in every presentation reading this
  list. Stage 1 fixed the one reader we knew about; stage 4 established
  there are no others. Re-run it as
  `git grep -n 'CallShell.tabs()' -- lib test`, and read it with the two
  caveats below or it will mislead you.

  IN `lib/`, ZERO CALLS. Every match is comment prose. Exactly two things
  render a tab list, and both derive: `call_rail/1`'s `@rail_tabs` (from
  `served_tabs/1`) and the `/meetings` collapsed strip (from
  `MeetingLive.served_meeting_tabs/1`). The in-chat quickmeet has no
  second presentation to disagree with its rail at all — the 44px strip is
  markup private to `meeting_live.html.heex` and `quickmeet_toggle_rail`
  shows and hides the whole rail as a bottom sheet — so its correctness
  here is STRUCTURAL rather than a judgement someone has to keep making.

  CAVEAT ONE, AND IT IS WHY THAT GREP IS NOT THE WHOLE ANSWER:
  `normalize_tab/2`'s second argument DEFAULTS to `@tabs`, so an arity-1
  call reads the unfiltered list WITHOUT NAMING IT and matches no search
  for `tabs`. Three such calls exist —
  `ChatLive.MeetingHooks.handle_event("meeting_tab_select", …)`,
  `MeetingLive`'s own clause for that event, and
  `MeetingLive.chat_on_screen?/1`. NONE OF THEM RENDERS ANYTHING: each
  compares an active-tab id to decide a boolean unread flag. They are a
  stale-flag question, not a presentation, which is why they are outside
  defect 1 and why stage 3 measured a correction to them and withdrew it
  (it reds an existing `:meet_member` test; see those functions).

  CAVEAT TWO: `normalize_tab/1` and `@tabs` are both spelled the same way
  in unrelated modules — `ControlCenterLive` has a private
  `normalize_tab/1` about ROLES, and `OrgMemoryLive.MobileShell` has its
  own `@tabs`. Neither has anything to do with this rail. A census that
  greps the bare names picks them up and reads as five defects.

  NO LINT RULE OR GREP-BASED META-TEST GUARDS THIS, deliberately: a caller
  that genuinely serves every tab is entitled to this list, so such a
  check would fire on correct code. The call-site comments are the record.
  """
  def tabs, do: @tabs

  @doc """
  The tabs THIS caller can actually serve, in render order.

  ## Why the strip is derived and not shared (task 01a084bf stage 4)

  Stage 1 added `{"chat", "Chat"}` to `@tabs` and the strip rendered
  `:for={{id, label} <- tabs()}` — off the module attribute, ignoring
  what the caller had passed. There are two callers. `/meetings`
  (`meeting_live.html.heex`) fills `<:chat>` with the one
  `ChatLive.Embedded` `live_render`; the in-chat quickmeet
  (`PlatformWeb.ChatLive.Partials.meeting_panel/1`) passes NO chat slot,
  because it is embedded in the chat surface itself and a second mount
  would put two chats on one screen. So the quickmeet grew a Chat tab
  whose pane was empty while the real discussion sat beside it.

  Capability is therefore read off the SLOTS, not off a second list a
  caller has to remember to keep in sync: a caller that supplies no
  `:chat` slot gets no Chat tab, forever, and a future slot-backed tab
  inherits the same rule by adding one `tab_served?/2` clause. The
  alternative — a `tabs` attr each call site overrides — makes capability
  explicit but reintroduces exactly the second list that let this
  regression through.

  People, Canvas and Transcript are unconditional: each renders something
  honest with no slot at all (a roster, `call-rail-canvas-empty`, and the
  JS-owned transcript pane with its own empty state).

  ## Callers with no slots to hand over (task 01a089fe stage 1)

  `/meetings` draws the rail TWICE — the expanded `call_rail/1` and, when
  the viewer collapses it, a 44px icon strip that is markup in
  `meeting_live.html.heex`'s own scope. That strip is not a call to this
  component, so it holds no slots and cannot be filtered by reading them;
  it used to loop `tabs/0` and therefore rendered the UNFILTERED list
  while the rail beside it derived. Two presentations of one rail
  disagreeing about which tabs exist is the defect stage 1 removes.

  So `:chat` is accepted as a BOOLEAN capability as well as a slot list.
  Same predicate, same order, one derivation — a caller states what it
  serves in whichever form it has, and neither form is a second tab list
  to keep in sync.
  """
  @spec served_tabs(map()) :: [{String.t(), String.t()}]
  def served_tabs(assigns) do
    Enum.filter(@tabs, fn {id, _label} -> tab_served?(assigns, id) end)
  end

  # WHAT THIS PREDICATE CAN SEE: whether a slot was PASSED, never whether that
  # slot RENDERS ANYTHING (task 01a089fe stage 3).
  #
  # `Map.get(assigns, :chat, [])` is the slot LIST. It is empty exactly when
  # the caller wrote no `<:chat>` — or wrote one whose own `:if` was false,
  # which is the same thing to the compiler — and non-empty the moment one was
  # written, whatever its body then decides to do. A slot body is an
  # `:inner_block` function that has not been called when this runs, and its
  # output is never handed here, so AN `:if` INSIDE A SLOT BODY IS INVISIBLE TO
  # THIS FUNCTION. A caller who writes `<:chat><div :if={@thing}>…</div></:chat>`
  # is served a Chat tab for every viewer, and the viewers for whom `@thing` is
  # false get that tab over a pane with nothing in it: the `case @active` has no
  # markup on its `"chat"` branch by design, so all that renders is an empty
  # `call-rail-chat-wrap`. That was defect 2 of task 01a089fe, on the
  # `/meetings` guest surface, and it was fixed in `meeting_live.html.heex` by
  # moving the condition ONTO the slot — not by teaching this function to look
  # inside one, which it cannot do.
  #
  # THIS IS THE BOUNDARY OF SLOT INTROSPECTION, NOT A FLAW IN CHOOSING IT.
  # Keying on the slot is what makes capability declarative and keeps it from
  # becoming a second tab list every caller has to remember to update (see
  # `served_tabs/1`). Nothing reachable from here could distinguish a slot that
  # renders a live chat from one that renders an empty div; that answer lives in
  # the caller's own condition, which is precisely why the condition has to sit
  # on the slot.
  #
  # SO `served_tabs/1` DOES NOT PROMISE A NON-EMPTY PANE. It reports what the
  # caller DECLARED. A caller that conditions its pane's CONTENT must condition
  # the SLOT by the same expression, and no test in this module can catch one
  # that does not — the mismatch is only visible in a render of the caller
  # (`meeting_live_rail_collapse_test.exs`, describe "(i)").
  defp tab_served?(assigns, "chat"), do: chat_served?(Map.get(assigns, :chat, []))

  # CANVAS IS CONDITIONAL SINCE THE DESKTOP LEFT RAIL LANDED (task 01a0693e).
  # On `/meetings` at `lg` the candidate card board is a first-class LEFT rail
  # beside the agents, so the right rail must NOT also carry a Canvas tab — that
  # was the "buried behind a mislabeled tab" state the prototype alignment
  # removes. The desktop `/meetings` caller therefore passes
  # `serve_canvas_tab: false`, and the collapsed strip's `served_meeting_tabs/1`
  # does the same. Everyone else — the in-chat quickmeet, which is a small panel
  # with no room for a left rail, and the `/meetings` MOBILE sheet, which reaches
  # cards through this Canvas tab exactly as before — keeps the default `true`.
  defp tab_served?(assigns, "canvas"), do: Map.get(assigns, :serve_canvas_tab, true)

  defp tab_served?(_assigns, _id), do: true

  # A `<:chat>` SLOT from `call_rail/1` — a list, empty exactly when the
  # caller supplied no slot — or an explicit boolean from a caller that has
  # no slots (see the moduledoc-level note on `served_tabs/1` above).
  defp chat_served?(chat) when is_boolean(chat), do: chat
  defp chat_served?(chat), do: chat != []

  # The tab's ACCESSIBLE name. The unread dot is `aria-hidden`, so without
  # this the state it announces would exist only in pixels and a
  # screen-reader user would be told nothing arrived. Same string the
  # COLLAPSED strip already uses, so the two states of one rail read the
  # same way.
  #
  # Only Chat ever changes name; every other tab's accessible name is its
  # word in every state (the inactive tabs are icon-only, so `aria-label` is
  # the whole of their a11y identity).
  defp tab_name("chat", _label, true), do: "Chat, unread messages"
  defp tab_name(_id, label, _unread), do: label

  @doc """
  The hero-icon class for one tab id (task 01a0740d).

  Exported because the COLLAPSED strip in `meeting_live.html.heex` has no
  labels at all — the icon is the entire visual identity of a tab there,
  so the icon-to-tab mapping stops being private styling and becomes a
  contract two surfaces have to agree on. A second copy in the template
  would be free to drift from whatever the expanded rail grows later.

  Deliberately NO catch-all clause: a NEW entry in `@tabs` must fail
  to compile here rather than render a blank 44px square that the user
  can click but cannot identify. `"chat"` is one of the four (task
  01a084bf stage 1), and its glyph is the same
  `hero-chat-bubble-left-right` the top bar's chat control already uses.

  Glyphs match how the rest of the meeting surface already spells these
  concepts, rather than being picked fresh: `hero-user-group` is the top
  bar's own call-rail toggle, and `hero-squares-2x2` / `hero-document-text`
  are `archive_chip_icon/1`'s canvas and summary icons in `MeetingLive`.
  """
  @spec tab_icon(String.t()) :: String.t()
  def tab_icon("people"), do: "hero-user-group"
  def tab_icon("chat"), do: "hero-chat-bubble-left-right"
  def tab_icon("canvas"), do: "hero-squares-2x2"
  def tab_icon("transcript"), do: "hero-document-text"

  @doc """
  Coerce an arbitrary tab string to one this rail actually renders.

  Public since task 01a0740d: the collapsed strip draws the active-tab
  marker off `@active_meeting_tab`, and `MeetingLive`'s
  `"meeting_tab_select"` handler assigns any binary it is handed. Without
  the same normalisation the expanded pane applies, a junk value would
  leave the strip with NO marker while the rail below it renders People —
  the collapsed state claiming to have forgotten a place it has not
  actually lost.

  An unrecognised tab renders People rather than an empty rail: a stale
  bookmark or a bad param should cost the user the tab they asked for,
  not the whole pane.

  ## The second argument, and why the default is not good enough inside
  ## `call_rail/1` (task 01a084bf stage 4)

  `@tabs` is what the rail knows; `served_tabs/1` is what a given caller
  can fill. Both questions are legitimate — the bug is only ever a
  PRESENTATION asking the first when it needed the second. Coercing to
  `@tabs` is WRONG inside `call_rail/1`, which must land on a tab the
  caller can actually serve.

  THE SENTENCE THAT WAS HERE SAID COERCING TO `@tabs` WAS "right for the
  meeting surface's collapsed strip — that socket serves all four". Both
  halves are now false, and it is corrected rather than deleted because a
  doc that blesses reading the unfiltered list is how the defect comes
  back (01a084bf stage 4 left the same carve-out on `tabs/0`, and stage 1
  of 01a089fe had to withdraw it). The strip stopped coercing to `@tabs`
  in 01a089fe stage 1 — it passes its derived list explicitly — and that
  socket stopped serving all four in stage 3, which gated `<:chat>` on
  `@shell?`. A guest's `/meetings` socket serves three.
  A quickmeet arriving with `active_tab: "chat"` (a stale `?tab=` param, a
  bookmark, or its own `"meeting_tab_select"` handler, which assigns any
  binary) would otherwise select a pane whose button is not in the strip:
  an active pane the viewer cannot navigate away from. Worse, the pane
  `case` in `call_rail/1` has NO catch-all, so an id outside the rendered
  strip is one `CaseClauseError` away rather than one bad pixel away.

  `"people"` is the fallback for both arities and is safe for every
  caller: People is unconditional in `served_tabs/1`, so the fallback can
  never name a tab the strip does not render.
  """
  @spec normalize_tab(term(), [{String.t(), String.t()}]) :: String.t()
  def normalize_tab(tab, tabs \\ @tabs)

  def normalize_tab(tab, tabs) when is_binary(tab) do
    if Enum.any?(tabs, fn {id, _} -> id == tab end), do: tab, else: "people"
  end

  def normalize_tab(_tab, _tabs), do: "people"

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
    doc:
      ~s(one of "people" | "chat" | "canvas" | "transcript"; anything else falls back to people)
  )

  attr(:tab_event, :string,
    required: true,
    doc: "event pushed on tab click, with `phx-value-tab` carrying the tab id"
  )

  attr(:serve_canvas_tab, :boolean,
    default: true,
    doc: """
    Whether this rail carries a Canvas (card board) tab (task 01a0693e).

    TRUE for everyone by default — the in-chat quickmeet and the `/meetings`
    MOBILE sheet both reach the candidate card board through this tab, exactly
    as before. FALSE only for the `/meetings` DESKTOP surface, where the card
    board is now a first-class LEFT rail beside the agents (see
    `meeting_live.html.heex`) and a Canvas tab here would reproduce the
    "buried behind a mislabeled tab" state the prototype alignment removes.

    Read by `tab_served?/2`, so an unserved Canvas tab is genuinely ABSENT
    from the strip AND from `@active`'s coercion — `normalize_tab/2` can never
    land on a pane the strip has no button for.
    """
  )

  attr(:chat_unread, :boolean,
    default: false,
    doc: """
    Whether a message has landed in the bound chat space that the viewer
    has not seen (task 01a084bf stage 4 — FE-5's unresolved V2 case).

    An ATTR, not an assign this component derives, for the same reason
    `active_tab` is: the rail holds no state. `/meetings` passes
    `:call_rail_unread`, which `MeetingLive` raises from a real
    `{:new_message, %Platform.Chat.Message{}}` broadcast and clears when
    the Chat tab becomes active. The quickmeet has no such assign and
    serves no Chat tab, so it passes nothing and the default is false.

    FALSE IS THE ONLY HONEST DEFAULT. A caller that forgets this attr
    must under-report, never invent a dot.
    """
  )

  # ── People pane ──────────────────────────────────────────────────
  attr(:participants, :list, default: [])
  attr(:agents_by_id, :map, default: %{})
  attr(:meeting, :any, default: nil)
  attr(:agent_activity, :any, default: nil)

  attr(:muted_identities, :any,
    default: nil,
    doc: "MapSet of LiveKit identities whose mic is off; passed through to the rail."
  )

  attr(:camera_off_identities, :any,
    default: nil,
    doc: "MapSet of LiveKit identities whose camera is off; passed through to the rail."
  )

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

  attr(:hold_to_talk?, :boolean,
    default: false,
    doc: """
    Forwarded to `ParticipantRail.participant_rail/1`: render a per-agent
    press-and-hold control on every agent row in the People pane. `false`
    — the default — is what the in-chat quickmeet gets (no push-to-talk
    producer) and what `/meetings` passes on DESKTOP, where the left rail
    already carries the controls. `/meetings` passes `true` only below
    `lg`, where the left rail is gone and the People pane is the only
    roster; that keeps exactly one set of controls per viewport.
    """
  )

  attr(:can_remove_agents?, :boolean,
    default: false,
    doc: """
    Forwarded to `ParticipantRail.participant_rail/1` (task 01a0e906 stage
    3): render the host's "Remove from meeting" button on agent rows.
    `/meetings` passes `host?(current_participant, meeting)`; the chat
    quick-meet passes nothing and so renders no button — removal from the
    quick-meet is out of scope.
    """
  )

  attr(:removing_ids, :any,
    default: MapSet.new(),
    doc: "Forwarded to the rail: row ids whose removal is in flight (\"Leaving…\")."
  )

  attr(:removal_errors, :map,
    default: %{},
    doc: "Forwarded to the rail: row id => failed-removal message."
  )

  attr(:hold_to_talk_id_prefix, :string,
    default: "meeting-people-ptt",
    doc: "Forwarded to the rail as `id_prefix` — distinct from the left rail's."
  )

  attr(:pressed_agent_id, :any,
    default: nil,
    doc: "Forwarded to the rail: the agent this viewer is currently holding, or nil."
  )

  attr(:ask_floor_holders, :map,
    default: %{},
    doc: "Forwarded to the rail: agent_id => display_name for every held floor, meeting-wide."
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

  # The rail's FROZEN order while a pointer is over it (task 01a0740e
  # stage 4). `nil` — the default — means "sort live", which is what
  # every caller that has not wired the freeze gets.
  attr(:candidate_order, :list, default: nil)

  # The ten-second undo this socket's own stop left behind (task
  # 01a0740e stage 5), or nil. `nil` — the default — is what the
  # in-chat quickmeet gets: `ChatLive` renders this rail but carries no
  # `stop_candidate` handler, so there is no stop of its own to undo.
  attr(:candidate_undo, :map, default: nil)

  # THE CORRECTION ROSTER, or nil (task 01a0740e stage 2) — the agents a
  # card's correction panel may offer to hand the work to, as
  # `[%{id:, name:}]`.
  #
  # `nil` — the default — is what the in-chat quickmeet gets, and it is
  # what keeps this from becoming a dead button there: `MeetingLive`
  # carries the five `candidate_correct_*` handlers and `ChatLive` does
  # not, so on nil `candidate_rail/1` renders no pencil and no panel and
  # nothing on that surface can push an event it cannot handle. Same
  # posture as `candidate_order` and `candidate_undo` above, for the same
  # structural reason.
  #
  # `[]` is NOT the same as nil: it means "this surface can correct and
  # there is no other agent in the room", which still renders the panel.
  attr(:correction_agents, :list, default: nil)

  # WHICH card has its correction panel open, or nil. Per-socket, like
  # `candidate_undo` — the re-arm the press caused is server state and
  # moves every rail, but the open drawer is local to the reader who
  # opened it.
  attr(:correcting_candidate_id, :string, default: nil)

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

  slot(:chat,
    doc: """
    The typed conversation that runs alongside the call (task 01a084bf).
    A caller fills this with the embedded chat `live_render`.

    SUPPLYING THIS SLOT IS WHAT CREATES THE CHAT TAB (stage 4). See
    `served_tabs/1`: a caller that passes no `:chat` gets a three-up
    strip and no Chat button, because a tab it cannot fill is a button
    that leads nowhere. This is not a fallback, it is the contract.

    MOUNT-ONCE, like `:transcript` and for a harder reason. This slot is
    rendered in a persistent sibling wrapper BELOW the `case @active`,
    never inside a branch of it. A nested `live_render` that is unmounted
    on every tab switch loses the child LiveView, its message stream and
    the reader's scroll position — so the wrapper carries `hidden` and
    stays in the document for as long as the rail lives.
    """
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
    # ONE derivation, used twice. The strip renders `@rail_tabs` and the
    # active tab is coerced against THAT list, not against `@tabs` — see
    # `normalize_tab/2`. Filtering the strip alone would leave a caller that
    # asked for a tab it does not serve sitting on a pane with no button.
    rail_tabs = served_tabs(assigns)

    assigns =
      assigns
      |> assign(:rail_tabs, rail_tabs)
      |> assign(:active, normalize_tab(assigns.active_tab, rail_tabs))

    ~H"""
    <aside
      id={@id}
      class={[
        "flex flex-shrink-0 flex-col border-l border-edge bg-base-200/40",
        @width_class,
        @class
      ]}
      data-component="call-rail"
      data-active-tab={@active}
    >
      <div class="flex border-b border-edge" role="tablist" data-role="call-rail-tabs">
        <button
          :for={{id, label} <- @rail_tabs}
          type="button"
          role="tab"
          phx-click={@tab_event}
          phx-value-tab={id}
          aria-selected={to_string(id == @active)}
          aria-label={tab_name(id, label, @chat_unread)}
          title={if(id == @active, do: nil, else: label)}
          data-role="call-rail-tab"
          data-tab={id}
          data-active={to_string(id == @active)}
          class={[
            "relative flex items-center justify-center px-2 py-2.5 text-[12.5px] transition-colors",
            if(id == @active,
              do: "min-w-0 flex-1 font-semibold text-base-content",
              else: "flex-none font-medium text-base-content/60 hover:text-base-content/80"
            )
          ]}
        >
          <%!-- MEASURED, NOT ARGUED (task 01a084bf stage 1). At 1280x800
               with the rail at its default `w-[312px]`, four equal tabs
               are 78px wide and give each label a 62px content box.
               Measured label widths at 12.5px Public Sans:

                 People 41.70  Chat 28.25  Canvas 43.64  Transcript 60.91

               Transcript clears 62px by a pixel while INACTIVE — and the
               active tab is semibold, which costs it 62.67px. So the one
               tab whose label matters most is the one that clips, and a
               four-up of equal text tabs renders "Transcri…" on the tab
               you are currently reading.

               The brand truncation rule then applies as written: the
               ACTIVE tab keeps its text and takes the leftover width, the
               other three go icon-only. "Transcript" is never abbreviated
               and never shortened to fit — every tab carries the full word
               as its accessible name in every state, so the a11y tree is
               the same four strings whichever tab is selected. Shrinking
               the type to make four labels fit was not on the table: the
               12.5px is the design ruling that the measurement tested. --%>
          <span
            :if={id == @active}
            class="block truncate"
            data-role="call-rail-tab-label"
          >
            {label}
          </span>
          <span
            :if={id != @active}
            class={[tab_icon(id), "size-4"]}
            aria-hidden="true"
            data-role="call-rail-tab-icon"
          >
          </span>
          <%!-- THE UNREAD DOT (task 01a084bf stage 4 — FE-5's V2 case).
               6px (`size-1.5`) round, INLINE and immediately after
               whichever of the two spans above rendered: after the word on
               the active Chat tab, and after the glyph on an inactive one,
               which is the state a viewer actually sees. The dot clears
               when Chat becomes active, so in practice it is only ever
               drawn beside the icon — but hanging it on the icon branch
               alone would make it vanish for one render if the two rules
               ever diverged.

               `shrink-0` so the ACTIVE tab's `truncate` label gives way
               first: the dot must never be what pushes "Transcript" into
               an ellipsis, and a 6px dot plus its margin takes 10px off
               the 200px content box the active tab has spare at 312px.

               `info`, and only `info`: `error`, `success` and `warning` are
               all already spent on this screen (Leave, the live pill, and
               "a human is being asked for something"), and an unread
               message is informational state — not an alarm, not a
               success, not a request. Same slot as the COLLAPSED strip's
               dot, so the two states of one rail agree.

               NO ANIMATION CLASSES WHATSOEVER — no pulse, no fade. A
               blinking dot in peripheral vision during a call is hostile
               and this state is not urgent enough to earn it.

               `:if` rather than an always-present transparent node, so
               ABSENCE is the contract and the node is testable.

               It rides the CHAT tab and nothing else. It is deliberately
               NOT on `data-role="chat-pane-toggle"`: that button's job is
               to COLLAPSE the rail, and hanging "there is something to
               read" on a control that hides things passes a render test
               while pointing the viewer away from the messages. --%>
          <span
            :if={id == "chat" and @chat_unread}
            class="ml-1 size-1.5 shrink-0 rounded-full bg-info"
            aria-hidden="true"
            data-role="call-rail-tab-unread-dot"
          >
          </span>
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
              muted_identities={@muted_identities}
              camera_off_identities={@camera_off_identities}
              now={@now}
              hold_to_talk?={@hold_to_talk?}
              id_prefix={@hold_to_talk_id_prefix}
              pressed_agent_id={@pressed_agent_id}
              ask_floor_holders={@ask_floor_holders}
              can_remove_agents?={@can_remove_agents?}
              removing_ids={@removing_ids}
              removal_errors={@removal_errors}
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
              id={"#{@id}-candidate-rail"}
              candidates={@candidates}
              closed={@candidates_closed}
              events={@candidate_events}
              error={@candidate_error}
              order={@candidate_order}
              undo={@candidate_undo}
              correction_agents={@correction_agents}
              correcting_id={@correcting_candidate_id}
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
          <% "chat" -> %>
            <%!-- NOTHING renders inside the case for Chat, deliberately.
                 The pane is the caller's `:chat` slot and it is mounted
                 unconditionally below, because a branch that unmounts it
                 on People/Canvas/Transcript destroys the nested
                 `live_render` and with it the message stream and the
                 reader's scroll position (task 01a084bf). Necessary, and
                 stage 5 measured that it is not sufficient for the scroll
                 position — see the note on the wrap itself below.

                 This branch used to hold the `data-role="call-rail-chat-empty"`
                 line, gated on `@chat == []`. Stage 4 deleted it, because
                 `@chat == []` means "the CALLER supplied no slot" and
                 stage 4's `served_tabs/1` makes that state unreachable
                 through a rendered Chat tab — a caller with no slot has no
                 Chat button to press. It also was never the state the
                 stage asked about: "a bound chat space with no messages"
                 is a fact only the chat LiveView knows, and it is answered
                 there, by `PlatformWeb.ChatLive.Partials.Composer.message_scroller/1`,
                 which already maintains the readable message count. See
                 that function for the copy and the role name.

                 A clause is still REQUIRED even though it draws nothing:
                 this `case` has no catch-all, so a tab id with no branch
                 raises `CaseClauseError` at runtime rather than failing to
                 compile. --%>
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

        <%!-- The chat pane, mounted ONCE and never unmounted while the rail
             lives (task 01a084bf stage 1). Same shape as the transcript
             wrap above, same reason, one degree worse: this slot carries a
             `live_render` of a NESTED LiveView. Rendering it inside the
             `case` would mean a fresh child process on every return to the
             Chat tab — new stream, no scrollback, cursor at the bottom —
             for the cost of glancing at the roster. So LiveView owns this
             outer div and flips `hidden` on it, and the slot's own DOM is
             never removed.

             KEEPING IT MOUNTED IS NECESSARY AND WAS NOT SUFFICIENT (stage 5).
             Stage 3 shipped this wrap and the behavioural gate then measured
             a reader parked at scrollTop 354 sent to 614 — the bottom — by a
             tab round trip, with the node never unmounted. So the sentence
             above is true and was read as settling more than it does: the
             node surviving buys the message STREAM, and the reader's scroll
             position turned out to be a second question with a second owner.

             `hidden` is not the culprit and is deliberately kept. Measured in
             Chrome 152 over CDP against Tailwind v4.1.12's preflight rule:
             the browser RETAINS the offset across a `display: none` round
             trip and hands it back. What discarded it was `ScrollToBottom`'s
             viewport ResizeObserver recording the hidden pane's 0x0 box and
             then reconstructing the reader's distance from those zeroes. The
             full account, the numbers and the regression tests live in
             `assets/js/hooks/scroll_to_bottom.js` (`_hasMeasurableBox`) and
             `assets/test/scroll_to_bottom_hidden_pane_test.mjs`. Read that
             before changing how this wrap hides — an out-of-flow or
             `visibility`-based rewrite here would fix nothing, because the
             offset was never the browser's to lose.

             `data-active` mirrors the transcript wrap's contract so a
             caller (or a test) can tell "mounted and showing" from
             "mounted and hidden" without reading the `hidden` attribute.

             `:if={@chat != []}` is a CALLER-CONSTANT, not per-tab state
             (stage 4): a caller either supplies the slot for the whole life
             of the rail or never does, so this can never toggle at runtime
             and cannot unmount a live child. A quickmeet, which serves no
             Chat tab, gets no empty wrapper either. --%>
        <div
          :if={@chat != []}
          data-role="call-rail-chat-wrap"
          data-active={to_string(@active == "chat")}
          hidden={@active != "chat"}
          class="flex h-full min-h-0 flex-col"
        >
          {render_slot(@chat)}
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
          class="rounded-box border border-dashed border-edge px-3 py-2.5 text-[11px] leading-relaxed text-base-content/50"
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

  A CONTROL'S WIDTH DOES NOT DEPEND ON ITS OWN STATE (task 01a0773e /
  FE-20). Mic and share change their label word when pressed, and this
  row is `justify-center` inside a box that does not resize, so a
  widening label used to push every sibling outward by HALF the
  widening: +15.7969px on "Mute" -> "Unmute" moved the other three
  controls 7.8906px, and +38.9531px on "Share" -> "Stop sharing" moved
  them 19.4844px. Both toggling labels now reserve their widest word
  via `toggling_label/1` below, so every rect on this row is fixed
  across every state. If you add a fifth control whose label changes,
  give it `toggling_label/1` too; a plain `.call-control-label` with an
  `if` in it reintroduces the defect.

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
    `/meetings` used to pass its push-to-talk button here (task
    01a03f4e stage 5, re-homed in the merge with #910); push-to-talk
    moved to the participant rail (per-agent hold-to-talk) and this
    slot now carries `/meetings`' captions toggle instead (task
    01a0cf5d stage 2, relocated from the top bar). The quickmeet has
    no captions producer and passes nothing. A slot rather than an
    attr because the button carries its own event handling and state,
    none of which this component should know about.
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
        class="btn btn-sm rounded-field gap-2 border-edge bg-base-200 font-normal text-base-content/80"
      >
        <span
          class={["size-4", if(@mic_on, do: "hero-microphone", else: "hero-microphone-slash")]}
          aria-hidden="true"
        >
        </span>
        <.toggling_label on={@mic_on} when_on="Mute" when_off="Unmute" />
      </button>

      <button
        type="button"
        phx-click={@camera_event}
        data-role={@camera_role}
        data-active={to_string(@camera_on)}
        data-on={to_string(@camera_on)}
        aria-pressed={to_string(!@camera_on)}
        aria-label={if @camera_on, do: "Turn camera off", else: "Turn camera on"}
        class="btn btn-sm rounded-field gap-2 border-edge bg-base-200 font-normal text-base-content/80"
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
        class="btn btn-sm rounded-field gap-2 border-edge bg-base-200 font-normal text-base-content/80"
      >
        <span class="hero-arrow-up-tray size-4" aria-hidden="true"></span>
        <.toggling_label on={@sharing} when_on="Stop sharing" when_off="Share" />
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

  attr(:on, :boolean, required: true)
  attr(:when_on, :string, required: true)
  attr(:when_off, :string, required: true)

  @doc false
  # A label whose WORD changes with state, rendered so its WIDTH does
  # not (task 01a0773e / FE-20).
  #
  # Both words are always in the box, stacked in one grid cell, with
  # the inactive one held by `visibility: hidden` — hidden boxes still
  # take part in layout, so the label sizes to the wider of the two in
  # BOTH states. See `app.css`, which owns the stacking.
  #
  # WHY THIS AND NOT A `min-width`. `.call-control-label` is shared by
  # all four controls and each toggling pair has a different wider
  # word: "Unmute" for mic, "Stop sharing" for share, measured at
  # 44.4219px and 71.5313px. One constant cannot be right for both,
  # and picking either is wrong SILENTLY — the row stops moving on
  # mute and keeps moving on share. There is no number in this
  # mechanism, so it stays correct when a label is reworded.
  #
  # WHY NOT A ROW-LAYOUT FIX (fixed grid tracks, or dropping
  # `justify-center`). That stops the SIBLINGS moving, which is the
  # 7.8906px in the bug report, but the pressed control still changes
  # width inside its own track, so its glyph still slides out from
  # under the finger that pressed it. Mute is the button people press
  # twice in a row. It would also break the two quickmeet assertions
  # that this bar keeps `justify-center`.
  #
  # ONE `.call-control-label` PER CONTROL, words nested inside it.
  # `partials_meeting_panel_test.exs` asserts the quickmeet bar
  # contains exactly four of them, because that class is what the
  # narrow-bar container query keys on; a second span carrying it per
  # control would read as six controls' worth of labels.
  defp toggling_label(assigns) do
    ~H"""
    <span class="call-control-label">
      <span class="call-control-label-word" data-shown={to_string(@on)}>{@when_on}</span>
      <span class="call-control-label-word" data-shown={to_string(!@on)}>{@when_off}</span>
    </span>
    """
  end

  # `normalize_tab/1` moved to the top of this module and became public
  # in task 01a0740d — the collapsed strip needs the same coercion. Its
  # clauses had to travel with it: Elixir warns (and `mix precommit`
  # runs `--warnings-as-errors`) on clauses of one function split apart.
end
