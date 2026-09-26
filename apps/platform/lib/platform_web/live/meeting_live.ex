defmodule PlatformWeb.MeetingLive do
  @moduledoc """
  Meetings module — staged collaboration surface (ADR 0042).

  This LiveView ships the layout shell for the meeting surface plus
  this stack member's deliverable: the **stage-mode switcher** with
  Canvas / Screen / Gallery / Whiteboard renderers in the center stage.

  The right pane embeds the canonical `PlatformWeb.ChatLive` surface in
  its `embedded: true` mode (stage 5 of task 019e2d1a; replaced the
  earlier `MeetingChatPanelLive` stub from the 019e2475-87a8 sibling).
  See "Embedding choice" below.

  ## Stage modes (this stack member)

  Four modes per ADR 0042's "Stage modes" table, surfaced via the
  segmented control in the top bar:

    * `:canvas`     — renders the most-recently-created canvas in the
                      meeting's chat space, or an empty-state CTA that
                      creates one.
    * `:screen`     — attaches the active LiveKit screen-share track via
                      the `MeetingScreenShare` JS hook into
                      `[data-screen-share-slot]`. Empty-state CTA pushes
                      `toggle-screen-share` to any `MeetingClient` hook
                      mounted on the page.
    * `:gallery`    — one tile per human participant in a responsive
                      grid via the shared `<.video_tile>` component.
                      Agents are excluded (they live in the bottom strip).
                      Default mode (the meeting opens face-first; the
                      bottom strip is hidden in gallery so the grid owns
                      the full vertical space).
    * `:whiteboard` — placeholder card; the real drawing surface is a
                      separate stack and lands later.

  Switching is pure presentation: flipping `:current_stage_mode` swaps
  which renderer the center stage shows, but the other modes' underlying
  state (canvas LV state, the LiveKit Room on `window.__livekit_room`,
  participant subscriptions) is untouched.

  ## Embedding choice (stage 5 of 019e2d1a — Option A)

  Stage 5 swapped the ~150-line `MeetingChatPanelLive` stub for the
  canonical `PlatformWeb.ChatLive` surface in its new `:embedded` mode.
  The stub had only messages + composer; embedding ChatLive lights up
  @mentions, attachments, reactions, threading, message editing, link
  previews, and canvas embeds inside the meeting pane — the same
  affordance set as `/chat/<slug>`.

  How embedded mode works (see ChatLive `mount/3` + chat_live.html.heex
  `:if={!@embedded}` gates):

    * The session passed to `live_render` carries
      `{"chat_space_slug" => …, "embedded" => true, "current_user_id"
      => …}`. URL params don't flow to a `live_render`d child, so
      ChatLive's `mount/3` does the same setup `handle_params/3` does
      for the slug path (active_space, current_participant, message
      stream, mentions / pins / canvases / agents).
    * Sidebar, mobile pills, mobile browser overlay, the desktop chat
      header, settings / new-channel / new-conversation modals, the
      meeting mini-bar, and the duplicate JS-hook anchors are all
      suppressed in the embed via `:if={!@embedded}`.
    * MeetingHooks are NOT attached on the embedded surface — the
      parent MeetingLive already owns the LiveKit lifecycle, and a
      second hook attach would double-subscribe to room presence.

  Render call:

      <%= live_render(@socket, PlatformWeb.ChatLive,
            id: "meeting-chat-panel-\#{@meeting.id}",
            session: %{
              "chat_space_slug" => @meeting.chat_space.slug,
              "embedded" => true,
              "current_user_id" => @user_id
            }) %>

  The `data-intent-panel-host="true"` marker survives on the wrapping
  `<div>` around the `live_render` so future-Rowan can still grep for
  the migration site when the real intent panel ships.

  ## Layout

    * Top bar: meeting name + 4-button stage-mode segmented control
      (THIS task).
    * Left rail (~240px): PLACEHOLDER slot for sibling 019e2475-4395's
      sectioned participant list.
    * Center stage (flex-1): stage-mode renderers (THIS task).
    * Bottom strip (~120px): PLACEHOLDER slot for sibling 019e2475-0037's
      video tiles.
    * Right pane: the embedded `PlatformWeb.ChatLive` surface (stage 5
      of 019e2d1a; was `MeetingChatPanelLive`).

  ## The discussion is a rail pane, not a drawer (task 01a084bf stage 3)

  There used to be a standalone chat `<aside id="meeting-chat-drawer">`
  here with its own two presentations and its own `:chat_panel_open`
  assign. It is deleted, and with it that assign.

  It had to go because its class list ended in an unconditional
  `lg:!hidden`: from `lg` up there was no readable discussion surface on
  this screen at all, so the top bar's toggle and the collapsed strip's
  Chat button both flipped state — and cleared the unread dot — against a
  `display: none` element. Task 01a0740d reported that as a known defect
  it declined to paper over.

  The single `PlatformWeb.ChatLive.Embedded` `live_render` now lives in the
  `<:chat>` slot of `CallShell.call_rail/1`, so it inherits the RAIL's two
  presentations instead of maintaining a second set:

    * `>=lg` — an in-flow right column, 312px expanded, collapsing to a
      44px icon strip under `:chat_panel_collapsed`.
    * `<lg` — a bottom sheet (`PlatformWeb.Components.Sheet`, framed by
      `PlatformWeb.Components.Meetings.CallRailFrame`), latched by
      `:call_rail_open`, whose SHUT handle carries `:soonest_candidate`'s
      countdown (task 01a07410 stage 3). The right slide-in drawer this
      used to be, and its backdrop, are retired. Which frame renders is
      decided by `:mobile_viewport?`, reported by the `ViewportBreakpoint`
      hook.

  `"toggle_chat_panel"` survives as the event the top bar pushes, but it
  now OPENS that rail on the Chat tab rather than toggling a drawer.

  ## Routes

    * `/meetings`         — `:index` action. Lightweight placeholder
      index so the sidebar nav link resolves.
    * `/meetings/:slug`   — `:show` action. The meeting shell.

  ## Mount + assigns (`:show`)

    * `:meeting` — the `%Platform.Meetings.Meeting{}` loaded by slug,
      with `:chat_space` preloaded (the panel needs the chat space's
      `slug` to drive `live_render`).
    * `:current_stage_mode` — one of `:canvas`, `:screen`, `:gallery`,
      `:whiteboard` (see `stage_modes/0`), default `:gallery`. The bottom
      strip is hidden while in gallery (the grid is the full face-grid);
      switching to canvas/screen/whiteboard reveals the strip as a
      compact horizontal row.
    * `:participants` — `Platform.Chat.list_participants/1` for the
      meeting's bound chat space; drives the Gallery-mode tile grid
      and the participant-rail placeholder.
    * `:meeting_canvas` — the RESOLVED canvas: the viewer's explicit
      `:selected_canvas_id` when it still names a live canvas, otherwise
      the default from `latest_canvas/1`. Canvas mode and the canvas tile
      both render this. May be `nil` when the space has no canvas.
    * `:meeting_canvases` — every non-deleted canvas in the meeting's
      chat space (`Chat.list_canvases/1`, oldest-first). Drives the
      canvas picker and is the CLAMP SET for `canvas_open`.
    * `:selected_canvas_id` — the viewer's explicit pick, or `nil` for
      "no pick yet, use the default". **A per-socket assign, exactly like
      `:captions_visible`** — never persisted to a shared row and never
      broadcast. That is structural, not a convention: with the choice
      living only in this LiveView's own state, one participant's pick is
      INCAPABLE of moving another participant's view. A shared column
      would make the yank possible and leave "don't broadcast it" as the
      only thing preventing it.
    * `:canvas_seen_revisions` — `%{canvas_id => revision}`: the document
      revision each canvas carried the last time THIS viewer had it in
      view. A canvas whose current revision is greater, or that has no
      entry at all, is CHANGED and wears a dot in the picker. Per-socket
      for the same structural reason as `:selected_canvas_id`.

      The baseline is seeded at mount from every loaded canvas, so the
      list opens clean and a dot means strictly "this changed while you
      were in this meeting". The absent-entry case then falls out of the
      same rule rather than needing its own: a canvas that arrives DURING
      the session was never part of your baseline, so it is news.
    * `:user_id` — authenticated user_id off the session (same pattern
      as ChatLive); used as the canvas-creator participant when the
      Canvas-mode "Create canvas" CTA fires.
    * `:active_meeting_tab` — which pane the right rail renders. `"chat"`
      is one of the four (task 01a084bf stage 1), which is why there is no
      longer a `:chat_panel_open`: "is the discussion on screen" is now a
      question about this assign and `:chat_panel_collapsed`, answered by
      `chat_on_screen?/1`.
    * `:chrome_mode` — one of `:shell` (default, used by the authenticated
      `/meetings/:slug` surface) or `:none` (used by the guest ingress on
      the `meet.` host). Driven by `session["chrome_mode"]`, which the
      `:guest_meeting` `live_session` block in the router injects as the
      string `"none"`. Stage 1 of task 019f498d landed the plumbing;
      stage 3 wires the guest-invite mount branch (see the `mount/3` head
      clause matching `chrome_mode: "none"`); stage 4 gates chrome regions
      in the heex; stage 5 retired the legacy standalone guest LV so
      MeetingLive is the single source of truth for both surfaces.
    * `:shell?` — convenience boolean, `true` when `:chrome_mode == :shell`.
      Same task/stage semantics as `:chrome_mode`.
    * `:state` — guest ingress state (task 019f498d stage 3), ONLY assigned
      when `chrome_mode == :none`. One of `:expired`, `:invalid`,
      `:unavailable`, `:name_entry`, `:in_meeting`. Absent in the shell
      path; the heex cond in stage 4 branches on
      `chrome_mode == :none and state == …` to render the guest
      sub-surfaces. `:unavailable` (task 019f9cb7 stage 2) is the
      OPERATIONAL failure state — our media plane could not admit a guest
      whose invite verified fine — and is deliberately distinct from
      `:invalid`, which is a claim about the guest's link.
    * `:unavailable_kind` — `:permanent` or `:unknown` (task 01a04353).
      Assigned ONLY alongside `:state == :unavailable`, by
      `guest_mint_failure/3`, which is that state's single writer. Decides
      whether the card offers a retry: `:permanent` does not, because
      neither fault it covers today (an unconfigured media plane, a
      meeting with no chat space) can resolve while the guest waits.

  ## PubSub (`:show`)

  On connect the LV subscribes to:

    * the meeting's bound chat-space topic via `Platform.Chat.PubSub` —
      roster events drive the Gallery grid + participant rail; canvas
      events latch new canvases into the Canvas-mode renderer.
    * `meeting:{id}` — a per-meeting topic for meeting-level lifecycle
      events. INTEGRATION POINT: sibling task 019e2474-11c1 owns the
      authoritative meeting PubSub helper; until it lands, the topic
      string is defined locally here (`meeting_topic/1`).
    * `meeting:{id}:intents` — the per-meeting intent-queue event stream
      (task 019f70b8 stage 7) feeding the `.intents-collapse` bar.
    * `roles:assignments` — so a `meeting_producer` appointed mid-meeting
      gets the (DOM-absent) intents bar without a page reload.

  ## The intents-collapse bar (task 019f70b8 stage 7)

  Rendered as a sibling ABOVE the embedded chat LV inside the right
  rail, so the producer sees the queue and the discussion at once. The
  whole strip — and the expanded table — is `:if`-gated on
  `@intents_visible?`, which is `Platform.Roles.agent_id_for_role("meeting_producer")`
  resolved ONCE at mount into an assign. Unassigned means **absent from
  the DOM**, not hidden with CSS: an unfilled capability is not a denial,
  and there is nothing to reserve layout space for.

  The gate is re-checked in every mutating handler, not only in the
  template. A `phx-click` is a client-supplied message; a template-only
  gate would be a suggestion.
  """
  use PlatformWeb, :live_view

  require Logger

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]
  import PlatformWeb.Components.Canvases.CanvasExplorer, only: [canvas_explorer: 1]
  import PlatformWeb.Components.Meeting.VideoTile, only: [video_tile: 1]

  alias PlatformWeb.Components.Meetings.CallRecap
  alias PlatformWeb.Components.Meetings.CallShell
  alias PlatformWeb.Components.Meetings.CallRailFrame
  alias PlatformWeb.Components.Meetings.CandidateRail
  alias PlatformWeb.Components.Meetings.ParticipantRail

  import PlatformWeb.Components.Meetings.CallRailFrame, only: [rail_frame: 1]

  import PlatformWeb.Components.Meetings.IntentsCollapse,
    only: [intents_collapse: 1, intents_overlays: 1]

  import PlatformWeb.Components.Meetings.InviteControl,
    only: [invite_control: 1, invite_list: 1]

  import PlatformWeb.Components.Meetings.MeetingDetail,
    only: [meeting_detail_body: 1, meeting_detail_actions: 1]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Attachments.ToolHandlers, as: AttachmentHandlers
  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasDocument
  alias Platform.Meetings
  alias Platform.Meetings.Archive
  alias Platform.Meetings.AskFloor
  alias Platform.Meetings.CandidateEvents
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PressCard
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.Room
  alias Platform.Meetings.SenderSeed
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks
  alias Platform.Tenancy
  alias PlatformWeb.ChatLive.MeetingHooks
  alias PlatformWeb.Components.Meetings.IntentsCollapse
  alias PlatformWeb.MeetingLive.CalendarWindow
  alias PlatformWeb.PublicSite
  alias PlatformWeb.SpaceTopics

  # The role that may see and drive the intents-collapse bar. Passed to
  # `Platform.Roles.agent_id_for_role/1` as a STRING — that function is
  # guarded `when is_binary(role_key)` and an atom raises
  # FunctionClauseError.
  @intent_producer_role "meeting_producer"

  # The nine per-meeting intent-queue events. Every one carries the FULL
  # row map, so a subscriber can render without a second lookup.
  #
  # `:intent_delivered` (task 019ff292 stage 2) is the only one that is
  # not a status change: the row stays `:dispatched` and what moved is
  # `delivered_at`, the instant the responder's ack window is anchored
  # to. It still has to be listed here — the catch-all below would
  # swallow it, and the strip would keep counting from a transmission
  # the responder never saw.
  @intent_events [
    :intent_classified,
    :intent_dispatched,
    :intent_delivered,
    :intent_acked,
    :intent_completed,
    :intent_cancelled,
    :intent_timed_out,
    :intent_dispatch_failed,
    :intent_no_ack_spawn_failed
  ]

  # Events that resolve a pending cancel: the row reached a terminal
  # state, so the "Cancelling" affordance has an answer and comes off.
  @cancel_resolving_events [
    :intent_completed,
    :intent_cancelled,
    :intent_timed_out,
    :intent_dispatch_failed,
    :intent_no_ack_spawn_failed
  ]

  @doc "The role key gating the intents-collapse bar."
  def intent_producer_role, do: @intent_producer_role

  @doc "The nine per-meeting intent-queue event names the LV handles."
  def intent_events, do: @intent_events

  # Stage modes per ADR 0042's "Stage modes" table. Canvas is the default
  # (meetings are often artifact-driven).
  @stage_modes [:canvas, :screen, :gallery, :whiteboard]

  @doc "Stage modes the segmented control exposes (ADR 0042)."
  def stage_modes, do: @stage_modes

  @doc """
  Whether the right rail starts COLLAPSED for a given stage mode (task
  01a0740d).

  The rail's collapse default follows what the stage is showing: gallery is
  the only mode where the stage is not competing for the pixels, so it is
  the only mode that opens the rail. Screen share, canvas and whiteboard are
  full-stage surfaces and open collapsed.

  **ONE CLAUSE PER MODE AND DELIBERATELY NO CATCH-ALL.** A fifth stage mode
  added to `@stage_modes` must fail to compile here rather than silently
  inheriting whichever default a fallthrough happened to name — that exact
  fallthrough shape (`AgentActivity`'s `meta(_)`) has already shipped a wrong
  default on this surface once.

  Public rather than private because `PlatformWeb.ChatLive.MeetingHooks` has
  to reassert the same default on the screen-share auto-switch: that hook
  returns `:halt`, so on `/meetings` it — not this module — is the path a
  share-start actually takes. Two copies of the table would be two answers.
  """
  @spec default_rail_collapsed?(:canvas | :screen | :gallery | :whiteboard) :: boolean()
  def default_rail_collapsed?(:gallery), do: false
  def default_rail_collapsed?(:screen), do: true
  def default_rail_collapsed?(:canvas), do: true
  def default_rail_collapsed?(:whiteboard), do: true

  # How long the canvas tile's just-changed highlight stays on before the
  # LV clears it. Long enough to notice on a glance back at the grid,
  # short enough that it does not become permanent chrome.
  @canvas_changed_ms 6_000

  # Rows per page in the canvas-mode picker's `CanvasExplorer` group. Matches
  # that component's own default page size on purpose — see
  # `ChatLive.CanvasHooks`'s identical constant and comment: the component
  # takes at most `page_size` of whatever `rows` it is handed, so a slice
  # LARGER than this would load rows nothing renders, and a smaller one
  # would make the pager offer a next page that repeats rows already shown.
  @canvas_explorer_page_size 20

  # ── New-meeting sheet: duration options and refusal copy ─────────────────
  #
  # The durations the sheet offers, in minutes, and the one it opens on.
  # The submit handler validates against this exact list rather than a
  # range, so a value the select never rendered is refused instead of
  # scheduling a meeting nobody asked for.
  @duration_options [15, 30, 45, 60, 90, 120]
  @default_duration_minutes 30

  @schedule_pair_error "Date and start time are required together."
  @no_time_zone_error "Time zone unavailable — reload to pick a time."
  @invalid_time_error "Date and start time are invalid."
  @nonexistent_time_error "That time does not exist on that date."
  @invalid_duration_error "Duration is invalid."

  @doc "Durations, in minutes, the new-meeting sheet offers."
  def duration_options, do: @duration_options

  @doc "The duration, in minutes, the new-meeting sheet opens on."
  def default_duration_minutes, do: @default_duration_minutes

  @doc "Human label for one of `duration_options/0`."
  def duration_label(minutes) when minutes < 60, do: "#{minutes} min"
  def duration_label(60), do: "1 hr"
  def duration_label(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} hr"
  def duration_label(minutes), do: "#{div(minutes, 60)} hr #{rem(minutes, 60)} min"

  @impl true
  # Guest ingress mount (task 019f498d stage 3, wired to the real route
  # in stage 5). The `:guest_meeting` live_session on the `meet.` host
  # scope injects `chrome_mode: "none"` into the session; the guest URL
  # carries `slug` + `token` in the path. This clause resolves the invite
  # through `Meetings.resolve_guest_invite/2` (extracted in stage 2) and
  # lands one of four states: `:expired`, `:invalid`, `:name_entry`, or
  # `:in_meeting`. `enter_meeting_as_guest/3` can subsequently divert
  # `:in_meeting` to `:unavailable` or back to `:name_entry` when the
  # LiveKit mint fails — see `guest_mint_failure/3`.
  #
  # In `:in_meeting` we mint the LiveKit bundle, seed the media-state
  # assigns via `MeetingHooks.attach_guest/1` (a guest-safe variant that
  # skips the user_id-dependent writes since `:user_id = nil` here), and
  # push `join-meeting` with the same payload shape the authenticated
  # `MeetingClient` consumes (built by
  # `Meetings.guest_join_event_payload/2`).
  #
  # `handle_params/3` no-ops when `chrome_mode == :none` (see the head
  # guard on the shell clause below) so this mount is the only place
  # meeting-specific state is seeded for the guest surface.
  def mount(
        %{"slug" => slug, "token" => token} = _params,
        %{"chrome_mode" => "none"} = _session,
        socket
      ) do
    socket =
      socket
      |> PlatformWeb.GameStreamHooks.attach()
      |> assign(:user_id, nil)
      |> assign(:chrome_mode, :none)
      |> assign(:shell?, false)
      |> assign(:stage_modes, @stage_modes)
      # Mobile-drawer open-state for the CALL RAIL (task 01a05b14 stage
      # 6). Orthogonal to `:chat_panel_collapsed`, which is the desktop
      # affordance. Before this the rail was `hidden lg:flex` and stage 5
      # measured it at `width: 0` on a 390px viewport — People and Canvas
      # simply did not exist on a phone, on either surface. A target that
      # only exists above `lg:` is not the target that was approved.
      |> assign(:call_rail_open, false)
      # Which side of `lg` the viewport is on, per the `ViewportBreakpoint`
      # hook (task 01a07410 stage 3). `false` — the desktop wrapper —
      # until the client reports; see `CallRailFrame`.
      |> assign(:mobile_viewport?, false)
      # The after-call recap (task 01a07410 stage 6). `nil` until the
      # viewer LEAVES a call; see `attach_call_recap_hook/1`.
      |> assign(:call_recap, nil)
      |> assign(:chat_panel_collapsed, false)
      # Rail width animation + unread flag (task 01a0740d). See the
      # matching pair in the general `mount/3` below for the reasoning;
      # both mount sites seed them so no path renders with the key absent.
      |> assign(:call_rail_animate, false)
      |> assign(:call_rail_unread, false)
      |> assign(:active_meeting_tab, "people")
      |> assign(:captions_visible, false)
      |> assign(:speaking_identities, MapSet.new())
      |> assign(:muted_identities, MapSet.new())
      |> assign(:camera_off_identities, MapSet.new())
      |> seed_intent_assigns()
      |> assign_calendar_time_zone()
      |> seed_calendar_now()
      |> assign(:meeting_slug, slug)
      |> assign(:token, token)
      # Task 01a08d5a stage 3: the key `MeetingHooks.attach_guest/1` seeds
      # committed mic/camera intent from across a reconnect mount. Derived
      # from the INVITE token (the URL, which is what a reconnect arrives
      # with) — `:token` is overwritten with the LiveKit token on entry.
      |> assign(:guest_intent_key, Platform.Meetings.State.guest_intent_key(token))

    case Meetings.resolve_guest_invite(slug, token) do
      {:error, :expired} ->
        {:ok,
         socket
         |> assign(:page_title, "This invite has expired")
         |> assign(:state, :expired)
         |> assign(:meeting, nil)
         |> seed_guest_index_fallback_assigns()}

      # `:revoked` (task 019fb954) renders as `:invalid` deliberately —
      # one rendered outcome, no new template branch. A guest whose link
      # was revoked is told it does not work; telling them it *used to*
      # would confirm the meeting exists to someone the host just cut off.
      {:error, reason} when reason in [:invalid, :revoked] ->
        {:ok,
         socket
         |> assign(:page_title, "Invite link is not valid")
         |> assign(:state, :invalid)
         |> assign(:meeting, nil)
         |> seed_guest_index_fallback_assigns()}

      {:ok, %{state: :name_entry, meeting: meeting}} ->
        # `:name_entry` seeds the same shell-tree assigns the `:in_meeting`
        # path uses so the top-level `:state`-branch cond (stage 4) can
        # short-circuit before touching any keys the meeting shell reads.
        # No LiveKit bundle is minted here — the guest hasn't confirmed
        # their name yet. `:display_name` is nil until `submit_name` lands.
        {:ok,
         socket
         |> assign(:page_title, "Join #{meeting.name}")
         |> assign(:state, :name_entry)
         |> assign(:name_error, nil)
         |> assign(:name_value, "")
         |> assign(:display_name, nil)
         |> seed_guest_shell_tree_assigns(meeting)}

      {:ok, %{state: :in_meeting, meeting: meeting, display_name: display_name}} ->
        {:ok, enter_meeting_as_guest(socket, meeting, display_name)}
    end
  end

  def mount(_params, session, socket) do
    # Pull the authenticated user_id off the session (same pattern as
    # ChatLive). Used to resolve a `current_participant` in the meeting's
    # bound chat space when an interaction (e.g. "Create canvas") needs an
    # author. Falls back to a generated UUID for anonymous test paths so
    # the LV stays mountable even without a session — tests that exercise
    # canvas creation set `current_user_id` explicitly.
    user_id = session["current_user_id"] || Ecto.UUID.generate()

    # Chrome-mode wiring (task 019f498d stage 1). The `:guest_meeting`
    # live_session on the `meet.` host scope injects `"chrome_mode" =>
    # "none"` into the session; the default authenticated `/meetings`
    # surface leaves it absent, which normalizes to `:shell`. Stage 1 is
    # additive-only — no render or lifecycle code branches on these
    # assigns yet. Stage 3 wires guest-invite mount branching, stage 4
    # gates chrome regions, stage 5 flips the `meet.` route to this LV.
    chrome_mode = normalize_chrome_mode(session["chrome_mode"])

    {:ok,
     socket
     # Seed the `chat:space:<id>` holder map from THIS view's own mount (task
     # 01a02c4e stage 3). On the `:meet_member` and `:authenticated` routes
     # `ShellLive`'s `on_mount` hook has already seeded it and this is a no-op
     # — `ensure_holders/1` is idempotent and never discards live holders. On
     # any route without that hook, MeetingLive has to seed it itself.
     # `hold/3` seeds internally too, but the explicit call keeps the assign
     # present for a render that reads it before any hold is taken.
     |> SpaceTopics.ensure_holders()
     # Canvas tiles can hold a `game_stream` node, whose hook pushes events
     # here (task 01a0db5f stage 4). Inert while GAME_STREAM_ENABLED is unset.
     |> PlatformWeb.GameStreamHooks.attach()
     |> assign(:user_id, user_id)
     |> assign(:chrome_mode, chrome_mode)
     |> assign(:shell?, chrome_mode == :shell)
     |> assign(:stage_modes, @stage_modes)
     # Stage 4 seed. The top-level heex cond branches on `@state` and
     # `{@display_name}` interpolates the guest badge in `chrome_mode: :none`.
     # The shell path never sets these — assign nil defaults here so the
     # template compiles under both modes without KeyErrors when the render
     # scans the cond's guard tuples.
     |> assign(:state, nil)
     # Task 019fb955-f8b1 stage 5: the `:meet_member` live_session reaches
     # THIS clause with `chrome_mode: :none` and a real signed-in account,
     # so `:display_name` has to name that account — the member identity
     # badge interpolates it. Read off `:current_user_record`, which
     # `ShellLive.on_mount(:default)` has already assigned (on_mount hooks
     # run before `mount/3`). Stays nil on the shell surface, which renders
     # no badge, and nil for the `Ecto.UUID.generate()` anonymous-test
     # fallback above, where there is no account to name.
     |> assign(:display_name, member_display_name(socket.assigns[:current_user_record]))
     # Desktop collapse state for the call rail (task 019e40f2).
     # `:chat_panel_open` — the retired chat drawer's `<lg` latch — used to
     # sit here and be described as orthogonal to this one. The drawer is
     # gone (task 01a084bf stage 3) and so is that assign; the `<lg`
     # equivalent for the rail is `:call_rail_open`, assigned just below.
     # `:chat_panel_collapsed` flips the desktop rail between
     # the wide 312px pane and a slim 44px collapsed strip. Same
     # default-expanded posture as `:sidebar_collapsed` in
     # `shell_live.ex` — first-time users see the full layout. The
     # `SidebarCollapse` JS hook (parameterized via `data-*` attrs in
     # stage 3) hydrates from localStorage so the preference survives
     # navigation + reload.
     |> assign(:chat_panel_collapsed, false)
     # Snap-vs-animate for the rail's WIDTH change (task 01a0740d, per
     # Saru's design canvas 01a08374). `true` only when the viewer moved
     # the rail themselves via the chevron; `false` on every mode-driven
     # reassert, so switching to screen share does not slide a slab of
     # the screen at someone whose attention is on the stage. Motion
     # should say "you", never "it". FALSE AT MOUNT is not incidental —
     # a first paint must never animate.
     |> assign(:call_rail_animate, false)
     # Unread marker for the discussion drawer (task 01a0740d). Raised by
     # the `{:new_message, _}` clause below when a message lands on this
     # meeting's chat space while the drawer is CLOSED, cleared when the
     # drawer is opened. Collapsing the rail must not silently hide that
     # something happened, and until this ticket the meeting surface had
     # no unread plumbing of any kind.
     |> assign(:call_rail_unread, false)
     # Mobile-drawer open-state for the CALL RAIL (task 01a05b14 stage
     # 6). Orthogonal to `:chat_panel_collapsed`, which is the DESKTOP
     # affordance. Before this the rail was `hidden lg:flex` and stage 5
     # measured it at `width: 0` on a 390px viewport — People, Canvas
     # and Transcript simply did not exist on a phone, on either
     # surface. A target that only exists above `lg:` is not the target
     # that was approved.
     |> assign(:call_rail_open, false)
     # Seeded at BOTH mounts, like `:call_rail_open`: the wrapper the rail
     # renders in is decided from this on every render (task 01a07410
     # stage 3, `CallRailFrame`).
     |> assign(:mobile_viewport?, false)
     # Seeded at both mounts like `:mobile_viewport?` (task 01a07410
     # stage 6): the recap renders off this on every render.
     |> assign(:call_recap, nil)
     # Right-rail tab (task 01a05b14 stage 3). `CallShell.call_rail`
     # holds no state of its own so each surface owns its own assign;
     # `"people"` is the default because humans and agents are what the
     # rail exists to show.
     |> assign(:active_meeting_tab, "people")
     # Closed-captions toggle for the meeting surface (task 019f3f17
     # stage 1). Originally distinct-named from a shell `toggle_captions`
     # handler (removed by task 019f43da) — the shell had swallowed clicks
     # via `attach_hook(:handle_event, ...)` before MeetingLive saw them.
     # The shell captions button + overlay + `:captions_enabled` assign
     # are gone; MeetingLive is now the sole writer of caption state.
     # Kept the `_meeting` suffix on the event name to avoid rebase churn
     # in tests + the MeetingCaptions JS hook. Default OFF per the task
     # spec; a viewer preference is mirrored to localStorage by the
     # MeetingCaptions JS hook and restored via `meeting_captions_hydrate`.
     |> assign(:captions_visible, false)
     # Active-speaker identities reported by THIS viewer's LiveKit client
     # (`MeetingRoom._onActiveSpeaker` -> `active_speakers`). VIEWER-LOCAL
     # for the same reason `:captions_visible` is: never persisted, never
     # broadcast over PubSub. Each viewer's own client is the authority on
     # what it is hearing.
     |> assign(:speaking_identities, MapSet.new())
     # Per-identity mic/camera state observed by THIS viewer's LiveKit
     # client (`MeetingClient._pushMediaStates` -> `media_states`).
     # VIEWER-LOCAL on the same terms as `:speaking_identities` above:
     # never persisted, never broadcast. `:camera_off_identities` has no
     # reader on the tile (the avatar fallback already IS the camera
     # indicator); the stage-3 roster is what consumes it.
     |> assign(:muted_identities, MapSet.new())
     |> assign(:camera_off_identities, MapSet.new())
     # Intents-collapse bar defaults (task 019f70b8 stage 7). Seeded in
     # BOTH mount clauses so the `:index` action and the guest surface
     # render without a KeyError even though neither shows the bar.
     # `handle_params/3` resolves the real values for the `:show` action.
     |> seed_intent_assigns()
     |> assign_calendar_time_zone()
     |> seed_calendar_now()}
  end

  # Seed the index-mode defaults so the current heex (which falls through
  # to the `:else` index branch when `@meeting == nil`) doesn't crash
  # on a bare guest failure state. Stage 4 will add a `:state`-branch cond
  # so `:expired` / `:invalid` render their own cards and this fallback
  # becomes dead code — but keeping it lets stage 3 land as a compilable,
  # renderable-without-crash unit even before stage 4 lands. Values are
  # empty defaults; no data leaks into the guest surface's DOM.
  defp seed_guest_index_fallback_assigns(socket) do
    socket
    # The single outbound action on every guest FAILURE card (expired,
    # invalid, unavailable) — all three route through here. Both assigns
    # are `nil` unless `PUBLIC_SITE_HOST` is configured, and the cards
    # gate the whole `card-actions` block on that nil (task 01a04352).
    # No default host: this repo is public, and a baked-in one points a
    # different deployment's guests at somebody else's company.
    |> assign(:public_site_url, PublicSite.url())
    |> assign(:public_site_host, PublicSite.display_host())
    |> assign(:meetings, [])
    |> assign(:grouped_meetings, %{live: [], upcoming: [], ended: []})
    # `false`, not `meetings == []`, even though the list above is empty:
    # this is a guest FAILURE surface, and "No meetings yet." would be a
    # claim about a scoped list that was never queried for this visitor.
    |> assign(:index_empty?, false)
    |> assign(:viewer_external?, true)
    |> assign(:projects, [])
    |> assign(:meeting_subscribed_project_ids, [])
    |> assign(:show_start_meeting_sheet, false)
    |> assign(:meet_now_pending?, false)
    |> assign(:meet_now_project_id, nil)
    |> assign(:meet_now_project_name, nil)
    |> assign(:start_meeting_form, blank_start_meeting_form([]))
    |> assign(:start_meeting_error, nil)
    |> seed_create_invite_assigns()
    |> seed_live_invite_assigns()
  end

  # Seed the meeting-shell-tree assigns the current (stage-3) heex reads
  # unconditionally under `<%= if @meeting do %>`. Used by the `:name_entry`
  # guest state so the shell renders without crashing before stage 4 adds
  # the `:state`-branch cond. `:in_meeting` calls this indirectly via
  # `enter_meeting_as_guest/3` which then overrides some values. All
  # side-effect-free (no PubSub subscribes, no LiveKit calls).
  defp seed_guest_shell_tree_assigns(socket, meeting) do
    participants =
      if is_binary(meeting.chat_space_id),
        do: build_meeting_participants(meeting.chat_space_id),
        else: []

    socket
    |> assign(:meeting, meeting)
    # Per-meeting intent mute (task 019fbaac stage 4). `seed_intent_assigns/1`
    # seeded `false` in the guest mount clause, but that is the
    # PRE-RESOLUTION default, not the answer — and unlike the authenticated
    # surface there is no `handle_params/3` pass to resolve it later. Read
    # it here so a guest who joins a meeting that is ALREADY muted sees the
    # badge on first paint rather than only after the next toggle.
    |> assign(:intent_muted?, Meetings.intent_muted?(meeting.id))
    |> assign(:participants, participants)
    |> assign(:room_live?, room_live?(meeting.chat_space_id))
    |> assign(:room_recording?, room_recording?(meeting.chat_space_id))
    |> assign(:agents_by_id, %{})
    # The lobby's own agent-capability list (task 019e07cd, meetings-vs-
    # mockups audit). `attach_guest/1` below only `assign_new`s an empty
    # default for `:invite_rows` -- it has to, since it also runs on the
    # `:name_entry -> :in_meeting` transition where re-deriving would be
    # wrong -- so the FIRST seed has to happen here, on the guest's actual
    # mount, the same way `assign_invite_rows/3` seeds it on the member
    # mount path (line ~1088). Without this call `@invite_rows` renders as
    # `[]` silently (never a KeyError) and the lobby shows no agent block
    # at all, indistinguishable from a meeting with no agents on it.
    |> assign_invite_rows(meeting.chat_space_id, participants)
    # Per-meeting agent activity (task 01a04a98). Hydrated on the GUEST
    # surface too: the guest holds `meeting:<id>` (see
    # `enter_guest_topics/2`), which is the topic the activity mirror
    # publishes on, so a guest's tiles are live from first paint. It is
    # `@agents_by_id` — the GLOBAL `agents.status` map — that is
    # deliberately empty here, and activity is now what the tile reads.
    |> assign(:agent_activity, AgentActivity.hydrate(meeting.id))
    |> assign_meeting_canvases(meeting.chat_space_id)
    |> assign(:canvas_tile_changed?, false)
    |> assign(:current_stage_mode, :gallery)
    |> assign(:active_space, meeting.chat_space)
    |> assign(:current_participant, nil)
    |> MeetingHooks.attach_guest()
  end

  # The viewer's IANA zone, off the LiveSocket connect params (set in
  # `assets/js/app.js`) and validated at `CalendarWindow`'s single choke
  # point. Seeded in BOTH mount clauses — same discipline as
  # `seed_intent_assigns/1` — so no template can KeyError on it even on
  # the guest surface, which never draws a calendar.
  #
  # `get_connect_params/1` is legal ONLY inside `mount/3`, which is why
  # this lives here rather than in `handle_params/3`. On the disconnected
  # render it returns nil, which flows through `resolve_time_zone/1` to
  # nil — the intended dead-render answer, not a failure to handle.
  #
  # Three assigns, not one, because "no zone" has TWO causes that a
  # viewer needs told apart. `resolve_time_zone/1` collapses them both to
  # nil, so the raw param is kept BEFORE it is validated away:
  #
  #   * nothing was sent — the dead render, where nil is the right answer
  #   * something was sent and did not resolve — a connected client whose
  #     browser named a zone Tzdata does not know. Nothing re-attempts:
  #     `get_connect_params/1` is mount-only and no tick or param change
  #     re-derives it, so this is PERMANENT for the life of the LiveView
  #     and re-derives the same nil on every remount.
  #
  # `connected?/1` is the discriminator, and it is load-bearing. On the
  # DISCONNECTED render nil is intended rather than a failure, so
  # `:calendar_zone_unresolved?` is false there and the static HTML is
  # byte-identical to what it was before this existed — the dead-render
  # contract documented at `CalendarWindow.resolve_time_zone/1` and at
  # `list_calendar_week_meetings/3` below.
  #
  # `:calendar_time_zone_raw` is CLIENT-CONTROLLED data. It is truncated
  # to a label's worth of bytes and relies on HEEx escaping at the point
  # of render; it is never used to look anything up.
  defp assign_calendar_time_zone(socket) do
    raw =
      socket
      |> get_connect_params()
      |> case do
        %{"timezone" => time_zone} when is_binary(time_zone) -> time_zone
        _ -> nil
      end

    time_zone = CalendarWindow.resolve_time_zone(raw)

    socket
    |> assign(:calendar_time_zone, time_zone)
    |> assign(:calendar_time_zone_raw, if(is_nil(time_zone), do: truncate_zone_label(raw)))
    |> assign(:calendar_zone_unresolved?, connected?(socket) and is_nil(time_zone))
    |> assign(:calendar_zone_assumed?, false)
  end

  @zone_label_max_bytes 64

  defp truncate_zone_label(nil), do: nil
  defp truncate_zone_label(""), do: nil

  # Byte-bounded, not grapheme-bounded: the cap exists to bound what a
  # client can make us carry, and 64 GRAPHEMES is an unbounded number of
  # bytes. Cutting at a byte offset can land mid-codepoint, so the tail
  # is trimmed back to the last valid boundary rather than shipping an
  # invalid binary into the template.
  defp truncate_zone_label(raw) when is_binary(raw) do
    raw
    |> binary_part(0, min(byte_size(raw), @zone_label_max_bytes))
    |> trim_to_valid_utf8()
  end

  defp trim_to_valid_utf8(""), do: nil

  defp trim_to_valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      trim_to_valid_utf8(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  # The instant the now-line is drawn from, seeded at MOUNT and moved by
  # nothing but `:calendar_tick`. Seeded in both mount clauses — same
  # discipline as `assign_calendar_time_zone/1` — so no template can
  # KeyError on it.
  #
  # Seeding it here rather than leaving it absent until the first beat is
  # what keeps the DEAD render exactly as it was: the disconnected render
  # has no zone, `calendar_now_line/4` answers `[]` on the zone whatever
  # the instant, and it must reach that clause rather than raise on its
  # way there.
  defp seed_calendar_now(socket), do: assign(socket, :calendar_now, DateTime.utc_now())

  # Defaults for the intents-collapse bar. `:intents_visible?` is false
  # here on purpose: absent-until-proven-assigned is the safe direction
  # for a role gate, and `handle_params/3` resolves the real answer.
  defp seed_intent_assigns(socket) do
    socket
    |> assign(:intents, [])
    |> assign(:intents_visible?, false)
    |> assign(:intents_open, true)
    |> assign(:intents_expanded, false)
    |> assign(:intent_reason_picker_id, nil)
    |> assign(:intent_edit_row, nil)
    |> assign(:intent_pending_cancels, MapSet.new())
    |> assign(:intent_agent_options, [])
    |> assign(:intent_error, nil)
    # Per-meeting intent mute (task 019fbaac stage 3). `false` here is
    # the PRE-RESOLUTION default, not the answer — `handle_params/3`
    # reads the real value for the `:show` action. Seeded in this shared
    # helper because it is called from BOTH mount clauses, and the badge
    # renders in the top bar, which the `:index` action and the guest
    # surface also reach.
    |> assign(:intent_muted?, false)
    # The armed-candidate rail (task 01a03fba stage 4). Seeded EMPTY and
    # ungated: unlike `:intents_visible?` this rail has no role gate, so
    # the only reason it is empty here is that no meeting is resolved
    # yet. `handle_params/3` loads the real list.
    |> assign(:meeting_candidates, [])
    |> assign(:meeting_candidates_closed, [])
    # DERIVED from the line above and seeded in the SAME pipe (task
    # 01a07410 stage 2). `nil` here is not a placeholder awaiting
    # `handle_params/3` — it is `soonest_candidate/1` of an empty list,
    # which is the only answer an empty board has. Every other write of
    # `:meeting_candidates` in this module goes through
    # `assign_candidate_board/2`, which re-derives this in its own pipe,
    # so the two assigns cannot get out of step.
    |> assign(:soonest_candidate, nil)
    |> assign(:meeting_candidate_events, %{})
    |> assign(:candidate_error, nil)
    |> assign(:candidate_order, nil)
    # The ten-second undo left behind by THIS socket's own stop, or nil.
    # It is per-socket on purpose: the undo belongs to the participant
    # who pressed the button, and everybody else correctly sees the card
    # move to Closed. See `apply_candidate_stop/2`.
    |> assign(:candidate_undo, nil)
    # WHICH card has its correction panel open, or nil for none (task
    # 01a0740e stage 2). One id and not a set, which is what makes "one
    # panel at a time" structural rather than a rule somebody has to
    # keep — the same shape `:intent_reason_picker_id` uses above.
    #
    # Per-socket, like the undo stash: the panel belongs to the
    # participant who opened it. The RE-ARM it causes is server state
    # and does reach everybody, which is correct — that is a fact about
    # the card, not about one reader's screen.
    |> assign(:candidate_correcting_id, nil)
  end

  @impl true
  # Guest ingress (task 019f498d stage 3): the guest mount clause above
  # already resolved the invite + seeded every assign the guest states
  # need (`:state` in
  # `[:expired, :invalid, :unavailable, :name_entry, :in_meeting]`).
  # handle_params is a no-op here to avoid the shell-path
  # `Meetings.fetch_meeting_for_user/2` re-lookup and MeetingHooks.attach/2
  # (which requires a binary user_id and would double-subscribe the guest
  # to per-space PubSub). Guarded on `:state` presence rather than
  # `:chrome_mode == :none` alone so the stage-1 `/_probe/:slug` smoke
  # route (chrome_mode :none, no token, no `:state`) still falls through
  # to the shell path and its `:meeting` assign lands.
  def handle_params(_params, _url, %{assigns: %{state: state}} = socket)
      when state in [:expired, :invalid, :unavailable, :name_entry, :in_meeting] do
    {:noreply, socket}
  end

  # Authorization gate for the `:show` action (task 019f9b14 stage 2).
  #
  # The subject is `:current_user_record` — the real `%Platform.Accounts.User{}`
  # with `:org_memberships` preloaded, assigned by
  # `PlatformWeb.ShellLive.on_mount(:default)`, which is first in the
  # `:authenticated` live_session's `on_mount` list and therefore always
  # present before `handle_params/3` runs. Deliberately NOT `:user_id`:
  # `mount/3` above falls back to `Ecto.UUID.generate()` when the session
  # carries no `current_user_id`, and a fabricated UUID would make any
  # authorization decision built on it meaningless. Bracket access so the
  # shell-less guest live_session yields `nil` rather than a KeyError if this
  # clause is ever reached from there — `fetch_meeting_for_user/2` denies nil.
  #
  # The gate has to precede the whole success body, not just the row read:
  # that body subscribes the viewer to the meeting's chat PubSub, presence and
  # room topics, builds the participant list, loads the canvas, attaches
  # MeetingHooks, and sends `:auto_join`, which mints a LiveKit token. A denied
  # mount must reach none of that.
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    chrome_mode = socket.assigns[:chrome_mode]

    # `?tab=` deep-links the right rail (task 01a05b14 stage 3). Absent
    # or unrecognised leaves the current tab standing — `call_rail/1`
    # normalises anything it does not know back to People, so a stale
    # link costs the tab, never the pane.
    socket =
      case params["tab"] do
        tab when is_binary(tab) -> assign(socket, :active_meeting_tab, tab)
        _ -> socket
      end

    case Meetings.fetch_meeting_for_user(socket.assigns[:current_user_record], slug) do
      # A DENIED MOUNT MUST NOT BOUNCE OFF THE CHROME-LESS SURFACE (task
      # 019fb955-f8b1 stage 5). The shell branches below `push_navigate` to
      # `/meetings`, which is right for an internal viewer and wrong for a
      # member on the `meet.` host. `/meetings` IS on the meet surface as of
      # task 019ffbb3 — routed in the `:meet_member` live_session and admitted
      # by `ExternalUserScope` — so the navigation would now SUCCEED, and that
      # is exactly why it must not happen: a member denied one meeting must
      # not be handed a navigation to a list. Render the
      # SAME terminal invalid-invite card a bad guest link produces, so the
      # two denials are one outcome and the meeting name never reaches the
      # DOM. Matched first so the `chrome_mode == :shell` clauses below
      # stay byte-identical.
      #
      # `:ambiguous` is included deliberately. It is not a security signal,
      # but it `push_navigate`s to the same denied route, so leaving it out
      # would leave the bounce live on half the denial paths.
      {:error, reason} when reason in [:not_found, :ambiguous] and chrome_mode == :none ->
        {:noreply,
         socket
         |> assign(:page_title, "Invite link is not valid")
         |> assign(:state, :invalid)
         |> assign(:meeting, nil)
         |> seed_guest_index_fallback_assigns()}

      {:error, :not_found} ->
        # Clean not-found path — no MatchError / Ecto.NoResultsError
        # bubbles. Also clear the client's saved `route_resume:meetings`
        # entry so the Meetings tile falls back to `/meetings` on the next
        # click rather than looping right back into this nil resolve.
        #
        # An unauthorized viewer lands here too, with a byte-identical flash
        # to a genuinely absent slug. That is deliberate: two distinct
        # messages would turn this route into a slug-existence oracle. The
        # context collapses the external-user denial into `:not_found` for
        # the same reason.
        {:noreply,
         socket
         |> handle_route_stale("meetings")
         |> put_flash(:error, "Meeting not found.")
         |> push_navigate(to: ~p"/meetings")}

      {:error, :ambiguous} ->
        # The viewer belongs to two orgs that each own a meeting with this
        # slug (slug is unique per project, not globally). Not a security
        # signal — the viewer is entitled to both — so "Meeting not found."
        # would be a lie. Say so plainly and send them to the list, which
        # links by an unambiguous route. `handle_route_stale/2` keeps the
        # client's `route_resume:meetings` entry from looping them back in.
        {:noreply,
         socket
         |> handle_route_stale("meetings")
         |> put_flash(
           :error,
           "That link matches more than one meeting. Open it from the Meetings list."
         )
         |> push_navigate(to: ~p"/meetings")}

      {:ok, meeting} ->
        # RELEASE BEFORE HOLD (task 01a02c4e stage 3). `/meetings` and
        # `/meetings/:slug` are declared in ONE live_session on purpose
        # (`router.ex:461`), so meeting -> meeting is a live patch and this
        # clause re-enters on the SAME pid. Without a release the previous
        # meeting's `chat:space:<id>` hold is never dropped and one pid
        # accumulates a hold per meeting visited.
        #
        # `release_all/2`, NOT `release/3`: the previous meeting's space id is
        # not reliably in scope here (`:meeting` may be nil, or already
        # overwritten), and a targeted release that misses the right id is a
        # silent leak that still reads as "we release". `:meeting` is this
        # module's own owner tag, so releasing all of it cannot touch the
        # shell's `:presence` / `:roster` holds or ChatLive's `:chat_active`.
        socket =
          socket
          |> SpaceTopics.release_all(:meeting)
          |> SpaceTopics.release_all_agents(:meeting)

        socket =
          if connected?(socket) do
            socket =
              if meeting.chat_space_id do
                # `SpaceTopics.hold/3` RETURNS A SOCKET, so this block threads
                # it rather than running for effect. A raw
                # `ChatPubSub.subscribe/1` here (what this line used to be)
                # was a second registration on a pid the shell already holds
                # `chat:space:<id>` on: `Phoenix.PubSub` starts its registry
                # `keys: :duplicate`, `subscribe/3` is `Registry.register/3`
                # and `unsubscribe/2` is `Registry.unregister/2` — so a raw
                # subscribe duplicates delivery, and anybody's later
                # unsubscribe destroys BOTH registrations.
                socket = SpaceTopics.hold(socket, meeting.chat_space_id, :meeting)

                # Roster changes on the meeting's space (task 01a0691d stage
                # 3). `Chat.broadcast_roster_changed/3` publishes
                # `{:roster_changed, space_id}` on `space_agents:<id>` from
                # add / remove / set_principal, and the People tab re-derives
                # its invite rows on it without a reload. Through
                # `SpaceTopics` for exactly the reason the line above is:
                # `ShellLive`'s roster branch holds this same topic on this
                # same pid whenever its visible space is this space, and its
                # release used to be a bare `Phoenix.PubSub.unsubscribe/2`,
                # which removes EVERY registration of the pid. Now both are
                # refcounted and neither can silently unsubscribe the other.
                socket = SpaceTopics.hold_agents(socket, meeting.chat_space_id, :meeting)

                # Live meeting presence: `broadcast_presence_change` publishes
                # `{:meeting_presence_update, …}` on this per-space topic for
                # every LiveKit join/leave, so the rail/count stay live without
                # depending on a room row existing at mount time. The granular
                # `{:participant_joined,_}`/`{:participant_left,_}` events fire on
                # the room topic (subscribed below when a room is active).
                #
                # NOT a `chat:space:<id>` topic — `meeting_presence:<id>` is
                # keyed by the same space id but is a different topic with a
                # single subscriber in this process, so it stays a raw
                # subscribe. Same for the room topic below.
                MeetingsPubSub.subscribe_presence(meeting.chat_space_id)

                # Through `subscribe_room_once/2` so this site and the
                # `{:meeting_presence_update, _}` clause share one record of
                # which room topic this pid holds. When they did not, the
                # first presence delta after mount added a SECOND
                # registration on the same topic (task `01a02c4e` stage 4).
                case Meetings.get_active_room(meeting.chat_space_id) do
                  %{id: room_id} -> subscribe_room_once(socket, room_id, meeting.id)
                  _ -> socket
                end
              else
                socket
              end

            Phoenix.PubSub.subscribe(Platform.PubSub, meeting_topic(meeting.id))

            # Intents-collapse bar (task 019f70b8 stage 7). Subscribed
            # unconditionally rather than behind the role gate: the gate can
            # flip mid-meeting, and a subscription taken only at gate-open
            # would miss every transition between the appointment and the
            # next event. The handlers no-op when the bar is hidden.
            MeetingsPubSub.subscribe_intents(meeting.id)

            # The candidate lifecycle stream (task 01a03fba). Reused
            # rather than adding a second mechanism: `01a04a7f` /
            # `914a980c` already broadcast every candidate write on
            # `meeting:{id}:candidate_events`, and arming, extending and
            # stopping a countdown ARE candidate writes — they ride
            # `:heard`, `:threaded` and the two countdown kinds. A
            # countdown-specific topic would carry the same rows under a
            # second name.
            MeetingsPubSub.subscribe_candidate_events(meeting.id)
            Roles.subscribe_assignments()

            socket
          else
            # Task 01a0d3cd stage 4: seed `:ask_floor_holders` here too,
            # NOT only inside `subscribe_room_once/3` above (which only
            # ever runs `if connected?(socket)`). Found live via CDP: a
            # second viewer's disconnected static render (the plain HTTP
            # GET every page load starts with, before the socket
            # connects) skipped this entirely, so `@ask_floor_holders`
            # was still its mount-time default when the per-agent hold
            # button — `phx-update="ignore"` in `ParticipantRail`, by
            # design so its own hook owns the DOM afterwards — got its
            # ONE chance to bake `disabled`/`bg-base-300` into the
            # button's initial HTML. The connected mount that follows
            # DOES compute `held_by_other?` correctly (the row's
            # non-ignored wrapper `<div>` dims right on cue), but
            # `phx-update="ignore"` means that correction can never
            # reach the button itself — so a viewer whose page load won
            # the ordinary disconnected-then-connected race saw a
            # bright, undisabled Ask button for an agent someone else
            # was already holding, for the rest of that mount's life.
            # `AskFloor.list_meeting/1` is a plain ETS read with no
            # subscription side effect (see its own moduledoc: "used to
            # seed a newly (re)subscribed client's view... so a viewer
            # joining mid-meeting needs this to see an already-held
            # agent as held from their FIRST RENDER" — that guarantee
            # did not actually reach the disconnected render before
            # this), so calling it unconditionally here costs nothing
            # the connected branch does not already pay.
            seed_ask_floor_holders(socket, meeting.id)
          end

        participants =
          if meeting.chat_space_id,
            do: build_meeting_participants(meeting.chat_space_id),
            else: []

        agents_by_id = load_agents_by_id(participants)

        # Resolve the viewer's existing participant row (read-only — the
        # bridge that inserts a row on join lands in stage 4 of this
        # task). MeetingHooks reads `:current_participant` at join time
        # for the LiveKit identity's display name; `nil` is fine for the
        # initial mount and join will simply no-op without crashing.
        current_participant =
          if meeting.chat_space_id,
            do: find_participant(meeting.chat_space_id, socket.assigns.user_id),
            else: nil

        # Mirror ChatLive's plumbing so we can reuse MeetingHooks
        # verbatim: it reads `:active_space` + `:current_participant`
        # on `meeting_join`, owns the `:in_meeting` / mic / camera /
        # screen-share assigns, and pushes the LiveKit-bound JS hook
        # events into MeetingClient + MeetingRoom.
        socket =
          socket
          |> assign(:page_title, "Meeting · #{meeting.name}")
          |> assign(:meeting, meeting)
          |> assign(:participants, participants)
          |> assign(:room_live?, room_live?(meeting.chat_space_id))
          |> assign(:room_recording?, room_recording?(meeting.chat_space_id))
          |> assign(:agents_by_id, agents_by_id)
          # The invite-an-agent control's options (task 01a04c2f). Seeded
          # here and re-derived by `refresh_participants/1`, so an agent that
          # joins the call leaves the list on the same tick its tile appears.
          |> assign_invite_rows(meeting.chat_space_id, participants)
          # Task 01a0691d stage 3. Opt in to `ShellLive`'s `:roster_updates`
          # hook FORWARDING `{:roster_changed, _}` instead of halting it; the
          # `handle_info/2` clause below is what folds it. Assigned
          # unconditionally rather than only when connected: the hook reads it
          # on every message, a disconnected mount receives none, and a flag
          # that is only sometimes present is the shape that goes stale.
          |> assign(:roster_changed_downstream?, true)
          # Per-meeting agent activity (task 01a04a98), seeded from the
          # LIVE intent queue rather than from the tile's old
          # `activity_state={:idle}` literal. A socket that mounts at
          # minute 20 has to see the intents that are in flight AT minute
          # 20 — mounting without hydration is exactly the "avatar stuck
          # on thinking" failure this replaces, run in reverse.
          |> assign(:agent_activity, AgentActivity.hydrate(meeting.id))
          |> assign_meeting_canvases(meeting.chat_space_id)
          |> assign(:canvas_tile_changed?, false)
          |> assign(:current_stage_mode, :gallery)
          |> assign(:active_space, meeting.chat_space)
          |> assign(:current_participant, current_participant)
          # Whiteboard persistence (stage 4). `:whiteboard_version` is what
          # THIS socket believes is stored; it is only ever set from a load
          # or a successful save, so it stays an honest answer to "is the
          # broadcast I just saw newer than what my client holds?".
          # `:whiteboard_remote_version` drives the passive badge and is nil
          # whenever there is nothing to tell the user.
          |> assign(:whiteboard_version, 0)
          |> assign(:whiteboard_remote_version, nil)
          # Stage 5: the two attachment ids/URLs reserved for an in-flight
          # export. Server-held on purpose — see the export handlers.
          |> assign(:whiteboard_export_pending, nil)
          # ── Intents-collapse bar (task 019f70b8 stage 7) ──────────────
          # Seeded from the LIVE queue keyed by this meeting's id — the
          # same id the classifier enqueues under. `IntentQueue.list/1`
          # returns `[]` when no owner is running, which is the correct
          # rendering for a meeting that has produced no intents yet.
          |> seed_intent_assigns()
          |> assign_intents_gate()
          |> assign(:intents, IntentQueue.list(meeting.id))
          # Durable per-meeting mute, resolved from the row rather than
          # inherited from the seed: a viewer joining a meeting that was
          # muted before they arrived must see it muted on first paint.
          |> assign(:intent_muted?, Meetings.intent_muted?(meeting.id))
          # Armed candidates, resolved from the rows rather than left at
          # the seed's `[]`: a participant joining a meeting whose cards
          # were already counting down must be able to stop them on
          # first paint, not only after the next utterance.
          |> assign_candidate_board(meeting.id)
          # BEFORE `MeetingHooks.attach/2`, deliberately: hooks run in
          # attach order and the leave clauses there `:halt`, so this
          # is the only seat from which MeetingLive can see a leave at
          # all — and it must read the roster before `stamp_local_left/1`
          # removes the viewer from it (task 01a07410 stage 6).
          |> attach_call_recap_hook()
          |> MeetingHooks.attach(List.wrap(meeting.chat_space_id))

        # THE `/meetings` HALF OF THE TWO-SURFACE AGENT-ACTIVITY TICK (task
        # 01a06e07 stage 3, correction 1). `MeetingHooks.attach/2` just
        # above installs the `:meeting_info` hook whose `:agent_activity_tick`
        # clause updates `:agent_activity_now` and re-arms itself every
        # second — this call is only ever the FIRST beat. Without it the
        # rail's `Thinking · Ns` counter on THIS surface would render once
        # at mount and freeze, and the 120s ceiling in
        # `AgentActivity.resolve_at/2` would never get asked again either,
        # exactly the quickmeet-only-fix trap the stage brief calls out.
        if connected?(socket), do: MeetingHooks.schedule_agent_activity_tick()

        # Pre-join LOBBY for signed-in members on the chrome-less meeting
        # surface (task 01a09415). This is Harper's #4 divergence from the
        # prototype: "member lobby — guests get the camera-preview prejoin,
        # but signed-in members skip straight into the call with no preview."
        #
        # An invited member arrives on the `meet.` host (`chrome_mode ==
        # :none`, a real signed-in account) EXACTLY as a guest does — via a
        # meeting link, with no app shell around them — so this is the
        # surface where "the member skips the prejoin the guest gets" is the
        # literal, side-by-side comparison the divergence names. That member
        # now lands in the SAME lobby a guest gets: `:lobby` renders the
        # identical preview + mic/camera toggles + Join markup as the guest's
        # `:name_entry`, minus the name field the account makes redundant.
        # The lobby's "Join" (`"join_meeting"`) runs the very
        # `maybe_start_meeting |> MeetingHooks.join()` path auto-join used to,
        # so a mic or camera toggled off in the lobby stays off in the room
        # (`do_join/1` reads the live `:mic_enabled`/`:camera_enabled` pair at
        # push time — device choice survives the transition unchanged).
        #
        # SCOPE (a documented judgment call). An INTERNAL user reaching a
        # meeting from the in-app meetings list renders inside the shell
        # (`chrome_mode == :shell`) and continues to auto-join on a connected
        # mount, unchanged. They navigated INTO the meeting from their own
        # list; the divergence is about the link-arrival surface that mirrors
        # a guest, and that is the chrome-less one. Widening the prejoin to
        # the in-app shell surface is a larger change (every in-call shell
        # test would have to enter through the lobby) and is left as a
        # follow-up rather than bundled in here.
        #
        # `?no_autojoin=true` keeps its meaning as the test/deep-link escape
        # hatch: SKIP the lobby / auto-join and render the call shell (with
        # its own manual "Join" CTA) WITHOUT connecting. `:in_meeting` guards
        # a live-patch re-entry (e.g. a `?tab=` deep-link) on an already
        # joined member so it cannot bounce them back out of the call.
        socket =
          cond do
            Map.get(params, "no_autojoin") == "true" ->
              socket

            socket.assigns[:in_meeting] ->
              socket

            socket.assigns[:chrome_mode] == :none ->
              # Set on both the disconnected and connected render so the
              # static first paint and the live view agree; the join itself
              # happens only on the explicit "Join".
              assign(socket, :state, :lobby)

            connected?(socket) ->
              # Internal shell surface, unchanged: defer the join one tick so
              # the LV is fully mounted before MeetingHooks reads
              # `:active_space`.
              send(self(), :auto_join)
              socket

            true ->
              socket
          end

        {:noreply, socket}
    end
  end

  def handle_params(params, _url, socket) do
    # `:index` action — grouped meetings list (live / upcoming / ended)
    # plus an empty-state when no meetings exist. Pre-project-routing
    # the index lists every meeting; per-project subscription keeps
    # `{:meeting_created, _}` / `{:meeting_ended, _}` / `{:meeting_started, _}`
    # broadcasts flowing in.
    # The index is viewer-scoped: `Meetings.list_meetings_for_user/1`
    # supplies the rule (Fabrikam root admin sees all; an external user sees
    # the meetings they hold a live invite for; everyone else is narrowed
    # by org membership), and the calendar below shares that one rule via
    # its range sibling. The project picker is viewer-scoped too. (Which
    # rows are excluded is spelled out in prose rather than by naming the
    # unscoped query function, so the `Platform.Tasks.ProjectScopeTest`
    # LiveView guard — a plain string scan over this directory — is not
    # tripped by a comment.)
    #
    # `:current_user_record` is assigned by `ShellLive.on_mount/4`, which
    # runs before `handle_params/3` for every route in the authenticated
    # live_session — no session re-read or extra lookup needed here.
    # The other half of the release pair (task 01a02c4e stage 3). Patching from
    # a room back to the index stays on ONE pid — both routes are declared in
    # the same live_session (`router.ex:461`) — so without this the room's
    # `chat:space:<id>` hold survives on a viewer who is no longer in any
    # meeting. `release_all/2` because the departed meeting's space id is not
    # in scope on this clause at all; only `:meeting`'s own holds are dropped,
    # so a space the shell's presence branch also holds stays subscribed.
    socket =
      socket
      |> SpaceTopics.release_all(:meeting)
      |> SpaceTopics.release_all_agents(:meeting)

    projects = Tasks.list_projects_for_user(socket.assigns[:current_user_record])
    project_ids = Enum.map(projects, & &1.id)

    if connected?(socket) do
      Enum.each(project_ids, &Meetings.subscribe_to_project_meetings/1)
    end

    # Same `:current_user_record` the project list above reads — the USER
    # STRUCT. Never `:current_user`, which holds a display string: a
    # non-map viewer lands in the scoped query's empty-answer clause and
    # would render an empty index to everybody, which passes every
    # must-not-see assertion vacuously.
    meetings = Meetings.list_meetings_for_user(socket.assigns[:current_user_record])
    grouped = group_meetings_by_status(meetings)

    # The now-line has to move on its own. Arming the tick here (only when
    # connected — a dead render has no later beat) rather than at mount
    # keeps it scoped to the `:index` action. A now-line frozen at mount
    # time is a wrong answer that looks like a right one.
    if connected?(socket), do: schedule_calendar_tick()

    {:noreply,
     socket
     |> assign(:page_title, "Meetings")
     |> assign(:meeting, nil)
     # Drop any meeting-surface `:state` (task 01a09415). A member who
     # patches from a meeting's pre-join `:lobby` back to `/meetings` stays
     # on ONE pid (both routes share the `:meet_member` live_session), so
     # without this the stale `:state == :lobby` would keep the lobby cond
     # branch selected while `:meeting` is now nil — a `@meeting.name` on nil.
     # The index never reads `:state`, and a normal index mount already has
     # it nil, so this is a no-op everywhere except that transition.
     |> assign(:state, nil)
     # `:meetings` and `:grouped_meetings` keep their exact prior meaning:
     # `data-role="meetings-count"` and the archive sibling both read them,
     # and the calendar is an additional projection, not a replacement.
     |> assign(:meetings, meetings)
     |> assign(:grouped_meetings, grouped)
     # ── Why the index needs an empty state again (019f9cb7 stage 5) ──────
     # Scoping the index changed the shape of a CORRECT answer. Before it,
     # `@meetings` held every meeting in the system and was empty only on a
     # fresh install; now zero is an ordinary result for a new external user
     # and one row is an ordinary result for most people. The calendar draws
     # its chrome either way, but a viewer whose ENTIRE scoped list is empty
     # is looking at a page that never says so, and this route is where a
     # denied `/meetings/:slug` redirects — so they arrive under "Meeting not
     # found." at a grid that reads as "your week", not as "you have none".
     #
     # `@meetings` (unbounded in time), never the week list: an empty WEEK is
     # a navigation fact the week's own count already reports.
     |> assign(:index_empty?, meetings == [])
     # Resolved once per index render, not per row: `external_user?/1` is a
     # query. The empty-state subline branches on it because the two viewer
     # classes are empty for DIFFERENT reasons — an external user sees only
     # meetings they hold a live invite for, an internal user is scoped by
     # org membership and will routinely open meetings nobody invited them
     # to. Telling an internal user to wait for an invite would be false.
     |> assign(:viewer_external?, Tenancy.external_user?(socket.assigns[:current_user_record]))
     |> assign(:meeting_subscribed_project_ids, project_ids)
     |> assign_new(:projects, fn -> projects end)
     |> assign_new(:show_start_meeting_sheet, fn -> false end)
     |> assign_new(:meet_now_pending?, fn -> false end)
     |> assign_meet_now_project()
     |> assign_new(:start_meeting_form, fn -> blank_start_meeting_form(projects) end)
     |> assign_new(:start_meeting_error, fn -> nil end)
     |> assign_new(:meeting_create_invites, fn -> [] end)
     |> assign_new(:meeting_create_invite_query, fn -> "" end)
     |> assign_new(:meeting_create_invite_candidates, fn -> [] end)
     |> assign_new(:meeting_create_invite_email, fn -> nil end)
     |> assign_new(:selected_meeting_id, fn -> nil end)
     |> assign_new(:meeting_invite_open, fn -> false end)
     |> assign_new(:meeting_invite_query, fn -> "" end)
     |> assign_new(:meeting_invite_candidates, fn -> [] end)
     |> assign_new(:meeting_invite_email, fn -> nil end)
     |> assign_calendar_week(calendar_today(socket))
     |> assign_archive(params)}
  end

  # ── Calendar window (task 019fb954-8ead) ─────────────────────────────────

  @typedoc """
  Which of the two calendar halves is asking.

  Not a breakpoint and not a device: the two halves are different
  information architectures that happen to draw the same meetings, and the
  only thing the geometry helpers need from the distinction is how tall
  that half draws an hour.
  """
  @type calendar_view :: :week | :day

  @typedoc "A placement plus the one question only the view can answer."
  @type calendar_block :: %{
          top: float(),
          height: float(),
          lane: non_neg_integer(),
          lanes: pos_integer(),
          left: float(),
          width: float(),
          compact?: boolean()
        }

  # `rem` is resolved against the root font size, which the shell does not
  # override; converting here rather than emitting a px threshold keeps the
  # comparison in the same units the template lays out in.
  @root_font_px 16

  # Recompute every calendar assign from one anchor date. The SINGLE path
  # by which the week's meetings are loaded: `handle_params/3` and all four
  # navigation events funnel through here, so there is exactly one range
  # query in the module and no way for a handler to drift from it.
  #
  # One query per WEEK, not seven per day: the range query is already
  # half-open over the same bounds `week_bounds/2` produces, and the day
  # columns are a partition of that result in memory.
  #
  # The viewer is read from the socket here rather than threaded in by
  # each caller, and is deliberately NOT a new assign: `:current_user_record`
  # is already assigned by `ShellLive.on_mount/4` for every route in the
  # authenticated live_session, so all four navigation events and the
  # PubSub refresh inherit the scoping without knowing about it.
  defp assign_calendar_week(socket, %Date{} = anchor, selected \\ nil) do
    time_zone = socket.assigns.calendar_time_zone
    selected = selected || anchor
    viewer = socket.assigns[:current_user_record]
    meetings = list_calendar_week_meetings(viewer, anchor, time_zone)

    socket
    |> assign(:calendar_anchor_date, anchor)
    |> assign(:calendar_selected_date, selected)
    |> assign(:calendar_week_meetings, meetings)
    |> assign(:calendar_hour_window, calendar_hour_window(meetings, time_zone))
  end

  # No zone means no query. The dead render places NOTHING rather than
  # placing everything in UTC: a row that visibly jumps between day
  # columns one beat after connect is a worse answer than one beat of
  # empty grid, and the extra range query would be work done to be undone.
  defp list_calendar_week_meetings(_viewer, _anchor, nil), do: []

  # Viewer-scoped for the same reason the list is: the grid draws meeting
  # NAMES, so an unscoped range query leaks exactly what the list would.
  # Same rule, shared with the index by construction.
  defp list_calendar_week_meetings(viewer, %Date{} = anchor, time_zone) do
    {from, to} = CalendarWindow.week_bounds(anchor, time_zone)
    Meetings.list_meetings_in_range_for_user(viewer, from, to)
  end

  defp calendar_hour_window(_meetings, nil), do: CalendarWindow.hour_window([], "Etc/UTC")

  defp calendar_hour_window(meetings, time_zone),
    do: CalendarWindow.hour_window(meetings, time_zone)

  defp schedule_calendar_tick, do: Process.send_after(self(), :calendar_tick, 60_000)

  defp schedule_agent_activity_tick_guest,
    do: Process.send_after(self(), :agent_activity_tick_guest, AgentActivity.tick_interval_ms())

  # "Today" is the viewer's today, not the server's. Near midnight those
  # are different DATES, and opening the calendar to the wrong week is
  # exactly the class of error the connect-param zone exists to prevent.
  # With no zone we have nothing better than UTC, and the grid is empty
  # anyway on that render.
  defp calendar_today(socket), do: calendar_today_date(socket.assigns.calendar_time_zone)

  @doc """
  The viewer's current date in `time_zone`, or the server's when the zone
  is unknown.

  The `nil` clause is NOT a second guess: it returns exactly the date
  `assign_calendar_week/3` already anchored the rendered week on, so the
  day the grid highlights and the week the grid draws can never disagree.
  Both correct themselves on the same beat, when the connect params land.
  """
  @spec calendar_today_date(String.t() | nil) :: Date.t()
  def calendar_today_date(time_zone), do: calendar_today_date(time_zone, DateTime.utc_now())

  @doc """
  `calendar_today_date/1` against a GIVEN instant rather than the clock.

  The arity-1 form reads the clock and is the one navigation calls; this
  is the form the render path uses, so "today" on screen is derived from
  the same `@calendar_now` the now-line's offset is, and the two cannot
  disagree about which day it is across a midnight beat.
  """
  @spec calendar_today_date(String.t() | nil, DateTime.t()) :: Date.t()
  def calendar_today_date(nil, %DateTime{} = now), do: DateTime.to_date(now)

  def calendar_today_date(time_zone, %DateTime{} = now) when is_binary(time_zone),
    do: now |> DateTime.shift_zone!(time_zone) |> DateTime.to_date()

  # ── Calendar rendering helpers (task 019fb954-8ead stage 2) ──────────────
  #
  # Every one of these is a total function of its arguments so the grid
  # template does no arithmetic of its own. `CalendarWindow` owns the
  # date maths; these own the FORMATTING and the assign-shaped plumbing
  # between it and the markup.

  @doc """
  The rendered week's label — `Aug 3 – 9, 2026`.

  The year is printed ONCE for a week that stays inside a year, which is
  every week but one. The three clauses widen only as far as they must:
  the month repeats only when the week straddles two, and the year only
  when it straddles two. The separator is an en dash (U+2013), the
  typographic range mark, not a hyphen.
  """
  @spec calendar_week_label(Date.t()) :: String.t()
  def calendar_week_label(%Date{} = anchor) do
    days = CalendarWindow.week_days(anchor)
    first = List.first(days)
    last = List.last(days)

    cond do
      first.year != last.year ->
        "#{month_abbrev(first)} #{first.day}, #{first.year} – " <>
          "#{month_abbrev(last)} #{last.day}, #{last.year}"

      first.month != last.month ->
        "#{month_abbrev(first)} #{first.day} – #{month_abbrev(last)} #{last.day}, #{last.year}"

      true ->
        "#{month_abbrev(first)} #{first.day} – #{last.day}, #{last.year}"
    end
  end

  @doc """
  The seven days of the rendered week, Monday first, each already tagged
  with whether it is the viewer's today.

  The tag is computed here rather than per-cell in the template so the
  clock is read ONCE for the whole grid. Two reads either side of
  midnight would let the header circle and the now-line disagree about
  which day it is, in the one render where that is most visible.
  """
  @spec calendar_week_days(Date.t(), String.t() | nil) :: [
          %{date: Date.t(), today?: boolean()}
        ]
  def calendar_week_days(%Date{} = anchor, time_zone) do
    today = calendar_today_date(time_zone)

    anchor
    |> CalendarWindow.week_days()
    |> Enum.map(&%{date: &1, today?: Date.compare(&1, today) == :eq})
  end

  @doc """
  The hours the gutter draws a label for, one per rendered row.

  The window is half-open — `{8, 18}` is eight AM through the END of the
  five PM row — so the last hour gets no label of its own.
  """
  @spec calendar_hours({integer(), integer()}) :: [integer()]
  def calendar_hours({first_hour, last_hour}) when last_hour > first_hour,
    do: Enum.to_list(first_hour..(last_hour - 1))

  @doc """
  A gutter label for a 24-hour clock hour — `8 AM`, `12 PM`, `11 PM`.
  """
  @spec calendar_hour_label(integer()) :: String.t()
  def calendar_hour_label(0), do: "12 AM"
  def calendar_hour_label(12), do: "12 PM"
  def calendar_hour_label(hour) when hour > 0 and hour < 12, do: "#{hour} AM"
  def calendar_hour_label(hour) when hour > 12 and hour < 24, do: "#{hour - 12} PM"

  @doc """
  The `{meeting, placement}` pairs that belong in `date`'s column.

  Filtering happens in `CalendarWindow.place/4`, which answers `:skip`
  both for a meeting that cannot be drawn at all (cancelled, or never
  scheduled) and for one that simply belongs to another day. The template
  therefore never asks "should this be here?" — it renders what it is
  handed.

  With no resolved zone there is no local date to compare against, so
  NOTHING is placed. That is the contract `resolve_time_zone/1` sets up:
  one beat of empty grid rather than seven columns of meetings that jump
  sideways the moment the browser tells us where it is.

  The returned placement is everything the template needs to draw the
  block and nothing it has to derive: vertical position from
  `CalendarWindow.place/4`, horizontal position from
  `CalendarWindow.assign_lanes/1`, and `:compact?` from the one piece the
  arithmetic module cannot know — how tall this particular view draws an
  hour. `view` is therefore load-bearing rather than cosmetic: the same
  meeting is compact in the week grid's 3.25rem rows and roomy in the day
  view's 5.5rem ones.
  """
  @spec calendar_day_events(
          [Meeting.t()],
          Date.t(),
          String.t() | nil,
          {integer(), integer()},
          calendar_view()
        ) :: [{Meeting.t(), calendar_block()}]
  def calendar_day_events(_meetings, %Date{}, nil, _window, _view), do: []

  def calendar_day_events(meetings, %Date{} = date, time_zone, window, view)
      when is_list(meetings) and is_binary(time_zone) and view in [:week, :day] do
    meetings
    |> Enum.flat_map(fn meeting ->
      case CalendarWindow.place(meeting, date, time_zone, window) do
        {:ok, placement} -> [{meeting, placement}]
        :skip -> []
      end
    end)
    |> CalendarWindow.assign_lanes()
    |> Enum.map(fn {meeting, placement} ->
      {meeting, Map.put(placement, :compact?, calendar_compact_block?(placement, window, view))}
    end)
  end

  @doc """
  How tall one hour is drawn, in `rem`, for each of the two calendar halves.

  The single source of truth for the vertical rhythm: the gutter row, the
  hour rules painted behind the column, and the compact-block threshold all
  read it, so none of them can drift from the others.

  `:week` keeps the design frame's 3.25rem — ten hours over a 520px body,
  a working day visible without scrolling. `:day` is 5.5rem, and that number
  is derived rather than chosen: `CalendarWindow`'s half-hour floor times
  5.5rem is exactly 44px, so the shortest block a phone can draw IS the
  touch target. Meeting the 44px floor by geometry is what lets the block
  carry no CSS minimum at all — a pixel minimum inside a proportional
  column is what put two meetings' text on top of each other.
  """
  @spec calendar_hour_row_rem(calendar_view()) :: float()
  def calendar_hour_row_rem(:week), do: 3.25
  def calendar_hour_row_rem(:day), do: 5.5

  @doc """
  The height a two-line block needs, in px, before its second line clips.

  Title line plus time line at each half's own font sizes and leading, plus
  that half's vertical padding. A block shorter than this renders compact —
  one line — rather than drawing a time label the viewer only sees the top
  half of.
  """
  @spec calendar_two_line_px(calendar_view()) :: number()
  # 11px + 10px at leading-tight, plus `py-1`.
  def calendar_two_line_px(:week), do: 35
  # 12px + 11px at leading-tight, plus `py-1.5`.
  def calendar_two_line_px(:day), do: 41

  @doc """
  How tall `placement` actually renders, in px, in `view`.

  Note the window cancels out — a percentage of a window that is itself
  `hours * row` px tall is just the block's own duration in rows — which is
  the property that makes the compact threshold stable no matter how far
  `hour_window/2` has widened the grid.
  """
  @spec calendar_block_height_px(
          %{height: float()},
          {integer(), integer()},
          calendar_view()
        ) :: float()
  def calendar_block_height_px(%{height: height}, {first_hour, last_hour}, view) do
    height / 100 * (last_hour - first_hour) * calendar_hour_row_rem(view) * @root_font_px
  end

  @doc """
  Whether this block must drop to a single line to stay legible.
  """
  @spec calendar_compact_block?(%{height: float()}, {integer(), integer()}, calendar_view()) ::
          boolean()
  def calendar_compact_block?(placement, window, view),
    do: calendar_block_height_px(placement, window, view) < calendar_two_line_px(view)

  @doc """
  The gutter, in `rem`, between an event block and its column's edges — and
  between two blocks that had to share the column's width.
  """
  @spec calendar_block_gutter_rem(calendar_view()) :: float()
  def calendar_block_gutter_rem(:week), do: 0.25
  def calendar_block_gutter_rem(:day), do: 0.375

  @doc """
  The whole geometry of one event block as an inline `style`.

  All four edges in one string, because they are one decision: `top` /
  `height` say WHEN, `left` / `width` say which lane, and a block whose
  lane came from a stale copy of its placement would be drawn over its
  neighbour. The `calc` keeps the gutter in `rem` while the lane split
  stays in percent, so a two-lane pair gets one gutter between them and
  half a column each without either unit having to know the other.
  """
  @spec calendar_block_style(
          %{top: float(), height: float(), left: float(), width: float()},
          calendar_view()
        ) :: String.t()
  def calendar_block_style(%{top: top, height: height, left: left, width: width}, view) do
    gutter = calendar_block_gutter_rem(view)

    "top:#{top}%;height:#{height}%;" <>
      "left:calc(#{left}% + #{gutter}rem);width:calc(#{width}% - #{gutter * 2}rem)"
  end

  @doc """
  One hour row's height, as an inline `style` for the gutter column.
  """
  @spec calendar_hour_row_style(calendar_view()) :: String.t()
  def calendar_hour_row_style(view), do: "height:#{calendar_hour_row_rem(view)}rem"

  @doc """
  The hour rules painted behind a day column, as an inline `style`.

  A repeating gradient rather than one element per hour: the rules are
  decoration, and the column's only children should be the things a reader
  can click. Driven off the same `rem` as the gutter rows, so the lines
  cannot land anywhere but on the hour.
  """
  @spec calendar_hour_rules_style(calendar_view()) :: String.t()
  def calendar_hour_rules_style(view) do
    row = calendar_hour_row_rem(view)

    "background-image: repeating-linear-gradient(to bottom, transparent 0, " <>
      "transparent calc(#{row}rem - 1px), var(--color-base-300) calc(#{row}rem - 1px), " <>
      "var(--color-base-300) #{row}rem)"
  end

  @doc """
  A placed meeting's local start time as `HH:MM`.

  Rendered SERVER-SIDE in the resolved zone rather than by a client hook,
  so the string inside a block and the column the block sits in can never
  disagree about what day it is.
  """
  @spec calendar_event_time(Meeting.t(), String.t()) :: String.t()
  def calendar_event_time(%Meeting{scheduled_start_at: start_at}, time_zone)
      when is_binary(time_zone) do
    start_at
    |> DateTime.shift_zone!(time_zone)
    |> Calendar.strftime("%H:%M")
  end

  @doc """
  How far down the rendered hour window a GIVEN instant sits, as a
  percentage, or `nil` when there is no honest answer.

  The instant is an ARGUMENT, never the clock. Two reasons, and the
  first is a correctness one: LiveView diffs on assigns, so a helper
  that reads the clock inside the render is only ever re-evaluated when
  something else on the page changes, and the line it draws is the one
  from whenever that last happened. Taking `now` in means the offset
  moves exactly when `@calendar_now` does — every beat, and only then.
  The second is that it makes the value testable at an arbitrary time of
  day without sleeping through one.

  `nil` for an unresolved zone — the caller draws no line rather than a
  line in server time, which is the same call `resolve_time_zone/1`
  makes. `nil` too when the instant's hour falls OUTSIDE the drawn
  window: a now-line pinned to the top edge at 3 AM is not a smaller
  error than no line, it is a confident wrong one.
  """
  @spec calendar_now_offset(String.t() | nil, {integer(), integer()}, DateTime.t()) ::
          float() | nil
  def calendar_now_offset(nil, _window, %DateTime{}), do: nil

  def calendar_now_offset(time_zone, {first_hour, last_hour}, %DateTime{} = now)
      when is_binary(time_zone) and last_hour > first_hour do
    now = DateTime.shift_zone!(now, time_zone)
    window_minutes = (last_hour - first_hour) * 60
    offset_minutes = (now.hour - first_hour) * 60 + now.minute

    if offset_minutes >= 0 and offset_minutes <= window_minutes do
      offset_minutes / window_minutes * 100
    end
  end

  @doc """
  The now-line's offset for one day column, as a single-element list, or
  `[]` when that column must not draw one.

  A list rather than a `nil`-able value so the template renders it with
  the same `:for` it renders everything else with, and never places a
  line on a path where the guard said no.

  Two independent reasons to draw nothing, and they are different
  reasons: this is not today's column (the line is a fact about ONE day
  — drawn across all seven it claims it is also 2:14 PM on Sunday), or
  there is no honest offset at all (see `calendar_now_offset/3`).
  """
  @spec calendar_now_line(boolean(), String.t() | nil, {integer(), integer()}, DateTime.t()) ::
          [float()]
  def calendar_now_line(false, _time_zone, _window, %DateTime{}), do: []

  def calendar_now_line(true, time_zone, window, %DateTime{} = now) do
    case calendar_now_offset(time_zone, window, now) do
      nil -> []
      offset -> [offset]
    end
  end

  @doc """
  A day column's heading abbreviation — `MON`, `TUE`.
  """
  @spec calendar_weekday_abbrev(Date.t()) :: String.t()
  def calendar_weekday_abbrev(%Date{} = date),
    do: date |> Calendar.strftime("%a") |> String.upcase()

  # ── Mobile week strip + day view (task 019fb954-8ead stage 3) ────────────

  @doc """
  A week-strip cell's single letter — `M`, `T`, `W`.

  Derived from `calendar_weekday_abbrev/1` rather than from a literal
  seven-element list, so the strip cannot disagree with the desktop
  heading about which day a date is.
  """
  @spec calendar_weekday_initial(Date.t()) :: String.t()
  def calendar_weekday_initial(%Date{} = date),
    do: date |> calendar_weekday_abbrev() |> String.first()

  @doc """
  The mobile day heading's date half — `Wednesday, Aug 5`.

  The weekday is written out in full here where the strip above prints
  one letter: the strip is scanned, this is read.
  """
  @spec calendar_day_label(Date.t()) :: String.t()
  def calendar_day_label(%Date{} = date), do: Calendar.strftime(date, "%A, %b %-d")

  @doc """
  How many meetings the day view will actually DRAW for `date`.

  Delegates to `calendar_day_events/4` rather than counting rows itself,
  which is the whole point: the number in the heading and the blocks in
  the column are the same list measured twice, so a cancelled meeting —
  or one that was never scheduled — cannot be counted into a heading
  that then names more meetings than the reader can see.
  """
  @spec calendar_day_meeting_count(
          [Meeting.t()],
          Date.t(),
          String.t() | nil,
          {integer(), integer()}
        ) :: non_neg_integer()
  def calendar_day_meeting_count(meetings, %Date{} = date, time_zone, window),
    do: meetings |> calendar_day_events(date, time_zone, window, :day) |> length()

  @doc """
  The count half of the mobile day heading — `No meetings`, `1 meeting`,
  `2 meetings`.

  Zero gets words rather than a `0`, because the heading is the only
  place a phone says anything about the selected day and an empty column
  under a bare `0 meetings` reads like a failed load.
  """
  @spec calendar_day_count_label(non_neg_integer()) :: String.t()
  def calendar_day_count_label(0), do: "No meetings"
  def calendar_day_count_label(1), do: "1 meeting"

  def calendar_day_count_label(count) when is_integer(count) and count > 1,
    do: "#{count} meetings"

  @doc """
  The meetings of ONE day as a flat list, for the mobile card list
  (task 01a07410 / FE-17 stage 7).

  Derived from `calendar_day_events/5` and nothing else, so the cards,
  the hour blocks under them and the count in the heading are the same
  list read three times: a meeting that the placement maths skips
  (cancelled, unscheduled, outside the drawn window) is absent from all
  three rather than counted in one and missing from another.
  """
  @spec calendar_day_meetings(
          [Meeting.t()],
          Date.t(),
          String.t() | nil,
          {integer(), integer()}
        ) :: [Meeting.t()]
  def calendar_day_meetings(meetings, %Date{} = date, time_zone, window) do
    meetings
    |> calendar_day_events(date, time_zone, window, :day)
    |> Enum.map(fn {meeting, _placement} -> meeting end)
  end

  @doc """
  The state chip on a mobile meeting card — a word, never only a colour,
  so the state survives a monochrome reading. The four values are exactly
  `Meeting.statuses/0`; an unknown status falls through to its raw string
  rather than to a silent blank.
  """
  @spec calendar_card_status_label(String.t()) :: String.t()
  def calendar_card_status_label("live"), do: "Live"
  def calendar_card_status_label("scheduled"), do: "Scheduled"
  def calendar_card_status_label("ended"), do: "Ended"
  def calendar_card_status_label("cancelled"), do: "Cancelled"
  def calendar_card_status_label(other) when is_binary(other), do: other

  @doc """
  Semantic token slots for the card's state chip. `success` for live
  mirrors the calendar blocks' live accent; `primary` for scheduled
  mirrors their default accent; ended and cancelled are muted, since
  neither is something the reader can still join.
  """
  @spec calendar_card_status_class(String.t()) :: String.t()
  def calendar_card_status_class("live"), do: "border-success/40 bg-success/15 text-success"
  def calendar_card_status_class("scheduled"), do: "border-primary/40 bg-primary/15 text-primary"

  def calendar_card_status_class(_other),
    do: "border-edge bg-base-200 text-base-content/60"

  @doc """
  How many meetings the rendered WEEK actually draws.

  The seven day columns summed through `calendar_day_meeting_count/4`,
  so this counts placed BLOCKS and not rows: `place/4` answers `:skip`
  for a meeting that is cancelled, for one that was never scheduled, and
  for one whose local start date is not the column's — and it matches
  exactly one of the seven columns for every meeting it does place, so
  nothing is counted twice.

  Derived from the same function the grid draws with, deliberately. The
  header chip this feeds read `7 total` beside a grid holding 5 blocks,
  because it was `length(@meetings)` — every meeting row the LiveView had
  loaded, including the two the grid refuses to place. A count next to a
  grid is read as a count OF the grid.
  """
  @spec calendar_week_meeting_count(
          [Meeting.t()],
          Date.t(),
          String.t() | nil,
          {integer(), integer()}
        ) :: non_neg_integer()
  def calendar_week_meeting_count(meetings, %Date{} = anchor, time_zone, window) do
    anchor
    |> CalendarWindow.week_days()
    |> Enum.map(&calendar_day_meeting_count(meetings, &1, time_zone, window))
    |> Enum.sum()
  end

  @doc """
  The header chip beside the Calendar/Archive tabs — `No meetings this
  week`, `1 meeting this week`, `5 meetings this week`.

  It says "this week" because the number is about the rendered week, and
  the string it replaced (`7 total`) named no scope at all. Unlabelled
  was the other half of the defect: `total` invites the reader to take it
  as a fact about the whole surface, so a reader who counts the grid and
  gets a different number has no way to tell which of the two is lying.

  Pluralisation is borrowed from `calendar_day_count_label/1` rather than
  rewritten, so the chip and the day heading cannot disagree about how to
  say one.
  """
  @spec calendar_week_count_label(non_neg_integer()) :: String.t()
  def calendar_week_count_label(count) when is_integer(count) and count >= 0,
    do: "#{calendar_day_count_label(count)} this week"

  @doc """
  The now-line offsets for the mobile day column — a single-element list,
  or `[]`.

  Same two conditions as `calendar_now_line/4` on the desktop grid,
  asked of the ONE day on screen instead of each of seven: the line is a
  fact about today, so a day view showing Friday draws none.

  Both conditions are answered from the SAME injected instant — "is this
  today" and "where in the day" cannot come from two different readings
  of the clock without a beat existing on which they disagree.
  """
  @spec calendar_selected_now_line(
          Date.t(),
          String.t() | nil,
          {integer(), integer()},
          DateTime.t()
        ) :: [float()]
  def calendar_selected_now_line(%Date{} = selected, time_zone, window, %DateTime{} = now) do
    today? = Date.compare(selected, calendar_today_date(time_zone, now)) == :eq
    calendar_now_line(today?, time_zone, window, now)
  end

  defp month_abbrev(%Date{} = date), do: Calendar.strftime(date, "%b")

  # ── Meeting detail selection (task 019fb954-8ead stage 4) ────────────────

  @doc """
  The meeting the detail panel/sheet is open on, or `nil`.

  Resolved out of `@calendar_week_meetings` rather than re-queried, and
  that is the whole point: the panel can only ever describe a meeting the
  RENDERED WEEK contains. `select_meeting` carries an id from a block the
  grid drew, so the row is already loaded, and paging away from the week
  a selection was made in closes the panel rather than leaving it
  describing a meeting no longer on screen.

  It also means a `phx-value-id` naming any other row — the event is
  attacker-supplied by definition — resolves to `nil` and renders
  nothing, with no query issued for it.
  """
  @spec selected_meeting(map()) :: Meeting.t() | nil
  def selected_meeting(%{selected_meeting_id: nil}), do: nil

  def selected_meeting(%{selected_meeting_id: id, calendar_week_meetings: meetings})
      when is_binary(id) and is_list(meetings),
      do: Enum.find(meetings, &(&1.id == id))

  # ── The detail surface's invitee rows (task 019fb955-1d7b stage 5) ───────
  #
  # `invited_count/1` lived here until this stage. It answered `length(
  # list_invites(id))` for a chip beside the status tag; the rows now carry
  # their own `Invited · N` header, so the chip and the function behind it
  # were deleted rather than left to disagree with the list beneath them.

  @doc """
  The rows the detail surface's invitee list draws for `meeting`.

  `Meetings.list_invites/2` defaults to `include_revoked: false`, and that
  default is the whole reason no filtering happens here: a revoked invitee
  is precisely someone who is NOT invited, so drawing them would overstate
  the room to the one person looking at this panel to decide whether to
  chase anybody. Order is that function's — `inserted_at` ascending, `id`
  as a total tiebreak — so the list does not reshuffle between renders.

  ## Three queries, not three per row

  A rendered list asks three questions of every account-holding invitee:
  what is their name, what is their address, and are they external. All
  three are per-USER facts, and asking them a row at a time is a query per
  row on a surface that re-renders on every calendar event. So the users
  are preloaded in one round trip and
  `Platform.Tenancy.external_user_ids/1` answers the membership question
  for the whole list in a second.

  ## The producer agent row is not an invite and cannot be one

  `meeting_invites` carries `user_id` and `email` and no `agent_id`, so
  the agent that produces meetings has no row to be listed from. It is
  rendered from `Platform.Meetings.SenderSeed.get/0` instead, appended
  after the invites, and OMITTED ENTIRELY when that returns `nil` — which
  is the expected state wherever the meetings subsystem was never enabled.
  A synthesised placeholder would name an agent that cannot be messaged.

  It is also not the agent currently sitting in a meeting's chat space:
  `Chat.create_space/1` attaches the HISTORIAN to any space slugged
  `meeting-<uuid>`, which is a different agent doing a different job and
  is deliberately not drawn here.
  """
  @spec detail_invite_rows(Meeting.t()) :: [map()]
  def detail_invite_rows(%Meeting{} = meeting) do
    invites = Repo.preload(Meetings.list_invites(meeting.id), :user)

    external_ids =
      invites
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&is_nil/1)
      |> Tenancy.external_user_ids()

    Enum.map(invites, &invite_row(&1, meeting, external_ids)) ++ producer_rows()
  end

  defp invite_row(%Invite{} = invite, %Meeting{} = meeting, external_ids) do
    external? = is_binary(invite.user_id) and MapSet.member?(external_ids, invite.user_id)

    %{
      id: invite.id,
      name: invite_row_name(invite),
      subtitle: invite_row_subtitle(invite, external?),
      user_id: invite.user_id,
      email: invite_row_email(invite),
      expires_at: invite.expires_at,
      external: external?,
      agent: false,
      avatar_url: nil,
      removable: false,
      copy_url: invite_row_copy_url(meeting, invite)
    }
  end

  # The user's own record wins over `display_name`, which is only ever
  # what the host happened to type — `invite_user/3` says as much. A row
  # that can name nobody RAISES: `meeting_invites_identity_check` forbids
  # it at the database level, so reaching here means the check was dropped,
  # and a row rendered as a blank line is a person nobody notices is
  # missing.
  defp invite_row_name(%Invite{user: %User{} = user} = invite),
    do: user.name || user.email || invite.display_name || raise_nameless(invite)

  defp invite_row_name(%Invite{} = invite),
    do: invite.display_name || invite.email || raise_nameless(invite)

  defp raise_nameless(%Invite{} = invite) do
    raise ArgumentError,
          "meeting invite #{invite.id} names nobody: user_id, display_name and email are all nil"
  end

  # STATE, never explanation — the one line under a name says what is true
  # of this invitee right now:
  #
  #   * an external account-holder — their address, because "external" on
  #     its own does not say which org they came from;
  #   * an internal member — nothing. Their name is the whole fact.
  #   * a guest — how long their link has left, which is the only thing
  #     about a guest that changes on its own;
  #   * an external invite awaiting a grant — the address it was sent to,
  #     since there is no account to name yet.
  defp invite_row_subtitle(%Invite{user: %User{} = user}, true), do: user.email
  defp invite_row_subtitle(%Invite{user: %User{}}, false), do: nil

  defp invite_row_subtitle(%Invite{expires_at: %DateTime{} = expires_at}, _external?),
    do: guest_expiry_label(expires_at)

  defp invite_row_subtitle(%Invite{email: email}, _external?) when is_binary(email), do: email
  defp invite_row_subtitle(%Invite{}, _external?), do: nil

  @doc """
  How long a guest link has left — `expires in 24h`, `expires in <1h`, or
  `expired`.

  Whole hours and no minutes: the window is 24h by default and the reader
  is deciding whether to re-send, not timing anything.

  ## Rounded, not truncated — and why the sub-hour case is its own string

  `expires_at` is stamped as `now + 24h` and read back a few milliseconds
  later, so the remaining span is 23h59m59s. TRUNCATING that renders
  `expires in 23h` for a link minted a moment ago, which reads as though
  an hour had already been lost. Rounding renders `24h`, which is what the
  host was told when they minted it.

  Rounding UP is the direction that misleads — it would let a link with
  four minutes left claim an hour — so the sub-hour span does not go
  through the hours form at all. `expires in <1h` says the one thing that
  matters about it without overstating. Past due gets its own string for
  the same reason in the other direction: `list_invites/2` filters revoked
  rows and NOT expired ones, so a dead link is reachable here, and
  `expires in 0h` reads as a live one.
  """
  @spec guest_expiry_label(DateTime.t()) :: String.t()
  def guest_expiry_label(%DateTime{} = expires_at) do
    case DateTime.diff(expires_at, DateTime.utc_now(), :second) do
      seconds when seconds <= 0 -> "expired"
      seconds when seconds < 3600 -> "expires in <1h"
      seconds -> "expires in #{round(seconds / 3600)}h"
    end
  end

  # `email` on an account-holding row is whatever the host typed, and the
  # account is authoritative. Only the tag derivation reads this key, and
  # only for rows with no `user_id`.
  defp invite_row_email(%Invite{user: %User{} = user}), do: user.email
  defp invite_row_email(%Invite{email: email}), do: email

  # ONLY a guest row has a link to copy. An account-holder signs in as
  # themselves and an external invite awaiting a grant has no token at
  # all, so both get no control rather than one that copies something
  # that cannot admit anyone.
  defp invite_row_copy_url(
         %Meeting{} = meeting,
         %Invite{user_id: nil, expires_at: %DateTime{}} = i
       ),
       do: Meetings.guest_invite_link(meeting, i)

  defp invite_row_copy_url(%Meeting{}, %Invite{}), do: nil

  # Display-only, no remove control, and absent when the seed is absent.
  defp producer_rows do
    case SenderSeed.get() do
      %Agent{} = agent ->
        [
          %{
            id: "agent:" <> agent.id,
            name: agent.name,
            subtitle: "meeting producer",
            user_id: nil,
            email: nil,
            expires_at: nil,
            external: nil,
            agent: true,
            # Stage 4 left this hardcoded nil with a real `%Agent{}` in hand and
            # flagged it. The producer is an agent appearing in the roster, so
            # it belongs to "render the face everywhere an agent appears".
            avatar_url: agent.avatar_url,
            removable: false,
            copy_url: nil
          }
        ]

      nil ->
        []
    end
  end

  # ── Archive half of the index (task 019fb954-c848) ───────────────────────
  #
  # The index has two halves — the calendar ("what is coming up?") and the
  # archive ("what came out of what already happened?"). Which one is showing
  # is URL state (`?view=archive`), not a bare assign, so a reload, a shared
  # link and the browser's back button all land on the same half the reader
  # was looking at. Every filter (`q`, `types`, `person_id`, `project_id`)
  # rides the same URL for the same reason: an archive search that cannot be
  # pasted to someone else is half a feature.
  #
  # The index's own meetings list is deliberately NOT the source here. Even
  # now that it is viewer-scoped it is unbounded in time and carries no
  # filters, and the archive is a viewer-facing SEARCH — `Archive.search/2`
  # does its own org narrowing over the fields being searched.
  defp assign_archive(socket, params) do
    view = archive_view(params)
    query = archive_param(params, "q") || ""
    types = archive_param_types(params)
    person_id = archive_param(params, "person_id")
    project_id = archive_param(params, "project_id")

    socket
    |> assign(:meetings_view, view)
    |> assign(:archive_query, query)
    |> assign(:archive_types, types)
    |> assign(:archive_person_id, person_id)
    |> assign(:archive_project_id, project_id)
    |> assign(:archive_time_zone, socket.assigns[:calendar_time_zone] || "Etc/UTC")
    |> assign_archive_result(view, query, types, person_id, project_id)
  end

  # The calendar half pays for nothing the archive needs. `nil` rather than an
  # empty result map so a template that reads `@archive_result` on the
  # calendar half fails loudly instead of rendering a confident "0 of 0".
  defp assign_archive_result(socket, :calendar, _query, _types, _person_id, _project_id) do
    socket
    |> assign(:archive_result, nil)
    |> assign(:archive_artifacts, %{})
  end

  defp assign_archive_result(socket, :archive, query, types, person_id, project_id) do
    # The viewer is the USER RECORD, not `:current_user` — that assign holds a
    # display STRING (see `PlatformWeb.ShellLive.on_mount/4`), and handing a
    # string to `Archive.search/2` would land in its `viewer_org_ids(_)`
    # fallback and silently return an empty archive to everyone.
    viewer = socket.assigns[:current_user_record]

    result =
      Archive.search(viewer,
        query: query,
        types: types,
        person_id: person_id,
        project_id: project_id
      )

    socket
    |> assign(:archive_result, result)
    |> assign(:archive_artifacts, Archive.artifacts_for(viewer, result.matches ++ result.others))
  end

  defp archive_view(%{"view" => "archive"}), do: :archive
  defp archive_view(_params), do: :calendar

  defp archive_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  # A comma list of `Archive.types/0` names. Unknown names are dropped rather
  # than raised on: this is a URL a human can hand-edit, and the empty list
  # already means "search everything", so a typo degrades to the default view
  # rather than to a 500.
  defp archive_param_types(params) do
    known = Map.new(Archive.types(), &{Atom.to_string(&1), &1})

    case archive_param(params, "types") do
      nil ->
        []

      types ->
        types
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.flat_map(&List.wrap(Map.get(known, &1)))
        |> Enum.uniq()
    end
  end

  # ── Archive URL building ─────────────────────────────────────────────────
  #
  # One builder for every archive link and for the filter form's `push_patch`,
  # so a control can never drop a filter another control set. `overrides` is a
  # string-keyed map; an explicit `nil` CLEARS the parameter (the reject below
  # strips it), which is how "deselect this chip" is expressed.
  defp archive_path(assigns, overrides \\ %{}) do
    params =
      %{
        "view" => "archive",
        "q" => Map.get(overrides, "q", assigns.archive_query),
        "types" => Map.get(overrides, "types", archive_types_param(assigns.archive_types)),
        "person_id" => Map.get(overrides, "person_id", assigns.archive_person_id),
        "project_id" => Map.get(overrides, "project_id", assigns.archive_project_id)
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/meetings?#{params}"
  end

  # ── Meetings-view shelf (Calendar · Archive) ─────────────────────────────
  #
  # One data structure drives the index's top-level view switcher, so it reads
  # as a single styled, extensible shelf and a future view is one more entry
  # here (plus a `meetings_view_path/2` clause) rather than another
  # hand-copied `<.link>`. Each entry carries its own hero-icon and a label;
  # `id` is the `data-view` test contract, `short_label` is the phone label.
  # The glyph names are string literals so Tailwind's `matchComponents`
  # scanner emits their CSS — a computed name would render blank.
  @meetings_view_shelf [
    %{id: :calendar, label: "Calendar", short_label: "Cal", icon: "hero-calendar-days"},
    %{id: :archive, label: "Archive", short_label: "Archive", icon: "hero-archive-box"}
  ]

  @doc "The meetings index view-switcher entries, in display order."
  def meetings_view_shelf, do: @meetings_view_shelf

  # Each segment patches to its own URL: Calendar to the bare index (which
  # defaults to the calendar half and carries no dead `view=` param), Archive
  # through `archive_path/1` so it preserves whatever filters are active.
  defp meetings_view_path(_assigns, :calendar), do: ~p"/meetings"
  defp meetings_view_path(assigns, :archive), do: archive_path(assigns)

  # A key the form did not send is left alone; a key it sent EMPTY is cleared
  # (`archive_param/2` normalises blank to `nil`, and `archive_path/2` strips
  # nils out of the query string).
  defp archive_override(overrides, params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> Map.put(overrides, key, archive_param(params, key))
      _ -> overrides
    end
  end

  defp archive_types_param([]), do: nil
  defp archive_types_param(types), do: types |> Enum.map(&Atom.to_string/1) |> Enum.join(",")

  # Toggling a type chip. Selecting none is the same query as selecting all
  # (`Archive.search/2` normalises `[]` to every type), so the "all off" state
  # is represented by dropping the parameter entirely rather than by an empty
  # `types=` that would have to be special-cased on the way back in.
  defp archive_toggle_types_path(assigns, type) do
    next =
      if type in assigns.archive_types do
        List.delete(assigns.archive_types, type)
      else
        assigns.archive_types ++ [type]
      end

    archive_path(assigns, %{"types" => archive_types_param(next)})
  end

  # The person filter is a two-state toggle (Anyone / Just me) rather than a
  # picker: `person_id` is honoured from the URL for any user id, so a link
  # naming someone else still works, but this codebase has no viewer-scoped
  # people list to populate a dropdown from, and inventing one here would be
  # a second, unaudited answer to "who may this viewer see?".
  defp archive_person_path(assigns) do
    next = if assigns.archive_person_id, do: nil, else: assigns[:current_user_id]

    archive_path(assigns, %{"person_id" => next})
  end

  # The no-matches state's one control: back to the whole archive. It clears
  # the QUERY AND every filter, because the state it exits is reachable from
  # any combination of them and a control that cleared only the query would
  # leave the reader in the same place it just told them was empty.
  defp archive_clear_path(assigns) do
    archive_path(assigns, %{
      "q" => nil,
      "types" => nil,
      "person_id" => nil,
      "project_id" => nil
    })
  end

  # ── The archive's two empty states ───────────────────────────────────────
  #
  # They are two ANSWERS, not two renderings of one answer, and the whole
  # point of this pair is that they never both hold:
  #
  #   * nothing archived AT ALL — `unfiltered_total` is what says so, not
  #     `total`, which already has the person and project filters applied and
  #     so reads zero for a filter that excluded everything.
  #   * archived meetings exist, this query/filter set reached none of them.
  #     With a query that is `matched == 0`; with a blank query there is no
  #     matched partition at all (see `Archive`'s moduledoc) and the filters
  #     having emptied the in-scope set is the same statement.
  #
  # A blank query over an unfiltered archive with meetings in it is NEITHER:
  # the full list under "Also in this range, no match" is the answer.
  defp archive_no_meetings?(%{unfiltered_total: 0}), do: true
  defp archive_no_meetings?(_result), do: false

  defp archive_no_matches?(%{unfiltered_total: 0}), do: false
  defp archive_no_matches?(%{query: "", total: total}), do: total == 0
  defp archive_no_matches?(%{matched: matched}), do: matched == 0

  # ── Archive labels ───────────────────────────────────────────────────────

  # "2 of 47 · filtered" — MATCHED of total. A bare total answers a question
  # nobody asked: the reader already knows the archive is big, what they want
  # to know is how much of it their query reached. The un-queried archive has
  # no matched partition at all (see `Archive`'s moduledoc on why blank is a
  # different state from zero matches), so it reads as a plain total.
  defp archive_count_label(%{query: "", total: total}, _suffix), do: "#{total} archived"

  defp archive_count_label(%{matched: matched, total: total}, suffix),
    do: "#{matched} of #{total} · #{suffix}"

  defp archive_sort_label(%{query: ""}), do: "sorted by date"
  defp archive_sort_label(_result), do: "sorted by relevance"

  defp archive_type_label(:canvases), do: "Canvases"
  defp archive_type_label(:summaries), do: "Summaries"
  defp archive_type_label(:action_items), do: "Action items"
  defp archive_type_label(:transcripts), do: "Transcripts"

  # Mobile truncates the longest label rather than letting CSS clip it —
  # `Act…` is the design's own abbreviation, and an ellipsis the browser
  # chose would land in a different place at every text size.
  defp archive_type_short_label(:action_items), do: "Act…"
  defp archive_type_short_label(type), do: archive_type_label(type)

  defp archive_type_icon(:canvases), do: "hero-squares-2x2"
  defp archive_type_icon(:summaries), do: "hero-document-text"
  defp archive_type_icon(:action_items), do: "hero-check-circle"
  defp archive_type_icon(:transcripts), do: "hero-chat-bubble-left-ellipsis"

  defp archive_chip_icon(:canvas), do: "hero-squares-2x2"
  defp archive_chip_icon(:summary), do: "hero-document-text"
  defp archive_chip_icon(:action_items), do: "hero-check-circle"
  defp archive_chip_icon(:transcript), do: "hero-chat-bubble-left-ellipsis"

  # Colour is TYPE, expressed in semantic token slots. The mock's hex values
  # are scaffolding — a canvas chip is "the accent thing", not "#8b5cf6".
  defp archive_chip_class(:canvas), do: "border-secondary/40 bg-secondary/10 text-secondary"
  defp archive_chip_class(:summary), do: "border-primary/30 bg-primary/10 text-primary"
  defp archive_chip_class(:action_items), do: "border-warning/30 bg-warning/10 text-warning"
  defp archive_chip_class(:transcript), do: "border-edge bg-base-200 text-base-content/60"

  # Mobile shortens the chips that CARRY a short form — `artifacts_for/2`
  # ships `:short_label` on the action-item chip precisely so the phone does
  # not have to guess at one. A canvas chip has none, and it should not: its
  # label is the canvas's own title plus its revision span, and trimming a
  # word off a title the user chose is mangling their data, not abbreviating.
  # `nil` means "the full label is already the short one".
  defp archive_chip_short_label(%{short_label: short_label}), do: short_label
  defp archive_chip_short_label(_chip), do: nil

  # The two result sections. A BLANK query has no matched partition at all
  # (`Archive`'s moduledoc: blank is a different state from zero matches), so
  # it renders as one undivided list rather than as an empty "Matches" plus
  # everything under a heading that would be claiming they failed to match.
  defp archive_sections(%{total: 0}), do: []

  defp archive_sections(%{query: ""} = result) do
    [%{key: "others", heading: nil, rows: result.others, dim?: false}]
  end

  # A section with no rows is DROPPED rather than rendered as a bare heading.
  # "Matches" over nothing, sitting directly above an empty state that says
  # "No matches", is the same fact told twice in two registers — and the one
  # in the smaller type is the one that reads as a bug.
  defp archive_sections(result) do
    [
      %{key: "matches", heading: "Matches", rows: result.matches, dim?: false},
      %{
        key: "others",
        heading: "Also in this range, no match",
        rows: result.others,
        dim?: true
      }
    ]
    |> Enum.reject(&(&1.rows == []))
  end

  defp archive_person_label(%{archive_person_id: nil}), do: "Anyone"
  defp archive_person_label(%{archive_person_id: id, current_user_id: id}), do: "Just me"
  defp archive_person_label(_assigns), do: "One person"

  # A meeting the viewer may not see is ABSENT from `artifacts_for/2`'s map —
  # that is the function's contract, not an error. The correct render for an
  # absent key is a row with no artifacts, so the default is a real empty
  # payload rather than a `Map.fetch!` that would 500 on a stale URL.
  defp archive_artifacts(artifacts, %{id: id}) do
    Map.get(artifacts, id, %{
      chips: [],
      duration_minutes: nil,
      host_name: nil,
      attendee_count: 0,
      project_path: "",
      cancelled_by_name: nil,
      cancellation_notified_at: nil
    })
  end

  # The row's date is when it LEFT the calendar: ended, or — for a meeting
  # that never ran — cancelled. Same `coalesce` the archive's `:others`
  # partition orders by, so the gutter cannot disagree with the sort.
  defp archive_row_at(%{ended_at: %DateTime{} = at}), do: at
  defp archive_row_at(%{cancelled_at: %DateTime{} = at}), do: at
  defp archive_row_at(%{scheduled_start_at: %DateTime{} = at}), do: at
  defp archive_row_at(_entry), do: nil

  defp archive_row_month(entry, time_zone), do: archive_strftime(entry, time_zone, "%b")
  defp archive_row_day(entry, time_zone), do: archive_strftime(entry, time_zone, "%-d")
  defp archive_row_date(entry, time_zone), do: archive_strftime(entry, time_zone, "%b %-d")

  defp archive_strftime(entry, time_zone, format) do
    case archive_row_at(entry) do
      nil ->
        ""

      %DateTime{} = at ->
        case DateTime.shift_zone(at, time_zone) do
          {:ok, shifted} -> Calendar.strftime(shifted, format)
          {:error, _reason} -> Calendar.strftime(at, format)
        end
    end
  end

  # "52 min · hosted by Rowan · 5 attended · Suite / Control Center". A
  # cancelled meeting has no duration (it never ran), and saying so is the
  # first thing the subtitle owes the reader.
  defp archive_row_subtitle(entry, artifacts) do
    (archive_cancelled_parts(entry, artifacts) ++
       [
         archive_duration_part(entry, artifacts),
         archive_host_part(artifacts),
         archive_attended_part(artifacts),
         archive_project_part(artifacts)
       ])
    |> archive_join_parts()
  end

  # Mobile drops host and project — the two parts a phone-width row cannot
  # show without wrapping — and folds the date gutter in at the front.
  defp archive_row_mobile_subtitle(entry, artifacts, time_zone) do
    ([archive_row_date(entry, time_zone)] ++
       archive_cancelled_parts(entry, artifacts) ++
       [
         archive_duration_part(entry, artifacts),
         archive_attended_part(artifacts)
       ])
    |> archive_join_parts()
  end

  defp archive_join_parts(parts) do
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  # "Cancelled by Rowan · attendees notified" — the design's third row.
  #
  # THE MISSING NUMBER IS DELIBERATE. The mock reads "4 notified in chat", and
  # nothing on this branch can answer that 4 as a FACT about this
  # cancellation. `meetings.cancellation_notified_at` is a bare timestamp with
  # no recipient list beside it, and the only public function that resolves
  # recipients — `Platform.Meetings.recipients_for_meeting/1` — answers who
  # would be notified NOW, not who was notified THEN, and falls back to every
  # human in the chat space when the invite list comes back empty. Revoking
  # the last invitee therefore WIDENS its count, which is the one case the
  # sponsor has not ruled on. A number that is right in the ordinary case and
  # silently wrong in the contested one is worse here than no number: the
  # reader cannot tell which they are looking at. So the count is omitted and
  # the fact that a notification happened is not.
  #
  # A `nil` `cancellation_notified_at` renders WITHOUT the notified clause —
  # claiming a fan-out that never ran is the same lie in the other direction.
  # A `nil` `cancelled_by_name` renders a bare "Cancelled": the FK nilifies
  # rather than cascades, so an absent canceller is a real state.
  defp archive_cancelled_parts(%{status: "cancelled"}, artifacts) do
    [archive_cancelled_by_part(artifacts), archive_notified_part(artifacts)]
  end

  defp archive_cancelled_parts(_entry, _artifacts), do: []

  defp archive_cancelled_by_part(%{cancelled_by_name: name}) when is_binary(name) and name != "",
    do: "Cancelled by #{name}"

  defp archive_cancelled_by_part(_artifacts), do: "Cancelled"

  defp archive_notified_part(%{cancellation_notified_at: %DateTime{}}), do: "attendees notified"
  defp archive_notified_part(_artifacts), do: nil

  defp archive_duration_part(%{status: "cancelled"}, _artifacts), do: nil
  defp archive_duration_part(_entry, %{duration_minutes: nil}), do: nil
  defp archive_duration_part(_entry, %{duration_minutes: minutes}), do: "#{minutes} min"

  defp archive_host_part(%{host_name: nil}), do: nil
  defp archive_host_part(%{host_name: ""}), do: nil
  defp archive_host_part(%{host_name: host_name}), do: "hosted by #{host_name}"

  defp archive_attended_part(%{attendee_count: count}) when is_integer(count) and count > 0,
    do: "#{count} attended"

  defp archive_attended_part(_artifacts), do: nil

  defp archive_project_part(%{project_path: path}) when is_binary(path) and path != "", do: path
  defp archive_project_part(_artifacts), do: nil

  # The design's overlapping stack, one ring per attendee up to four. The
  # rings carry a generic person glyph rather than initials: `artifacts_for/2`
  # returns a COUNT, not identities, and initials derived from anything else
  # would be a second answer to "who was in this meeting" that nobody
  # authorised.
  defp archive_attendee_rings(%{attendee_count: count}) when is_integer(count) and count > 0,
    do: Enum.to_list(1..min(count, 4))

  defp archive_attendee_rings(_artifacts), do: []

  defp archive_attendee_overflow(%{attendee_count: count}) when is_integer(count) and count > 4,
    do: count - 4

  defp archive_attendee_overflow(_artifacts), do: 0

  # ── Events ───────────────────────────────────────────────────────────────

  @impl true
  # Invite an agent into the LIVE call (task 01a04c2f).
  #
  # `Meetings.invite_agent/3` existed with zero callers, so nothing in the
  # product could put an agent in a meeting; this handler and the rail control
  # it is wired to are that missing edge.
  #
  # Three ids matter here and only one of them comes from the client:
  #
  #   * the SPACE is `@meeting.chat_space_id`, a server assign resolved by
  #     `handle_params/3`'s authorization gate. It is never read from params —
  #     a client-supplied space id is the exact defect
  #     `Platform.Chat.SpaceAccess`'s moduledoc was written about.
  #   * the ROOM is whatever `get_active_room/1` answers for that space. Read,
  #     not created: `ensure_room/1` + `activate_room/1` would write rows for a
  #     caller who has not been authorized yet, since the authorization lives
  #     inside `invite_agent/3` and needs the room to name the space. No active
  #     room means no live call, and there is nothing to invite an agent into.
  #   * the AGENT id is the one client value, and it is resolved against
  #     `@invitable_agents` — the list this socket just rendered — rather than
  #     against the `agents` table. Same rule `deliver_live_invite/4` applies
  #     to its `"user"` kind one screen over.
  #
  # Authorization is NOT repeated here. `invite_agent/3` composes
  # `SpaceAccess.authorize_writer/2` itself, and `{:error, :forbidden}` is
  # given its own clause so a permission denial reads differently from a
  # changeset failure.
  def handle_event("meeting_invite_agent", %{"agent-id" => agent_id}, socket)
      when is_binary(agent_id) do
    {:noreply, invite_agent_into_call(socket, agent_id)}
  end

  # "Show me the discussion" (task 01a084bf stage 3). This used to toggle
  # `:chat_panel_open` for `#meeting-chat-drawer`; that drawer is deleted
  # and chat is a PANE of the call rail, so the event was re-pointed rather
  # than removed — the top bar still pushes it, and so does the collapsed
  # strip's Chat control by way of `meeting_tab_select` +
  # `toggle_meeting_chat_pane`.
  #
  # IT OPENS, IT DOES NOT TOGGLE. The old handler flipped a boolean, which
  # was defensible when the target was a drawer that owned the whole
  # viewport. The target is now one tab among four, and "toggle" would mean
  # a second click closes the rail or deselects Chat — leaving the viewer on
  # no tab at all, or collapsing a rail they may have opened for People.
  # Asking for chat twice asks for the same thing twice.
  #
  # THREE ASSIGNS, ONE PER BREAKPOINT CONCERN:
  #   * `:active_meeting_tab` — the rail renders Chat.
  #   * `:chat_panel_collapsed` — false, so at `lg` the rail is expanded
  #     rather than the 44px strip. This is the desktop-only concern.
  #   * `:call_rail_open` — true, so below `lg` the rail drawer slides in.
  #     Harmless at `lg`, where the rail is an in-flow column and this
  #     assign is not consulted.
  #
  # `:call_rail_animate` is true because the viewer asked for this width
  # change themselves, which is exactly the distinction 01a0740d drew, and
  # the `push_event` persists the un-collapse to the same localStorage host
  # the chevron writes to — otherwise opening chat here would silently
  # disagree with the stored preference on the next mount.
  #
  # Opening chat CLEARS `:call_rail_unread` (task 01a0740d): the messages
  # are on screen, so the marker has nothing left to say. Unlike the old
  # handler this is unconditional, because there is no longer a "closing"
  # result that would wipe the dot at the moment it should start counting
  # again.
  def handle_event("toggle_chat_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:active_meeting_tab, "chat")
     |> assign(:chat_panel_collapsed, false)
     |> assign(:call_rail_open, true)
     |> assign(:call_rail_animate, true)
     |> assign(:call_rail_unread, false)
     |> push_event("meeting_chat_pane_collapsed_changed", %{collapsed: false})}
  end

  # Mobile call-rail drawer (task 01a05b14 stage 6). `lg:hidden` control;
  # at `lg` the rail is an in-flow column and this state is not consulted.
  #
  # The mutual exclusion with `:chat_panel_open` is gone with the chat
  # drawer (task 01a084bf stage 3). There was only ever one reason for it —
  # two `<lg` drawers sliding in from the same edge at the same `z-40`
  # could stack one unreachably behind the other — and there is now exactly
  # one such drawer, which holds the chat as a tab.
  def handle_event("toggle_call_rail", _params, socket) do
    {:noreply, assign(socket, :call_rail_open, !socket.assigns.call_rail_open)}
  end

  # The sheet's `on_close` (task 01a07410 stage 3). CLOSES, never toggles:
  # the `Sheet` hook pushes this on Escape and the backdrop and the close
  # button push it on click, and any of those arriving twice must leave
  # the sheet shut rather than reopening it.
  def handle_event("close_call_rail", _params, socket) do
    {:noreply, assign(socket, :call_rail_open, false)}
  end

  # A named mobile sheet (task 01a07410 stage 3): `"cards"`, `"chat"` or
  # `"invite"` — the three surfaces the ticket names — as STATES of the one
  # rail sheet, so the launcher says which pane it wants and the sheet
  # opens already pointed at it. The shut sheet's countdown handle pushes
  # `"cards"`. Chat clears the unread dot for the same reason
  # `meeting_tab_select` does: the messages are about to be on screen.
  def handle_event("open_mobile_sheet", %{"sheet" => sheet}, socket) do
    tab = CallRailFrame.tab_for_sheet(sheet)

    socket =
      socket
      |> assign(:active_meeting_tab, tab)
      |> assign(:call_rail_open, true)

    socket = if tab == "chat", do: assign(socket, :call_rail_unread, false), else: socket

    {:noreply, socket}
  end

  # The `ViewportBreakpoint` hook's report (task 01a07410 stage 3). `below`
  # is the only fact the server needs — which wrapper the rail renders in.
  # Anything but a literal boolean is ignored rather than coerced: a
  # malformed payload must not flip the rail into the wrong frame.
  def handle_event("meeting_viewport", %{"below" => below}, socket) when is_boolean(below) do
    {:noreply, assign(socket, :mobile_viewport?, below)}
  end

  def handle_event("meeting_viewport", _params, socket), do: {:noreply, socket}

  # The recap's own close control (task 01a07410 stage 6). Rejoining
  # clears it too, through `attach_call_recap_hook/1`.
  def handle_event("dismiss_call_recap", _params, socket) do
    {:noreply, assign(socket, :call_recap, nil)}
  end

  # Right-rail tab select (task 01a05b14 stage 3). An unrecognised tab
  # is normalised by `CallShell.call_rail/1` itself rather than being
  # rejected here, so a stale value costs the tab, not the pane.
  #
  # SELECTING CHAT CLEARS THE UNREAD DOT (task 01a084bf stage 3). Chat is a
  # tab now, so arriving at it by clicking the tab — or by the collapsed
  # strip's chained `meeting_tab_select` + `toggle_meeting_chat_pane` — is
  # the same act of reading the messages that `"toggle_chat_panel"` performs
  # from the top bar. Normalised before comparing, because `tab` is assigned
  # from a URL param behind nothing stronger than `is_binary/1` and a junk
  # value renders People.
  #
  # THIS CLAUSE IS DEAD ON `/meetings`, AND THAT IS WHY IT STILL READS THE
  # VOCABULARY (task 01a089fe stage 3, which gated the `<:chat>` slot and was
  # handed this call site as a follow-on). `MeetingHooks.attach/2` — called
  # from the `:show` `handle_params/3` — installs a `"meeting_tab_select"`
  # hook that `{:halt, …}`s, so on the shell and `:meet_member` mounts the
  # clause that actually services this event, and actually clears the dot, is
  # `PlatformWeb.ChatLive.MeetingHooks.handle_event/3`. 01a084bf stage 4
  # measured that by mutation: deleting the clear from here reds nothing,
  # deleting it from there reds three tests. Changing THIS line therefore
  # changes nothing anybody can observe on either of those surfaces; the live
  # twin calls `normalize_tab/1` too, and correcting THAT reds an existing
  # `:meet_member` test — see the note on `chat_on_screen?/1` for the
  # measurement and for why it is reported rather than fixed here.
  #
  # It is live on exactly one surface: the GUEST mount, whose `handle_params/3`
  # no-ops on `:state` and so never attaches the hook. And on that surface
  # both effects are unobservable — a guest holds no `chat:space:<id>`
  # subscription, so `:call_rail_unread` can never be true for this to clear,
  # and no `"chat"` entry exists in either tab loop to render it if it were.
  def handle_event("meeting_tab_select", %{"tab" => tab}, socket) when is_binary(tab) do
    socket = assign(socket, :active_meeting_tab, tab)

    socket =
      if CallShell.normalize_tab(tab) == "chat",
        do: assign(socket, :call_rail_unread, false),
        else: socket

    {:noreply, socket}
  end

  # `toggle_participant_rail` and `meeting_participant_rail_hydrate` were
  # DELETED with the left rail (task 01a05b14 stage 3), together with the
  # `data-storage-key="suite.meeting.participant_rail.collapsed"` host
  # that drove them. Removing one without the other would have left a
  # live `SidebarCollapse` hook pushing at a missing handler.

  # Desktop call-rail collapse (task 019e40f2). Strictly DESKTOP — the
  # `<lg` drawer latch is `:call_rail_open`. Same shape as the retired
  # `toggle_participant_rail` (see above).
  #
  # THE ONE PATH THAT ANIMATES (task 01a0740d). `:call_rail_animate` is set
  # `true` here and `false` on every mode-driven reassert, because this is
  # the only width change the viewer asked for.
  def handle_event("toggle_meeting_chat_pane", _params, socket) do
    next = !socket.assigns.chat_panel_collapsed

    {:noreply,
     socket
     |> assign(:chat_panel_collapsed, next)
     |> assign(:call_rail_animate, true)
     |> push_event("meeting_chat_pane_collapsed_changed", %{collapsed: next})}
  end

  def handle_event("meeting_chat_pane_hydrate", %{"collapsed" => collapsed}, socket)
      when is_boolean(collapsed) do
    if collapsed == socket.assigns.chat_panel_collapsed do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :chat_panel_collapsed, collapsed)}
    end
  end

  # Closed-captions toggle (task 019f3f17 stage 1). Originally distinct-
  # named from a shell `toggle_captions` handler to sidestep the shell
  # hook that would swallow the event. Task 019f43da deleted the shell
  # duplicate (button + overlay + assign + handler) — MeetingLive is now
  # the sole writer of caption state. Kept the `_meeting` suffix on the
  # event name to avoid rebase churn in `meeting_live_test.exs` and the
  # `MeetingCaptions` JS hook. The client-side hook mirrors the preference
  # to localStorage on the push_event round-trip so the viewer's choice
  # survives navigation.
  def handle_event("toggle_captions_meeting", _params, socket) do
    next = !socket.assigns.captions_visible

    {:noreply,
     socket
     |> assign(:captions_visible, next)
     |> push_event("meeting_captions_persist", %{visible: next})}
  end

  # Restore the persisted preference on hook-mount from localStorage.
  # Idempotent: skips the re-render when the stored value matches the
  # current assign so a hydrate on every reconnect doesn't churn state.
  def handle_event("meeting_captions_hydrate", %{"visible" => visible}, socket)
      when is_boolean(visible) do
    if visible == socket.assigns.captions_visible do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :captions_visible, visible)}
    end
  end

  # Caption-stall signal (task 01a0cf5c stage 2). Fired once per stall
  # episode by the `MeetingCaptions` hook's `_reportStall`, the moment the
  # bar enters state 3 (STALLED) — never per tick, never per re-render.
  #
  # WHY THIS EXISTS: the production incident that opened task 01a0cf5c
  # could not be root-caused with confidence because nothing durable
  # recorded when the bar told a viewer their captions were broken versus
  # merely late. A browser console line does not survive to be read after
  # the fact. This is a low-cardinality operator log line, not a new
  # assign and not a broadcast — VIEWER-LOCAL, same posture as
  # `meeting_speaking_update` below, for the same reason: each connected
  # client's captions state is its own.
  def handle_event("meeting_captions_stalled", params, socket) do
    meeting_id =
      Map.get(params, "meeting_id") || (socket.assigns[:meeting] && socket.assigns.meeting.id)

    elapsed_ms = Map.get(params, "elapsed_ms")

    Logger.warning(
      "Meeting captions bar entered the STALLED state: sustained speech with " <>
        "no caption arriving for the confirmation window. meeting_id=" <>
        to_string(meeting_id) <> " elapsed_ms=" <> to_string(elapsed_ms)
    )

    {:noreply, socket}
  end

  # Active speakers reported by the viewer's own LiveKit client via the
  # `MeetingRoom` hook. VIEWER-LOCAL presentation state: not persisted, not
  # broadcast. Each connected client runs its own LiveKit room and reports
  # what IT hears, so broadcasting one viewer's set over the others would
  # be actively wrong.
  #
  # The push arrives on the ROOT LiveView, not a component: a JS hook's
  # `pushEvent` ignores `phx-target`, and `MeetingRoom` is mounted on
  # `#meeting-room` inside this LiveView. Keep this handler here.
  #
  # The hook already debounces (250ms trailing + identity-set equality), so
  # this is not a hot path; the MapSet rebuild is cheap and idempotent.
  #
  # ONE implementation for both surfaces: `MeetingHooks.apply_active_speakers/2`
  # (task 01a05b14 stage 5). The attached `MeetingHooks` handle_event hook
  # already halts this event with that function on the authenticated
  # surface, so this clause is reached only where the hook is not the
  # authenticated one (the guest ingress, whose hook also delegates) or if
  # the hook is ever detached. A malformed payload is tolerated there too.
  def handle_event("active_speakers", params, socket) do
    {:noreply, MeetingHooks.apply_active_speakers(socket, params)}
  end

  # Per-identity remote mic/camera state, pushed by `MeetingClient`
  # (`_pushMediaStates`) on `RoomEvent.TrackMuted` / `TrackUnmuted`. Same
  # ONE-implementation arrangement as `active_speakers` above:
  # `MeetingHooks` is attached and halts this event first on the
  # authenticated and guest surfaces, so this clause is the fallback for a
  # detached hook. Malformed payloads are tolerated there too.
  def handle_event("media_states", params, socket) do
    {:noreply, MeetingHooks.apply_media_states(socket, params)}
  end

  # Stage-mode switching (ADR 0042). The segmented control in the top bar
  # pushes `set_stage_mode` with the target mode as a string. We clamp to
  # the four known modes (`stage_modes/0`) — any unknown value is ignored
  # so a hand-crafted phx-click can't crash the LV or assign a bogus mode.
  # Switching is pure presentation: the center stage swaps which renderer
  # it shows, but the other modes' underlying state (canvas LV, screen-
  # share track, video feeds) is untouched.
  def handle_event("set_stage_mode", %{"mode" => mode}, socket) do
    case parse_stage_mode(mode) do
      {:ok, stage_mode} ->
        # v2 (task 019e42f6): the local self-view <video> is reparented by
        # the page-level `MeetingClient` hook into the dock for the now-active
        # mode (gallery tile vs. bottom strip). The bare `assign` alone gives
        # JS no race-free trigger — the per-mode tiles remount on the LV patch
        # in an unpredictable order, so a hook `updated()` can't be relied on.
        # Push an explicit named event to the always-mounted page hook (which
        # holds `window.__livekit_room`) so relocation fires exactly once per
        # switch. Mirrors the `*_collapsed_changed` push_event idiom above
        # (lines ~311 / ~334).
        # Task 01a0740d: the new mode REASSERTS its rail default, so it wins
        # over whatever the viewer last toggled by hand. The
        # `meeting_chat_pane_collapsed_changed` push keeps the localStorage
        # copy in step — without it the hydrate handler would restore a
        # stale manual value on the next mount and the default would look
        # like it never applied.
        collapsed = default_rail_collapsed?(stage_mode)

        {:noreply,
         socket
         |> assign(:current_stage_mode, stage_mode)
         |> assign(:chat_panel_collapsed, collapsed)
         |> assign(:call_rail_animate, false)
         |> push_event("meeting_stage_mode_changed", %{mode: Atom.to_string(stage_mode)})
         |> push_event("meeting_chat_pane_collapsed_changed", %{collapsed: collapsed})}

      :error ->
        # Unknown mode — keep `:current_stage_mode` unchanged. No
        # FunctionClauseError, no flash; the click is simply a no-op.
        # It reasserts NOTHING either (task 01a0740d): a hand-crafted
        # phx-click naming a bogus mode must not be able to shut the
        # viewer's rail.
        {:noreply, socket}
    end
  end

  # Canvas picker (task 019ff704 stage 3). Records THIS viewer's choice of
  # which canvas the meeting surface shows.
  #
  # Per-socket only. The pick is a plain assign — no shared row, no
  # broadcast — for the same reason `:captions_visible` is: the choice is
  # about one person's view of the meeting, and making it shared would
  # let one participant's click yank everybody else's screen mid-call.
  # With the state living here, that yank is not merely disallowed, it is
  # unrepresentable.
  #
  # The id is CLAMPED to the loaded `:meeting_canvases`, mirroring
  # `parse_stage_mode/1`: an id that is not in the set is IGNORED and the
  # current selection stands. A hand-crafted phx-click therefore cannot
  # point this LV at a canvas in another space, nor blank the stage by
  # naming something that does not exist.
  def handle_event("canvas_open", %{"canvas-id" => canvas_id}, socket) do
    canvases = socket.assigns[:meeting_canvases] || []

    case Enum.find(canvases, fn c -> c.id == canvas_id end) do
      nil ->
        # Unknown id — selection unchanged, no crash, no flash.
        {:noreply, socket}

      canvas ->
        {:noreply,
         socket
         |> assign(:selected_canvas_id, canvas.id)
         |> assign(:meeting_canvas, canvas)
         # A deliberate switch is not a "this canvas just changed"
         # event: leaving the marker set would put the just-changed ring
         # on a tile the viewer themselves just opened.
         |> assign(:canvas_tile_changed?, false)
         # Selecting a canvas IS looking at it, so its news is spent.
         # Re-baselined at the revision it carries right now, not
         # cleared: a later edit to this same canvas must be able to
         # raise the dot again once the viewer moves off it.
         |> mark_canvas_seen(canvas)}
    end
  end

  # The picker's own group has exactly one member (this meeting's chat
  # space), but the toggle is still real: `CanvasExplorer` always renders a
  # clickable group header, so a click has to go somewhere rather than into
  # a handler that does not exist. Same shape as `CanvasHooks`'s own
  # `canvas_explorer_toggle_group` handler, kept local rather than shared
  # because this LiveView has no other use for that module's much larger
  # surface (multi-space drawer, search, sort, versions panel).
  def handle_event("canvas_explorer_toggle_group", %{"key" => key}, socket) do
    keys = socket.assigns[:canvas_explorer_expanded_keys] || []
    updated = if key in keys, do: List.delete(keys, key), else: [key | keys]
    {:noreply, assign(socket, :canvas_explorer_expanded_keys, updated)}
  end

  # Paging past the first `@canvas_explorer_page_size` canvases. The old
  # `<details>` list had no cap at all (a scrollable `max-h-64`), so this
  # exists to make sure a meeting with more canvases than the page size does
  # not silently lose the rest of them under the new, bounded component.
  # `Integer.parse` rather than `String.to_integer`: a hand-crafted
  # phx-click could send anything, and this is a viewer-scoped display
  # offset, not a value worth crashing the LiveView over — an unparsable or
  # negative offset is treated as "back to the start" rather than raising.
  def handle_event("canvas_explorer_page", %{"offset" => offset}, socket) do
    parsed =
      case Integer.parse(offset) do
        {n, ""} when n >= 0 -> n
        _ -> 0
      end

    {:noreply, assign(socket, :canvas_explorer_offset, parsed)}
  end

  # "Create canvas" CTA on the Canvas-mode empty state. Mints a fresh
  # blank canvas in the meeting's bound chat space (ADR 0036 canonical
  # document) and assigns it as the active `:meeting_canvas` so the
  # center stage flips from the empty-state CTA to the rendered canvas.
  # Re-uses `Chat.create_canvas_with_message/3` so the meeting's chat
  # thread carries a "canvas created" message — meetings ARE long-running
  # collaboration threads (ADR 0042), so the side-effect of a chat row is
  # a feature, not a leak.
  #
  # ## Participant requirement (no implicit join)
  #
  # `create_canvas_with_message/3` needs a participant_id to author both
  # the canvas (`created_by`) and the companion chat message
  # (`participant_id`). This handler used to *insert* the viewer as a
  # participant on the fly via `ensure_participant/2` — that made canvas
  # creation a join trigger, which was the wrong shape (ADR 0042: explicit
  # join is owned by the meeting bar / livekit hook, not by side-effects
  # of unrelated UI). We now refuse the create when the viewer has no
  # participant row and flash a hint to join first. The legitimate join
  # path is the meeting bar in a sibling stage.
  def handle_event("create_meeting_canvas", _params, socket) do
    %{meeting: meeting, user_id: user_id} = socket.assigns

    cond do
      is_nil(meeting) or is_nil(meeting.chat_space_id) ->
        {:noreply, socket}

      true ->
        case find_participant(meeting.chat_space_id, user_id) do
          nil ->
            {:noreply, put_flash(socket, :error, "Join the meeting to create a canvas.")}

          participant ->
            attrs = %{"title" => "#{meeting.name} canvas"}

            case Chat.create_canvas_with_message(meeting.chat_space_id, participant.id, attrs) do
              {:ok, canvas, _message} ->
                # Creating a canvas is an explicit act, so it both lands in
                # the picker AND becomes this viewer's selection — otherwise
                # the author is the one person who has to go find the thing
                # they just made.
                {:noreply,
                 socket
                 |> assign(:meeting_canvases, append_canvas(socket, canvas))
                 |> assign(:selected_canvas_id, canvas.id)
                 |> assign(:meeting_canvas, canvas)
                 # You made it and you are looking at it: no news.
                 |> mark_canvas_seen(canvas)}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, "Failed to create canvas.")}
            end
        end
    end
  end

  # ── Whiteboard persistence (task 019fcfcf stage 4) ───────────────────────
  #
  # Three events, all pushed by the `MeetingWhiteboard` hook, all answered
  # with `push_event` and never with an attribute on the host: the host is
  # `phx-update="ignore"` and LiveView merges attributes onto ignored nodes
  # (#664), so a server-rendered `data-scene-version` would be a defect of
  # exactly the shape that cost this stage twice already.

  # Restore. Asked for once per hook lifetime, after the island resolves.
  # A meeting with no board answers `scene: %{}, scene_version: 0` — an
  # empty board is the ordinary starting state, not an error.
  def handle_event("whiteboard_load", _params, socket) do
    case socket.assigns[:meeting] do
      nil ->
        {:noreply, socket}

      meeting ->
        {scene, version} =
          case Meetings.get_whiteboard(meeting.id) do
            nil -> {%{}, 0}
            wb -> {wb.scene, wb.scene_version}
          end

        {:noreply,
         socket
         |> assign(:whiteboard_version, version)
         |> push_event("whiteboard_loaded", %{scene: scene, scene_version: version})}
    end
  end

  # Save. Authorised with the SAME participant check `create_meeting_canvas`
  # uses: whiteboard access rides on the permission model of the chat space
  # the meeting lives in. That shared model is the reason this feature is
  # PubSub-and-Postgres rather than a deployed `excalidraw-room`, which
  # would bring its own auth and its own encryption story.
  def handle_event("whiteboard_save", %{"scene" => scene} = params, socket) do
    %{meeting: meeting, user_id: user_id} = socket.assigns
    expected = params["expected_version"]

    cond do
      is_nil(meeting) or is_nil(meeting.chat_space_id) ->
        {:noreply, socket}

      not is_integer(expected) ->
        {:noreply, socket}

      is_nil(find_participant(meeting.chat_space_id, user_id)) ->
        # No write of any kind. A non-participant may be looking at the
        # meeting; they may not overwrite its board.
        {:noreply, put_flash(socket, :error, "Join the meeting to edit the whiteboard.")}

      true ->
        save_whiteboard_scene(socket, meeting, user_id, scene, expected)
    end
  end

  # Dismiss the passive "updated elsewhere" badge. Purely presentational —
  # it clears the assign, it does not fetch, apply or discard any scene.
  def handle_event("dismiss_whiteboard_remote_notice", _params, socket) do
    {:noreply, assign(socket, :whiteboard_remote_version, nil)}
  end

  # ── Export the board into a Suite canvas (task 019fcfcf stage 5) ─────────
  #
  # Three server events, because the bytes and the authority live in
  # different places: only the browser can render the board, and only the
  # server may mint an upload URL. The chain is
  #
  #   click → "whiteboard_export_start"  (authorise, tell the hook to render)
  #         → "whiteboard_export"        (hook reports sizes; we presign x2)
  #         → "whiteboard_export_uploaded" (bytes are in; we write the canvas)
  #
  # The attachment URLs are NEVER taken from the client. We keep the two ids
  # and their `/chat/attachments/<uuid>` URLs in `:whiteboard_export_pending`
  # and require the ids the hook echoes back to be exactly those — otherwise
  # a crafted event could point a canvas image at any attachment id.

  # Step 1. Authorisation gate. A non-participant gets no `export_begin`, so
  # the browser is never even asked to render, let alone to upload.
  def handle_event("whiteboard_export_start", _params, socket) do
    %{meeting: meeting, user_id: user_id} = socket.assigns

    cond do
      is_nil(meeting) or is_nil(meeting.chat_space_id) ->
        {:noreply, socket}

      is_nil(find_participant(meeting.chat_space_id, user_id)) ->
        {:noreply,
         put_flash(socket, :error, "Join the meeting to send the whiteboard to a canvas.")}

      true ->
        {:noreply, push_event(socket, "whiteboard_export_begin", %{})}
    end
  end

  # Step 2. Reserve BOTH attachments. Two artefacts, always: the PNG is what
  # renders, the `.excalidraw` JSON is what makes the board reopenable.
  # Reserving one without the other would ship a picture of a whiteboard.
  def handle_event(
        "whiteboard_export",
        %{"png_byte_size" => png_size, "json_byte_size" => json_size},
        socket
      )
      when is_integer(png_size) and is_integer(json_size) do
    %{meeting: meeting, user_id: user_id} = socket.assigns

    cond do
      is_nil(meeting) or is_nil(meeting.chat_space_id) ->
        {:noreply, socket}

      is_nil(find_participant(meeting.chat_space_id, user_id)) ->
        # Nothing is reserved. No pending row, no signed URL.
        {:noreply,
         put_flash(socket, :error, "Join the meeting to send the whiteboard to a canvas.")}

      true ->
        reserve_whiteboard_export(socket, meeting, user_id, png_size, json_size)
    end
  end

  def handle_event("whiteboard_export", _params, socket), do: {:noreply, socket}

  # Step 3. Both blobs are stored; append one card to the meeting's canvas.
  def handle_event(
        "whiteboard_export_uploaded",
        %{"png_attachment_id" => png_id, "json_attachment_id" => json_id},
        socket
      ) do
    %{meeting: meeting, user_id: user_id} = socket.assigns
    pending = socket.assigns[:whiteboard_export_pending]

    cond do
      is_nil(meeting) or is_nil(meeting.chat_space_id) ->
        {:noreply, socket}

      # The echoed ids must be the ones WE reserved for THIS socket. Anything
      # else and we write nothing — the canvas image src is server-held.
      is_nil(pending) or pending.png.id != png_id or pending.json.id != json_id ->
        {:noreply, socket}

      is_nil(find_participant(meeting.chat_space_id, user_id)) ->
        {:noreply, socket}

      true ->
        write_whiteboard_canvas_card(socket, meeting, user_id, pending)
    end
  end

  def handle_event("whiteboard_export_uploaded", _params, socket), do: {:noreply, socket}

  # Screen-mode "Start sharing" CTA. The actual `setScreenShareEnabled`
  # toggle is owned by the `MeetingClient` JS hook; we forward the intent
  # by pushing the same `toggle-screen-share` browser event the chat-side
  # `meeting_toggle_screen_share` handler emits (see
  # `PlatformWeb.Chat.MeetingHooks`). Any `MeetingClient` mounted on the
  # page will pick it up via `handleEvent`. If no client is mounted (e.g.
  # the user opened the meeting URL directly without joining the call),
  # the push is a harmless no-op — the user can join via the persistent
  # mini-bar and then re-trigger.
  def handle_event("meeting_start_screen_share", _params, socket) do
    {:noreply, push_event(socket, "toggle-screen-share", %{})}
  end

  # Client-side mirror from the `MeetingShareButton` JS hook (task
  # 019e420f stage 2). The hook calls `setScreenShareEnabled` *inside*
  # the click handler — keeping the browser's user-activation flag alive
  # for `getDisplayMedia` — then pushes the resulting boolean here. We
  # just assign it; no `push_event`, because the JS already did the
  # LiveKit work (pushing `toggle-screen-share` back would double-toggle).
  #
  # MeetingHooks.attach/2 also handles this event for the chat-surface
  # Quick Meet panel, but the dedicated `/meetings/:slug` LiveView needs
  # its own clause so a non-boolean (or any) payload doesn't crash the
  # view by falling through to the catch-all.
  # NOTE: on `/meetings` this event is intercepted by the attached
  # `ChatLive.MeetingHooks.handle_event/3` (which returns `:halt`), so this
  # module clause is NOT reached for `meeting_screen_share_state` here — the
  # screen-share-not-displaying fix (auto-switch the stage to Screen on
  # share-start so `[data-screen-share-slot]` is mounted) lives in MeetingHooks
  # so it runs on the surface that actually has stage modes. This clause is
  # kept as a defensive standalone handler (e.g. if MeetingHooks ever detaches)
  # and mirrors the stage switch.
  def handle_event("meeting_screen_share_state", %{"enabled" => enabled}, socket)
      when is_boolean(enabled) do
    socket = assign(socket, :screen_share_enabled, enabled)

    socket =
      if enabled and Map.get(socket.assigns, :current_stage_mode) != :screen do
        # Task 01a0740d: same reassert as `set_stage_mode`, kept identical
        # to `MeetingHooks.maybe_switch_to_screen/2` so the backstop and
        # the live path cannot drift into two behaviours.
        collapsed = default_rail_collapsed?(:screen)

        socket
        |> assign(:current_stage_mode, :screen)
        |> assign(:chat_panel_collapsed, collapsed)
        |> assign(:call_rail_animate, false)
        |> push_event("meeting_stage_mode_changed", %{mode: "screen"})
        |> push_event("meeting_chat_pane_collapsed_changed", %{collapsed: collapsed})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("meeting_screen_share_state", _params, socket) do
    # Defensive: a malformed payload is ignored without touching state.
    {:noreply, socket}
  end

  # ── Guest name-entry form submit (task 019f498d stage 3) ────────────────
  #
  # Trim + length gates the submitted name, then calls
  # `Meetings.mint_guest_join_bundle/2`. On success we hand off to
  # `enter_meeting_as_guest/3` which flips `:state` from `:name_entry` to
  # `:in_meeting`, subscribes to per-space presence, and pushes
  # `join-meeting`. The heex render branches on `:state` in stage 4 so a
  # fresh guest sees the form → video-stage transition on this one
  # client-side round-trip.
  def handle_event("submit_name", %{"guest" => %{"name" => name}}, socket) do
    trimmed = name |> to_string() |> String.trim()

    cond do
      trimmed == "" ->
        {:noreply,
         socket
         |> assign(:name_error, "Please enter your name.")
         |> assign(:name_value, name)}

      String.length(trimmed) > 80 ->
        {:noreply,
         socket
         |> assign(:name_error, "Name is too long.")
         |> assign(:name_value, name)}

      true ->
        %{meeting: meeting} = socket.assigns

        # NO pre-flight mint (task 019f9cb7 stage 2). This used to call
        # `Meetings.mint_guest_join_bundle/2`, throw the bundle away as
        # `{:ok, _bundle}`, and then call `enter_meeting_as_guest/3` — which
        # mints a SECOND bundle — purely so this site could word its own
        # failure copy. Two JWTs per submission to produce a duplicate
        # message.
        #
        # It could not even see a different outcome: every
        # `mint_guest_join_bundle/2` failure is deterministic in
        # `(meeting, display_name, livekit config)`, so the pre-flight and
        # the real mint always agreed. What it DID produce was a second set
        # of guest-facing strings for the same operational fault, worded
        # differently from the mount path's — the pair that drifts. The
        # single mint inside `enter_meeting_as_guest/3` now answers for both
        # entry points, and `guest_mint_failure/3` routes a recoverable name
        # problem straight back to this form.
        {:noreply,
         socket
         |> assign(:name_error, nil)
         |> enter_meeting_as_guest(meeting, trimmed)}
    end
  end

  def handle_event("submit_name", _params, socket) do
    {:noreply, assign(socket, :name_error, "Please enter your name.")}
  end

  # Member pre-join lobby "Join" (task 01a09415). The signed-in-member
  # parallel to a guest's `"submit_name"`: there is no name to collect (the
  # account already names them), so a plain action rather than a form
  # submit. Clears the `:lobby` state back to `nil` — the member's post-join
  # state, which the call-shell member identity badge (`is_nil(@state)`)
  # keys on — then runs the SAME `maybe_start_meeting |> MeetingHooks.join()`
  # path the `:auto_join` handler's live branch runs, so a scheduled meeting
  # is flipped `live` on entry and the `:mic_enabled`/`:camera_enabled` the
  # lobby toggles committed ride into the room via `do_join/1`. Guarded on a
  # connected socket + binary `:user_id`: `MeetingHooks.join/1` no-ops
  # without a real user, so a stray click on a disconnected mount cannot
  # strand the socket out of both the lobby and the call.
  def handle_event("join_meeting", _params, socket) do
    if connected?(socket) and is_binary(socket.assigns[:user_id]) do
      socket =
        socket
        |> assign(:state, nil)
        |> maybe_start_meeting()
        |> MeetingHooks.join()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Lobby name field (task 01a07410 / FE-17 stage 4). Tracks what the guest
  # has typed so the mic/camera toggles, which re-render the form, do not
  # reset `value={@name_value}` to "". No validation here — `submit_name`
  # owns that, and an error shown while typing would be noise.
  def handle_event("lobby_name_change", %{"guest" => %{"name" => name}}, socket)
      when is_binary(name) do
    {:noreply, assign(socket, :name_value, name)}
  end

  def handle_event("lobby_name_change", _params, socket), do: {:noreply, socket}

  # ── Calendar navigation (`:index` action only, task 019fb954-8ead) ───────
  #
  # Every one of these recomputes through `assign_calendar_week/3`, so the
  # week query and the hour window can never drift between the arrows, the
  # Today button and the initial render.

  def handle_event("calendar_prev_week", _params, socket) do
    {:noreply, shift_calendar_week(socket, -7)}
  end

  def handle_event("calendar_next_week", _params, socket) do
    {:noreply, shift_calendar_week(socket, 7)}
  end

  # The viewer's escape hatch when their browser named a zone we cannot
  # resolve. UTC is never ASSUMED — it is only ever CHOSEN, here, by
  # someone who has been told their zone is unknown. Defaulting to it
  # would be quiet degradation: every time would be wrong by an unstated
  # offset and nothing on screen would say so. `:calendar_zone_assumed?`
  # stays true for the life of the LiveView so the choice keeps saying so.
  #
  # Guarded on `:calendar_zone_unresolved?` so the event cannot be pushed
  # from a console to relabel a viewer whose zone resolved correctly:
  # accepting it there would silently move every block on their calendar.
  def handle_event("calendar_assume_utc", _params, socket) do
    if socket.assigns.calendar_zone_unresolved? do
      socket =
        socket
        |> assign(:calendar_time_zone, "Etc/UTC")
        |> assign(:calendar_zone_assumed?, true)
        |> assign(:calendar_zone_unresolved?, false)

      {:noreply,
       assign_calendar_week(
         socket,
         socket.assigns.calendar_anchor_date,
         socket.assigns.calendar_selected_date
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("calendar_today", _params, socket) do
    today = calendar_today(socket)
    {:noreply, assign_calendar_week(socket, today, today)}
  end

  # A `phx-click` payload is a message from a client, so an unparseable
  # date is IGNORED rather than raised on: the only thing that can send
  # one is a stale or hand-edited DOM, and neither deserves a 500.
  #
  # A date OUTSIDE the rendered week is ignored for the same reason and
  # a stronger one: the seven strip cells are the only thing that sends
  # this event, so an eighth date is not a request the UI can make. The
  # week's meetings are loaded per week, so honouring it would select a
  # day whose meetings were never queried and draw a confidently empty
  # column. This is the invariant the day heading and the now-line both
  # stand on — the selected date is always one of the seven on screen.
  def handle_event("select_calendar_day", %{"date" => iso8601}, socket) do
    week = CalendarWindow.week_days(socket.assigns.calendar_anchor_date)

    with {:ok, date} <- Date.from_iso8601(iso8601),
         true <- date in week do
      {:noreply, assign(socket, :calendar_selected_date, date)}
    else
      _out_of_week_or_unparseable -> {:noreply, socket}
    end
  end

  # Both of these reset the invite control, and for the same reason: it is
  # scoped to ONE meeting. Left open across a change of selection it would
  # be a search box sitting under a different meeting's invitee list, and
  # the next thing staged in it would be written to that meeting instead.
  def handle_event("select_meeting", %{"id" => meeting_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_meeting_id, meeting_id)
     |> seed_live_invite_assigns()}
  end

  def handle_event("close_meeting_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_meeting_id, nil)
     |> seed_live_invite_assigns()}
  end

  # ── Live invites (detail panel + sheet, task 019fb955-1d7b stage 5) ──────
  #
  # `:live` mode of `PlatformWeb.Components.Meetings.InviteControl`. The
  # difference from the create sheet's `:draft` set is not cosmetic: there
  # IS a meeting row here, so choosing someone WRITES a `meeting_invites`
  # row and delivers the invite in the same call. Nothing is staged and
  # there is no submit to lose it at.

  def handle_event("meeting_invite_add_people", _params, socket) do
    {:noreply, socket |> seed_live_invite_assigns() |> assign(:meeting_invite_open, true)}
  end

  def handle_event("meeting_invite_search", %{"value" => query}, socket) do
    {:noreply, assign_live_invite_candidates(socket, to_string(query))}
  end

  def handle_event("meeting_invite_stage", %{"kind" => kind} = params, socket) do
    meeting = selected_live_invite_meeting!(socket)

    socket =
      case deliver_live_invite(meeting, kind, params, socket) do
        {:ok, _result} ->
          socket

        {:error, :guest_host_not_configured} ->
          # A missing guest host is an OPERATOR fault, not a caller one, and
          # the only person who can fix it is reading this flash. Folding it
          # into the generic message below would make a deployment mistake
          # indistinguishable from a bad email address. `invite_guest/2`
          # already logged the same fact; this is its user-visible half.
          put_flash(
            socket,
            :error,
            "Guest links are not available: MEETING_GUEST_HOST is not configured."
          )

        {:error, _reason} ->
          # A failure here is a real runtime outcome — a changeset error, a
          # grant that could not be staged — not a caller bug, so it is
          # reported rather than raised. What it must never be is silent:
          # the row simply not appearing looks identical to a click that
          # missed.
          put_flash(socket, :error, "That invite could not be sent.")
      end

    {:noreply, clear_live_invite_search(socket)}
  end

  # ── Archive filters (`:index` action only, task 019fb954-c848) ──────────
  #
  # The search box and the project select are ONE form, and it pushes into
  # the URL rather than into an assign. Results are then linkable, survive a
  # reload, and the back button steps through searches — which is the whole
  # reason the archive's state lives in `handle_params/3`.
  def handle_event("archive_filter", params, socket) do
    overrides =
      %{}
      |> archive_override(params, "q")
      |> archive_override(params, "project_id")

    {:noreply, push_patch(socket, to: archive_path(socket.assigns, overrides))}
  end

  # ── New-meeting FAB + create sheet (`:index` action only) ────────────────
  #
  # The FAB lives only on the meetings index. Clicking it flips
  # `:show_start_meeting_sheet` so the sheet wrapper renders. The sheet
  # collects { name, project, date, start, duration } plus a list of
  # STAGED invites, and submits to `Meetings.create_meeting/1`.
  #
  # ## It does not drop you into the room any more (stage 4)
  #
  # This handler used to `push_navigate` into `/meetings/<slug>` on
  # success. That was defensible when every meeting was ad-hoc and
  # "create" meant "start". With a date and a start time on the form it is
  # wrong: a meeting scheduled for next Wednesday must not open its room
  # now. The sheet closes, the flash confirms, and the index stays put —
  # `create_meeting/1` broadcasts `{:meeting_created, meeting}` on the
  # project topic and this LiveView is subscribed to every project's, so
  # the calendar redraws itself. Joining is still one click, from the
  # meeting.
  #
  # ## Staged invites are replayed AFTER the commit, and their failures
  #    are reported
  #
  # Nothing touches `meeting_invites` until submit, because at create time
  # there is no meeting row to hang an invite off. Once the meeting is
  # committed the staged entries are replayed one call each; a failure
  # does NOT roll the meeting back — but it is not swallowed either. The
  # count comes back as a second flash. An invite that silently evaporates
  # is a bug that files no report.

  def handle_event("open_start_meeting_sheet", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_start_meeting_sheet, true)
     |> reset_create_sheet()}
  end

  # Dismissal only HIDES. The reset lives on the open path, and duplicating
  # it here was measurably unfalsifiable: a mutant that deleted the
  # close-side reset left every test green, because the staged list is only
  # observable through a rendered sheet and rendering one requires an open,
  # which resets. Belt-and-braces no test can constrain is a claim nobody
  # is checking.
  def handle_event("close_start_meeting_sheet", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_start_meeting_sheet, false)
     |> assign(:start_meeting_error, nil)}
  end

  # Live-update form state on input change so re-render keeps the user's
  # input in the sheet (otherwise an inline-validation render wipes it).
  def handle_event("start_meeting_form_change", %{"start_meeting" => attrs}, socket) do
    # Re-resolves Meet now's project too: picking one in the select is the
    # one interaction that moves the answer while the sheet is open, and a
    # tile still naming the previous project would be telling the viewer
    # something untrue about what their next click does.
    {:noreply,
     socket
     |> assign(:start_meeting_form, start_meeting_form(attrs))
     |> assign_meet_now_project()}
  end

  # ── Draft invite staging (create sheet only) ─────────────────────────────
  #
  # `:draft` mode of `PlatformWeb.Components.Meetings.InviteControl`. The
  # event names are the component's `event(:draft, _)` set, which is
  # disjoint from the `:live` set the detail panel uses — both surfaces are
  # this same LiveView, so the name is the only thing that tells a
  # create-sheet click apart from a detail-panel one.

  def handle_event("meeting_create_invite_search", %{"value" => query}, socket) do
    {:noreply, assign_create_invite_candidates(socket, to_string(query))}
  end

  def handle_event("meeting_create_invite_stage", %{"kind" => kind} = params, socket) do
    entry = build_draft_invite(kind, params, socket)
    staged = socket.assigns.meeting_create_invites

    staged =
      if Enum.any?(staged, &(&1.id == entry.id)), do: staged, else: staged ++ [entry]

    {:noreply,
     socket
     |> assign(:meeting_create_invites, staged)
     |> clear_create_invite_search()}
  end

  def handle_event("meeting_create_invite_unstage", %{"id" => id}, socket) do
    staged = Enum.reject(socket.assigns.meeting_create_invites, &(&1.id == id))

    {:noreply, assign(socket, :meeting_create_invites, staged)}
  end

  def handle_event("start_meeting", %{"start_meeting" => attrs}, socket) do
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()
    project_id = attrs |> Map.get("project_id", "") |> to_string() |> String.trim()

    cond do
      name == "" ->
        refuse_create(socket, attrs, "Name is required.")

      # `meetings.project_id` is NOT NULL and the slug is unique per
      # project, so the `required` attribute on the select is a hint, not a
      # gate. This clause is the gate.
      project_id == "" ->
        refuse_create(socket, attrs, "Project is required.")

      true ->
        case scheduled_window(attrs, socket.assigns.calendar_time_zone) do
          {:error, message} ->
            refuse_create(socket, attrs, message)

          {:ok, starts_at, ends_at} ->
            create_from_sheet(socket, attrs, name, project_id, starts_at, ends_at, :stay)
        end
    end
  end

  # ── Meet now (task 01a0d4d5) ─────────────────────────────────────────────
  #
  # One click, no field touched, and you are in a live room. It shares the
  # commit path with `start_meeting` above rather than reaching for
  # `Meetings.create_meeting/1` a second time: that function is what wires
  # the backing chat space, the `meeting-<uuid>` LiveKit room name and the
  # project PubSub broadcast, and the staged-invite replay lives in
  # `create_from_sheet/7`. A parallel constructor would drift from all of
  # it silently — the transcriber and the voice agent would simply stop
  # arriving for meetings created this way, and nothing would fail loudly.
  #
  # It does NOT route through `scheduled_window/2`. That function exists to
  # turn a typed date and wall-clock time into an instant, which is why it
  # refuses without a time zone. Meet now already holds the instant.
  #
  # RE-ENTRY. `:meet_now_pending?` is checked HERE and not only used to
  # disable the button. A `phx-click` is a message from a client, and a
  # client that has already sent one can send another — a double-tap on a
  # slow connection must not commit two meetings. The template's `disabled`
  # is the courtesy; this clause is the gate.
  def handle_event("meet_now", _params, %{assigns: %{meet_now_pending?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("meet_now", _params, socket) do
    case socket.assigns[:meet_now_project_id] do
      nil ->
        # Refused in place, sheet still open. `meetings.project_id` is NOT
        # NULL, so the ticket's "otherwise none" is not representable and
        # there is nothing honest to create. Says what to do next rather
        # than what went wrong.
        {:noreply,
         assign(socket, :start_meeting_error, "Create a project before starting a meeting.")}

      project_id ->
        starts_at = DateTime.utc_now()
        ends_at = DateTime.add(starts_at, @default_duration_minutes * 60, :second)

        socket
        |> assign(:meet_now_pending?, true)
        |> create_from_sheet(
          socket.assigns.start_meeting_form,
          meet_now_name(starts_at, socket.assigns[:calendar_time_zone]),
          project_id,
          starts_at,
          ends_at,
          :enter
        )
    end
  end

  # ── Intents-collapse bar events (task 019f70b8 stage 7) ──────────────────
  #
  # EVERY clause here re-checks `@intents_visible?` through
  # `with_intents_gate/2`. The template gate keeps the bar out of an
  # unassigned viewer's DOM; this keeps it out of their reach. A
  # `phx-click` is a message from a client, and a client that no longer
  # holds the producer role (or never did) must not be able to cancel a
  # meeting's work by replaying one.

  def handle_event("toggle_intents_collapse", _params, socket) do
    with_intents_gate(socket, fn socket ->
      socket
      |> assign(:intents_open, !socket.assigns.intents_open)
      |> assign(:intent_reason_picker_id, nil)
    end)
  end

  def handle_event("toggle_intents_expanded", _params, socket) do
    with_intents_gate(socket, fn socket ->
      assign(socket, :intents_expanded, !socket.assigns.intents_expanded)
    end)
  end

  # Per-meeting intent mute (task 019fbaac stage 3).
  #
  # Deliberately does NOT assign `:intent_muted?` here. The write
  # broadcasts on `"meeting:<id>"`, and the `{:intent_mute_changed, …}`
  # clause below updates the assign — for the clicking client on exactly
  # the same path as for every other connected client. A local assign
  # would give the clicker a second, faster path to the same state, and
  # two paths to one piece of state is where divergence comes from.
  #
  # Authorization reuses `with_intents_gate/2`, the same gate governing
  # the per-row cancel and correct buttons. Read its real semantics at
  # its definition: it asks whether `meeting_producer` is assigned to any
  # agent ORG-WIDE, not whether this viewer holds it. Matching the
  # existing posture is deliberate; tightening it to viewer identity is a
  # separate decision and is being raised as its own ticket.
  #
  # GUEST REJECTION (task 019fbaac stage 4). Guests SEE the muted state and
  # cannot change it. This clause must stay ABOVE the one below, and it is
  # not redundant with `with_intents_gate/2`: that helper asks whether
  # `meeting_producer` is assigned to any agent ORG-WIDE, which says
  # nothing about who is holding the socket. A guest is blocked by it today
  # only incidentally — `:intents_visible?` is `false` on the guest path
  # because `handle_params/3` no-ops and never resolves it, not because
  # anything checked the viewer. The day someone resolves intent assigns
  # for guests (a read-only intent rail is an obvious next ask), that
  # incidental block evaporates and this one does not.
  #
  # The mutation control for this clause is documented in
  # `meeting_live_guest_mount_test.exs`: removing it does NOT redden the
  # plain guest test, precisely because the incidental guard still holds.
  # The test that DOES redden neutralizes `:intents_visible?` first so this
  # clause is the only thing left standing.
  def handle_event("toggle_intent_mute", _params, %{assigns: %{chrome_mode: :none}} = socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_intent_mute", _params, socket) do
    with_intents_gate(socket, fn socket ->
      case socket.assigns[:meeting] do
        %{id: meeting_id} ->
          # The ID, never the in-memory struct. `set_intent_muted/2`'s
          # struct clause delegates here anyway so the row is re-read
          # before the write, but passing the id makes that explicit at
          # the call site: this socket's `:meeting` was loaded once at
          # `handle_params/3` and its `intent_muted_at` is stale the
          # moment any other client toggles.
          case Meetings.set_intent_muted(meeting_id, not socket.assigns.intent_muted?) do
            {:ok, _meeting} -> socket
            {:error, _reason} -> assign(socket, :intent_error, "Could not change the agent mute.")
          end

        _ ->
          socket
      end
    end)
  end

  # Push-to-talk (task 01a03f4e stage 5). The key went down: open the
  # press window and put this speaker's card on the board immediately.
  #
  # The IDENTITY is read off this socket and never from the click
  # payload. It is minted the same way the LiveKit token mints it —
  # `"user:<uuid>"`, the shape `Meetings.parse_identity/1` parses and the
  # shape the transcriber stamps on every segment — so the window this
  # opens is the window an arriving segment will match. A crafted
  # `phx-value-` cannot open a window in somebody else's name.
  def handle_event("push_to_talk_press", params, socket) do
    # The agent the human PRESSED (per-agent hold-to-talk). Read off the
    # payload, but never trusted: `PressCard.open/3` validates the id
    # against the active roster and falls back to the configured default
    # for an unknown or absent one, so a crafted `phx-value-` cannot
    # byline a card to a stranger.
    agent_id = pressed_agent_id_param(params)

    socket =
      with %{id: meeting_id} <- socket.assigns[:meeting],
           identity when is_binary(identity) <- press_identity(socket) do
        case claim_ask_floor(socket, meeting_id, agent_id, identity) do
          {:error, {:held_by, _holder}} ->
            # Somebody else already has this agent's floor (task
            # 01a0cf5c stage 1). No window opens and no card is written —
            # refuse through the SAME `data-rejected` slot the hook
            # already renders `no-microphone` / `microphone-muted` /
            # `pointer-lost` through, so the presser sees it said no
            # before anything else happens.
            push_event(socket, "push_to_talk_rejected", %{
              "agent_id" => agent_id,
              "reason" => "held-by-other"
            })

          _claimed_or_untargeted ->
            socket =
              case PressCard.open(meeting_id, identity,
                     speaker: socket.assigns[:display_name],
                     room_id: socket.assigns[:meeting].chat_space_id,
                     target_agent_id: agent_id
                   ) do
                {:ok, %{intent: intent}} ->
                  # Task 01a0cf5c stage 3: start listening for THIS
                  # press's own speech the instant the card exists —
                  # see `start_ask_transcript_tracking/4` for why the
                  # topic is the CANONICAL one, not a per-room mirror.
                  start_ask_transcript_tracking(socket, meeting_id, identity, agent_id, intent)

                {:error, _reason} ->
                  socket
              end

            # Only reflect the held state once the press actually opened
            # a card — a viewer with no `press_identity` (a guest) opens
            # nothing, so a "Talking to…" cue for them would be a lie.
            assign(socket, :pressed_agent_id, agent_id)
        end
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  # The key came up. Closing the window is all that happens here: the
  # words are still in the transcriber's buffer, and
  # `PressWindow.release/3` leaves a grace period open for exactly that
  # reason.
  #
  # `:pressed_agent_id` is read BEFORE it is cleared below — it is this
  # socket's only record of which agent's floor (if any) this press
  # claimed, since the release event carries no payload of its own.
  #
  # This handler fires for EVERY release the JS hook produces — a real
  # (>=380ms) hold AND an early one (`meeting_push_to_talk.js`'s
  # `endPress/0` pushes it unconditionally either way, the 380ms split
  # is client-side choreography only). So `release_ask_floor/4` below
  # already closes the ask-floor loop for both paths in one place; nothing
  # about the 380ms threshold is visible here to gate on, and nothing
  # needs to be (task 01a0cf5c stage 3 — "close the loop on stage 1").
  def handle_event("push_to_talk_release", _params, socket) do
    agent_id = socket.assigns[:pressed_agent_id]

    with %{id: meeting_id} <- socket.assigns[:meeting],
         identity when is_binary(identity) <- press_identity(socket) do
      PressWindow.release(meeting_id, identity)
      release_ask_floor(socket, meeting_id, agent_id, identity)
    end

    socket =
      socket
      |> resolve_ask_outcome_on_release()
      |> assign(:pressed_agent_id, nil)

    {:noreply, socket}
  end

  # The rail freezes its order while a pointer is over it (task 01a0740e
  # stage 4). The rail sorts by deadline, so a card CAN move under a
  # cursor already on its way to `Stop` — rarely, on one of three
  # discrete events, and once is enough to stop the wrong card.
  #
  # The captured order is re-derived HERE from `:meeting_candidates`
  # through `CandidateRail.display_order/1`, the same sort the render
  # runs. The push carries no ids at all: a payload of card ids would let
  # a crafted event dictate the sequence of somebody's rail, or name a
  # row from another meeting, for no gain over reading the list this
  # socket already holds.
  #
  # This clause serves the GUEST ingress. An authenticated session on
  # this route also runs `MeetingHooks.attach/2`, whose own clause halts
  # the event before it reaches here; a guest runs `attach_guest/1`,
  # whose `handle_guest_event/3` falls through to this module. Both are
  # live paths, and deleting either as a duplicate crashes one of the two
  # surfaces on a hover.
  def handle_event("candidate_rail_freeze", _params, socket) do
    order = CandidateRail.display_order(socket.assigns[:meeting_candidates] || [])

    {:noreply, assign(socket, :candidate_order, order)}
  end

  # Cleared, never expired on a timer. A frozen rail is a rail that has
  # stopped telling the truth about urgency, so the only thing allowed to
  # hold one is a pointer that is still there.
  def handle_event("candidate_rail_thaw", _params, socket) do
    {:noreply, assign(socket, :candidate_order, nil)}
  end

  # Stop this candidate's countdown (task 01a03fba stage 4).
  #
  # Deliberately NOT wrapped in `with_intents_gate/2`. That gate resolves
  # the `meeting_producer` role, and the requirement here is that stop
  # works from ANY participant's session — a guest holds
  # `"meeting:{id}"` and not `"meeting:{id}:intents"`, so gating this
  # would deny it to exactly the people the requirement is about.
  #
  # The participant id goes to the server as the third thing written
  # (`closed_by_participant_id`); it is read off THIS socket and never
  # from the click payload, so a crafted `phx-value-` cannot attribute
  # somebody else's stop.
  def handle_event("stop_candidate", %{"candidate_id" => candidate_id}, socket)
      when is_binary(candidate_id) do
    meeting_id = socket.assigns[:meeting] && socket.assigns.meeting.id

    socket =
      case Candidates.get(candidate_id) do
        %{meeting_id: ^meeting_id} = candidate when is_binary(meeting_id) ->
          apply_candidate_stop(socket, candidate)

        # Not this meeting's candidate, or no such row. Nothing is
        # written and nothing is said — a click on a card belonging to
        # another meeting is not a state this UI can produce, and an
        # error message would only tell a prober that the id exists.
        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("stop_candidate", _params, socket), do: {:noreply, socket}

  # Take that stop back (task 01a0740e stage 5).
  #
  # Ungated for the SAME documented reason `stop_candidate` is: a guest
  # holds `"meeting:{id}"` and not `"meeting:{id}:intents"`, and the
  # requirement is that any participant can work the board. Undoing a
  # stop is strictly less powerful than making one — it hands the card
  # back to an explicit human decision rather than letting it act.
  #
  # The participant id is read off THIS socket and never from the click
  # payload, so a crafted `phx-value-` cannot attribute somebody else's
  # undo, and the candidate is RE-READ from the database rather than
  # taken from the assign — the assign was loaded before the stop, so
  # its `state` is stale by construction on this path.
  def handle_event("undo_stop_candidate", %{"candidate_id" => candidate_id}, socket)
      when is_binary(candidate_id) do
    meeting_id = socket.assigns[:meeting] && socket.assigns.meeting.id

    socket =
      case Candidates.get(candidate_id) do
        %{meeting_id: ^meeting_id} = candidate when is_binary(meeting_id) ->
          apply_candidate_undo_stop(socket, candidate)

        # Not this meeting's candidate, or no such row. Nothing written
        # and nothing said, matching `stop_candidate`.
        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("undo_stop_candidate", _params, socket), do: {:noreply, socket}

  # ── The correction panel (task 01a0740e stage 2) ────────────────────────
  #
  # Five handlers for the pencil on an armed card and the three choices
  # it opens. All five are UNGATED, and all five for the same documented
  # reason `stop_candidate` is: `with_intents_gate/2` resolves the
  # `meeting_producer` role, a guest holds `"meeting:{id}"` and not
  # `"meeting:{id}:intents"`, so gating these would deny correction to
  # exactly the participants the board exists for. It would also invert
  # the ticket's whole argument — correcting a card is meant to be
  # EASIER than stopping one, and stop is ungated.
  #
  # Every one of them resolves the candidate against THIS socket's
  # meeting through `with_own_candidate/3` before touching anything, and
  # reads the actor's participant id off THIS socket rather than from
  # the click payload, so a crafted `phx-value-` can neither reach
  # another meeting's card nor attribute somebody else's correction.

  # THE SIGNATURE MOVE: opening the panel re-arms the card.
  #
  # Without this, reading the three choices costs the reader the window
  # they were reading them in, and the cheapest move stays "stop it" —
  # which teaches the classifier nothing. `rearm/2` sets the FULL 30
  # seconds, and the rail draws it as the number changing in place.
  #
  # It is server state, so every participant's rail moves, not just the
  # one who opened the panel. A participant CAN therefore hold a card
  # open by re-opening the panel; that is intended and is strictly
  # weaker than the Stop control they already have.
  def handle_event("candidate_correct_open", %{"candidate_id" => candidate_id}, socket)
      when is_binary(candidate_id) do
    {:noreply, with_own_candidate(socket, candidate_id, &open_candidate_correction/2)}
  end

  def handle_event("candidate_correct_open", _params, socket), do: {:noreply, socket}

  # Closing writes nothing and does NOT take the re-arm back. The
  # seconds were given for reading the card; a reader who decided the
  # card was right has still done the reading.
  def handle_event("candidate_correct_close", _params, socket) do
    {:noreply, assign(socket, :candidate_correcting_id, nil)}
  end

  # `Hand to <agent>`. The agent id is the ONE thing here that legitimately
  # arrives in the payload — it names a choice the participant made, not
  # an identity they are claiming — and `Candidates.correct/3` refuses an
  # id that is not a UUID (`:no_agent`), names no agent row
  # (`:unknown_agent`), or names the agent already on the card
  # (`:same_agent`), each before anything is written.
  def handle_event(
        "candidate_correct_reassign",
        %{"candidate_id" => candidate_id, "agent_id" => agent_id},
        socket
      )
      when is_binary(candidate_id) and is_binary(agent_id) do
    {:noreply,
     with_own_candidate(socket, candidate_id, fn socket, candidate ->
       apply_candidate_correction(socket, candidate, :reassign, agent_id: agent_id)
     end)}
  end

  def handle_event("candidate_correct_reassign", _params, socket), do: {:noreply, socket}

  # `Make it a canvas instead` / `Make it a task instead`. Which of the
  # two it is, is a fact about the card and not about the click, so the
  # direction is not carried in the payload: `correct/3` flips whatever
  # `outcome_kind` the row it re-reads is actually carrying.
  def handle_event("candidate_correct_flip", %{"candidate_id" => candidate_id}, socket)
      when is_binary(candidate_id) do
    {:noreply,
     with_own_candidate(socket, candidate_id, fn socket, candidate ->
       apply_candidate_correction(socket, candidate, :flip_outcome, [])
     end)}
  end

  def handle_event("candidate_correct_flip", _params, socket), do: {:noreply, socket}

  # `Not an action`. The only one of the three that closes the card, and
  # it closes it through the existing `stop/3` — same race against the
  # sweeper, same `:dismissed` reason. The difference from pressing Stop
  # is the corpus row, which is the entire point.
  def handle_event("candidate_correct_none", %{"candidate_id" => candidate_id}, socket)
      when is_binary(candidate_id) do
    {:noreply,
     with_own_candidate(socket, candidate_id, fn socket, candidate ->
       apply_candidate_correction(socket, candidate, :not_an_action, [])
     end)}
  end

  def handle_event("candidate_correct_none", _params, socket), do: {:noreply, socket}

  # The human gate on a card that is NOT counting down (task
  # 01a03f4e-78b1). `Go ahead` and `Not now` are the review half of the
  # ticket's two modes; the countdown above is the act half, and the two
  # are mutually exclusive because a card in review has no `acts_at`.
  #
  # Ungated for the same reason `stop_candidate` is: the board is a
  # participant-facing surface, not the producer's tuning bar.
  #
  # `graduate/2` is what its own doc calls "the board that calls it" —
  # this is that board. It mints the deliverable and closes the row out,
  # so the card leaves the live list and lands in Closed with a reason,
  # exactly as a fired card does.
  def handle_event("approve_candidate", %{"candidate_id" => candidate_id}, socket)
      when is_binary(candidate_id) do
    {:noreply, with_own_candidate(socket, candidate_id, &apply_candidate_approve/2)}
  end

  def handle_event("approve_candidate", _params, socket), do: {:noreply, socket}

  # `Not now` closes `:dismissed` — the same reason a stop writes,
  # because they are the same human decision reached through two
  # affordances. Deliberately NOT a sixth `closed_reason`: the
  # vocabulary is the Architect's and `candidates_test.exs` asserts no
  # `dismiss/1` wrapper exists, so this goes through `close/2` like
  # every other close in the tree.
  def handle_event("decline_candidate", %{"candidate_id" => candidate_id}, socket)
      when is_binary(candidate_id) do
    {:noreply, with_own_candidate(socket, candidate_id, &apply_candidate_decline/2)}
  end

  def handle_event("decline_candidate", _params, socket), do: {:noreply, socket}

  # The X opens a reason picker rather than removing immediately. A
  # cancel carries no reason until a human states one, and stage 6's
  # corpus requires a reason on every row — so the reason has to be
  # collected before the mutation, not invented after it.
  def handle_event("intent_reason_picker_toggle", %{"intent_id" => intent_id}, socket) do
    with_intents_gate(socket, fn socket ->
      next = if socket.assigns.intent_reason_picker_id == intent_id, do: nil, else: intent_id
      assign(socket, :intent_reason_picker_id, next)
    end)
  end

  def handle_event("intent_remove", %{"intent_id" => intent_id, "reason" => reason}, socket) do
    with_intents_gate(socket, fn socket ->
      case {find_intent(socket, intent_id), parse_correction_reason(reason)} do
        {nil, _} ->
          assign(socket, :intent_reason_picker_id, nil)

        {_row, :error} ->
          socket
          |> assign(:intent_reason_picker_id, nil)
          |> assign(:intent_error, "Unrecognised removal reason.")

        {row, {:ok, reason}} ->
          # `dispatch_outcome` is captured from the row's status AT CLICK
          # TIME (AC11) — the cancel below may move the row, and a
          # correction stamped with the post-cancel status would record
          # the producer's own action rather than where the intent had
          # got to when they judged it wrong.
          outcome = IntentsCollapse.dispatch_outcome(row.status)

          {result, socket} = apply_intent_cancel(socket, row, reason: reason)

          write_intent_correction(socket, row, %{
            dispatch_outcome: outcome,
            correction: :removed_no_action,
            reason: reason
          })

          socket
          |> assign(:intent_reason_picker_id, nil)
          |> apply_cancel_result(row, result)
      end
    end)
  end

  def handle_event("intent_edit_open", %{"intent_id" => intent_id}, socket) do
    with_intents_gate(socket, fn socket ->
      socket
      |> assign(:intent_edit_row, find_intent(socket, intent_id))
      |> assign(:intent_reason_picker_id, nil)
      |> assign(:intent_error, nil)
    end)
  end

  def handle_event("intent_edit_close", _params, socket) do
    with_intents_gate(socket, fn socket ->
      socket
      |> assign(:intent_edit_row, nil)
      |> assign(:intent_error, nil)
    end)
  end

  def handle_event("intent_edit_save", %{"intent_edit" => attrs}, socket) do
    with_intents_gate(socket, fn socket ->
      intent_id = Map.get(attrs, "intent_id")
      corrected_intent = blank_to_nil(Map.get(attrs, "corrected_intent"))
      corrected_target = blank_to_nil(Map.get(attrs, "corrected_target_agent_id"))

      case {find_intent(socket, intent_id), parse_correction_reason(Map.get(attrs, "reason"))} do
        {nil, _} ->
          assign(socket, :intent_edit_row, nil)

        {_row, :error} ->
          assign(socket, :intent_error, "Unrecognised correction reason.")

        {row, {:ok, reason}} ->
          # Mirrors `IntentCorrection.changeset/2`'s one cross-field rule.
          # Checked here too so the producer gets a message in the modal
          # instead of a silently-dropped insert.
          if is_nil(corrected_intent) and is_nil(corrected_target) do
            assign(
              socket,
              :intent_error,
              "Name a corrected intent or a corrected target agent."
            )
          else
            outcome = IntentsCollapse.dispatch_outcome(row.status)

            {result, socket} =
              apply_intent_cancel(socket, row,
                reason: reason,
                corrected_intent: corrected_intent,
                corrected_target_agent_id: corrected_target
              )

            write_intent_correction(socket, row, %{
              dispatch_outcome: outcome,
              correction: :corrected,
              reason: reason,
              corrected_intent: corrected_intent,
              corrected_target_agent_id: corrected_target
            })

            socket
            |> assign(:intent_edit_row, nil)
            |> assign(:intent_error, nil)
            |> apply_cancel_result(row, result)
          end
      end
    end)
  end

  # Paging keeps the selected day's OFFSET within the week (a Wednesday
  # stays a Wednesday) rather than snapping back to Monday, so stepping
  # through weeks does not silently move which day is highlighted.
  defp shift_calendar_week(socket, days) do
    anchor = Date.add(socket.assigns.calendar_anchor_date, days)
    selected = Date.add(socket.assigns.calendar_selected_date, days)
    assign_calendar_week(socket, anchor, selected)
  end

  # ── PubSub ───────────────────────────────────────────────────────────────

  # Auto-join trigger from handle_params/3. Delegates straight into
  # MeetingHooks' public `join/1` so the LiveKit lifecycle (token mint,
  # MeetingClient push_event, MeetingState broadcast) stays a single
  # source of truth — same code path as the manual "Join meeting" CTA.
  @impl true
  def handle_info(:auto_join, socket) do
    cond do
      socket.assigns[:in_meeting] ->
        {:noreply, socket}

      not is_binary(socket.assigns[:user_id]) ->
        # Guest ingress (task 019f498d stage 3): mount already minted the
        # bundle and pushed `join-meeting`. MeetingHooks.join/1 assumes a
        # binary `:user_id` (see `do_join/1`), which the guest surface
        # doesn't have — so auto-join is a no-op on the guest path.
        #
        # NARROWED from `chrome_mode == :none` (task 019fb955-f8b1 stage
        # 5). That test conflated "chrome-less" with "guest", which held
        # only while the `meet.` host served guests exclusively. The
        # `:meet_member` live_session is chrome-less AND carries a real
        # binary `:user_id`, and it must auto-join like any other signed-in
        # viewer — under the old test it loaded the room and never entered
        # the call. The stated reason for the skip was always the missing
        # user_id, so this asks that question directly. `MeetingHooks`
        # carries its own invite gate (stage 4), so widening the auto-join
        # path does not widen who may join.
        {:noreply, socket}

      true ->
        # Transition a still-`scheduled` meeting to `live` BEFORE joining.
        # `Meetings.start_meeting/1` had ZERO callers — the /meetings FAB only
        # created (status="scheduled") then navigated here — so every meeting
        # stayed "scheduled" forever and the index showed it under "Upcoming".
        # Auto-join is the single chokepoint every join (FAB or direct link)
        # flows through, so starting the meeting here covers all paths.
        socket = socket |> maybe_start_meeting() |> MeetingHooks.join()
        {:noreply, socket}
    end
  end

  def handle_info({:participant_joined, _participant}, socket) do
    {:noreply, refresh_participants(socket)}
  end

  # Per-agent ask-floor ownership (task 01a0cf5c stage 1). Fired on the
  # room topic the instant a press claims an agent ANYWHERE in the
  # meeting, before anything is said — the design canvas (01a0cf5e-9cb0)
  # requires the second presser's button to say so before they start
  # talking, not after. `AskFloor` is keyed on the TARGET agent, unlike
  # `PressWindow` (keyed on the presser), so every connected client —
  # not only the presser — needs this broadcast to know an agent's
  # button is spoken for. `ParticipantRail` reads `:ask_floor_holders`
  # to disable and label every OTHER agent's row; the presser's OWN row
  # still reads `:pressed_agent_id` for its "Talking…" cue, so the two
  # never collide for the person actually holding the floor.
  def handle_info({:ask_floor_taken, %{agent_id: agent_id, display_name: display_name}}, socket) do
    holders = Map.put(socket.assigns[:ask_floor_holders] || %{}, agent_id, display_name)
    {:noreply, assign(socket, :ask_floor_holders, holders)}
  end

  # The explicit-release and stuck-claim-timeout paths both land here —
  # `AskFloor.release/3` broadcasts it from `push_to_talk_release`
  # (`claim_ask_floor/4`'s counterpart, `release_ask_floor/4`), and
  # `AskFloor` broadcasts it itself when a dropped socket's claim goes
  # stale. Either way the agent's button should un-freeze; this clause
  # does not need to know which case it is.
  def handle_info({:ask_floor_released, %{agent_id: agent_id}}, socket) do
    holders = Map.delete(socket.assigns[:ask_floor_holders] || %{}, agent_id)
    {:noreply, assign(socket, :ask_floor_holders, holders)}
  end

  # Live transcript feed for the held card's veil (task 01a0cf5c stage
  # 3). Only reached while THIS socket is actively tracking a press
  # (`start_ask_transcript_tracking/4`) — see that function for why the
  # subscription is the PER-ROOM `meeting:transcript_chunk:<room_name>`
  # topic, keyed off `Meetings.room_name_for_space/1`, and never the
  # global one `IntentClassifier` holds.
  #
  # `Platform.Meetings.IntentClassifier` is the other reader of this
  # exact broadcast shape and this clause mirrors its verdict logic on
  # purpose (`stamp_press_window_source/1`): a segment belongs to THIS
  # press iff its own `participant_identity` is the identity this
  # socket pressed with AND `PressWindow.claim/3` — called with that
  # SAME identity, at the ARRIVAL instant, exactly like the classifier
  # — says the window covers it. The `meeting_id` match below is belt
  # and braces (the room subscription already scopes this to one
  # space); anything that fails to match — a stale broadcast for a
  # PRIOR meeting in this same room, another speaker's segment, a
  # segment arriving outside the window — is a silent no-op here, same
  # as it is for the classifier.
  def handle_info({:transcript_chunk, payload}, socket) when is_map(payload) do
    identity = socket.assigns[:ask_transcript_identity]
    meeting = socket.assigns[:meeting]

    socket =
      with true <- is_binary(identity),
           %{id: meeting_id} <- meeting,
           ^meeting_id <- Map.get(payload, :meeting_id),
           segment when is_map(segment) <- Map.get(payload, :segment),
           ^identity <- segment_participant_identity(segment),
           {:ok, _window} <- PressWindow.claim(meeting_id, identity, DateTime.utc_now()) do
        claim_ask_transcript_segment(socket, segment)
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  # AUDIT FINDING, task 01a02c4e stage 3 — this clause is new behaviour, not a
  # refactor. `Chat.remove_participant/1` broadcasts `{:participant_left,
  # deleted}` on `chat:space:<id>` (`chat.ex:1556`). Before this stage
  # MeetingLive took a RAW `ChatPubSub.subscribe/1`, so when the viewer was
  # revoked mid-meeting the shell's own release (`shell_live.ex`'s
  # `{:participant_left, viewer}` branch) called `Registry.unregister/2` and
  # destroyed MeetingLive's registration ALONG WITH its own. Delivery stopped
  # by accident, via the over-broad unregister.
  #
  # Per-owner release removes that accident: the shell releases only
  # `:presence`, so `:meeting` would keep the topic pinned open and a revoked
  # viewer sitting in the room would go on receiving `{:new_message, _}`. This
  # is the same shape task 01a01a1b stage 3 hit on ChatLive, and the same fix:
  # the owner has to do its own half. Correct ownership without it is a leak.
  #
  # Narrowed to the VIEWER's own row on THIS meeting's chat space. The clause
  # also fires for other people leaving, and for the meetings ROOM topic's
  # like-named event (`meetings.ex:2889`), neither of which may drop the hold —
  # hence the space-id equality rather than a bare participant-id test.
  def handle_info({:participant_left, participant}, socket) do
    socket =
      if viewer_lost_meeting_space?(socket, participant) do
        socket
        |> SpaceTopics.release(participant.space_id, :meeting)
        |> SpaceTopics.release_agents(participant.space_id, :meeting)
      else
        socket
      end

    {:noreply, refresh_participants(socket)}
  end

  def handle_info({:participant_updated, _participant}, socket) do
    {:noreply, refresh_participants(socket)}
  end

  # A runtime answered `meeting_join` with a failure (task 01a0554f).
  #
  # This is the clause that makes the invite control honest. Before it, the
  # ONLY feedback a human got was the optimistic flash at dispatch time, so an
  # agent that answered "error" a few hundred milliseconds later was
  # indistinguishable on this screen from one that was still connecting — and
  # stayed that way for the rest of the call.
  #
  # The roster row is left alone on purpose. `Meetings.invite_agent/3` is safe
  # to call twice and reuses the row it already wrote, so keeping the row keeps
  # the retry available; `pending_invite_agent_ids/1` still marks the agent as
  # invited-never-arrived, which is exactly what it is.
  #
  # `refresh_participants/1` is NOT called: nothing about the roster changed,
  # and re-reading it would only cost a query to render the same list.
  # `clear_flash(:info)` is load-bearing, not tidiness. `put_flash/3` on a
  # different key LEAVES the existing one standing, so without it the screen
  # renders "Invited X — waiting for it to join." directly above "X could not
  # join the meeting." — the contradiction this task exists to remove, in a
  # single viewport. Only the `:info` key is cleared: an unrelated error
  # already on screen is not this clause's to discard.
  def handle_info({:agent_join_failed, %{agent_name: agent_name}}, socket) do
    {:noreply,
     socket
     |> clear_flash(:info)
     |> put_flash(
       :error,
       "#{agent_name} could not join the meeting. It may not have a voice worker connected."
     )}
  end

  # Live presence delta on the per-space topic. `broadcast_presence_change`
  # fires this on every LiveKit join/leave (even before/after a room row
  # exists), so it's the resilient signal that keeps the rail + count live
  # without a manual refresh. We also (re)subscribe to the now-active room
  # topic so the granular `{:participant_joined,_}`/`{:participant_left,_}`
  # events flow if the room was activated after mount.
  #
  # THAT RE-SUBSCRIBE USED TO ACCUMULATE (found while closing task
  # `01a02c4e`'s Route B leak, fixed here because it is the same defect).
  # This clause fires on EVERY LiveKit join/leave, and it called
  # `MeetingsPubSub.subscribe_room/1` unconditionally. `Phoenix.PubSub`
  # starts its registry with `keys: :duplicate` and `subscribe/3` is a bare
  # `Registry.register/3`, so a repeat subscribe ADDS a registration rather
  # than being a no-op: an n-person meeting left this pid with n+1
  # registrations on the room topic and delivered every room event n+1 times.
  # A guest reached 2 before any human did anything, because
  # `maybe_upsert_guest_presence/4` broadcasts a presence change during the
  # guest's own entry. `subscribe_room_once/2` makes it idempotent.
  def handle_info({:meeting_presence_update, _payload}, socket) do
    socket =
      case socket.assigns[:meeting] do
        %{id: meeting_id, chat_space_id: space_id} when is_binary(space_id) ->
          case Meetings.get_active_room(space_id) do
            %{id: room_id} -> subscribe_room_once(socket, room_id, meeting_id)
            _ -> socket
          end

        _ ->
          socket
      end

    {:noreply, refresh_participants(socket)}
  end

  # Live canvas-creation broadcasts on the meeting's chat-space topic.
  # If the meeting doesn't yet have a tracked canvas, latch on to this
  # one so a peer's "Create canvas" click flips this LV's center stage
  # without a refresh. If we already have one, prefer the newer (the
  # most-recently-created canvas wins, matching `latest_canvas/1`).
  #
  # Stage 3 (task 019ff704) adds the picker's list to what this refreshes:
  # a canvas created by a peer has to APPEAR in the picker, otherwise the
  # only way to reach it is a page reload. The list is appended to rather
  # than re-queried so the ordering contract (`list_canvases/1` is
  # oldest-first, and `latest_canvas/1` takes the last) still holds.
  #
  # The rendered canvas only latches on when the viewer has NOT picked
  # one: an explicit `:selected_canvas_id` outranks a peer's new canvas,
  # because being moved off the canvas you chose is precisely the yank
  # this ticket exists to stop.
  #
  # Stage 4 (task 019ff704) closes the loop: the suppressed canvas is not
  # merely ignored, it is SIGNALLED. It joins `:meeting_canvases` and,
  # by having no `:canvas_seen_revisions` baseline, wears a dot in the
  # picker. The list is where you go to change what you are looking at,
  # so the list is where the news belongs.
  #
  # This repo has already made this exact call once, and the precedent is
  # cited rather than paraphrased because the temptation recurs:
  # `Platform.Chat.AttentionRouter` REMOVED its `primary_agent_id`
  # fallback because it "silently reopened the eye the user had just
  # closed". Auto-switching the canvas view is the same move on a
  # different surface — and it stays refused even for a viewer who
  # happens to be idle, because "they were not doing anything" is a guess
  # about a person, not a fact about the system. It never moves you; you
  # move yourself.
  def handle_info({:canvas_created, canvas}, socket) do
    %{assigns: %{meeting: meeting, meeting_canvas: current}} = socket

    cond do
      is_nil(meeting) ->
        {:noreply, socket}

      canvas.space_id != meeting.chat_space_id ->
        {:noreply, socket}

      true ->
        socket = assign(socket, :meeting_canvases, append_canvas(socket, canvas))

        cond do
          # A viewer who chose a canvas keeps it. The new one is in the
          # picker wearing a dot; switching is their decision to make.
          # No `mark_canvas_seen/2` here, deliberately — the missing
          # baseline IS the dot.
          is_binary(socket.assigns[:selected_canvas_id]) ->
            {:noreply, socket}

          # No explicit pick: today's latch-onto-newest behaviour is
          # unchanged. The canvas becomes the one on screen, so it is
          # seen by definition and must not also be dotted.
          is_nil(current) ->
            {:noreply, socket |> assign(:meeting_canvas, canvas) |> mark_canvas_seen(canvas)}

          newer?(canvas, current) ->
            {:noreply, socket |> assign(:meeting_canvas, canvas) |> mark_canvas_seen(canvas)}

          # Older than what we already show, and nobody picked: it stays
          # off screen, so it is news like any other.
          true ->
            {:noreply, socket}
        end
    end
  end

  # Live canvas-update broadcasts: refresh the cached struct so the
  # rendered document reflects the latest server state when the active
  # meeting canvas is the one that changed.
  #
  # Stage 2 (task 019ff704) widened the reason this matters. The canvas
  # tile (`<.canvas_tile>`, rendered in the gallery grid and the bottom
  # strip) reads the SAME source canvas as the canvas view —
  # `canvas_tile_canvas/1` — so it is on screen in gallery / screen /
  # whiteboard modes, where the canvas view is not. A refresh that only
  # fired for the view would leave the tile frozen at mount, which is
  # exactly the failure this ticket exists to prevent. The canvas VIEW's
  # behaviour is deliberately unchanged here: the same struct is
  # reassigned, on the same condition.
  #
  # `:canvas_tile_changed?` is the transient just-changed marker the tile
  # renders once and then stills (no looping animation — see the
  # component moduledoc). It is cleared by a self-scheduled message so
  # the highlight decays on its own rather than persisting for the rest
  # of the call.
  def handle_info({:canvas_updated, canvas}, socket) do
    # Refresh the picker's copy first, and only for a canvas already in
    # the list — an update for a canvas this LV never loaded belongs to
    # another space and must not be pulled into this meeting's picker.
    # This keeps a renamed canvas's picker row current without touching
    # which canvas is RENDERED, which the clause below still owns.
    socket =
      if Enum.any?(socket.assigns[:meeting_canvases] || [], &(&1.id == canvas.id)) do
        assign(socket, :meeting_canvases, append_canvas(socket, canvas))
      else
        socket
      end

    case canvas_tile_canvas(socket.assigns) do
      %{id: id} when id == canvas.id ->
        Process.send_after(self(), {:clear_canvas_tile_changed, canvas.id}, @canvas_changed_ms)

        {:noreply,
         socket
         |> assign(:meeting_canvas, canvas)
         |> assign(:canvas_tile_changed?, true)
         # In view means seen: advance the baseline to the revision that
         # just landed so this edit never becomes a dot on the canvas
         # the viewer is watching it happen on. An update to any OTHER
         # canvas takes the clause below, leaves its baseline behind,
         # and therefore raises the dot in the picker.
         |> mark_canvas_seen(canvas)}

      _ ->
        {:noreply, socket}
    end
  end

  # Decay the one-shot highlight. Scoped to the canvas id that set it so
  # a later update to a DIFFERENT canvas can't be un-marked by an older
  # timer.
  def handle_info({:clear_canvas_tile_changed, canvas_id}, socket) do
    case canvas_tile_canvas(socket.assigns) do
      %{id: ^canvas_id} -> {:noreply, assign(socket, :canvas_tile_changed?, false)}
      _ -> {:noreply, socket}
    end
  end

  # Index PubSub: a peer (or this user) created/started/ended a meeting.
  # Re-query the global list and re-group rather than insertion-sort the
  # assigns — the dataset is small (one row per meeting per project) and
  # simplicity beats cleverness here. Subscribe-once-per-project ensures
  # the broadcast lands on a process that owns these assigns.
  #
  # `:meeting_cancelled` is on the list because the calendar must UNDRAW a
  # cancelled meeting: `CalendarWindow.placeable?/1` excludes the status,
  # but only if the assigns are refreshed to notice the change. Without it
  # the grid would keep showing a meeting that is off until a navigation.
  def handle_info({tag, %Meetings.Meeting{}}, socket)
      when tag in [:meeting_created, :meeting_started, :meeting_ended, :meeting_cancelled] do
    if Map.has_key?(socket.assigns, :meetings) do
      # Scoped with the same viewer as the initial render. A peer's
      # broadcast re-queries the list, so an unscoped read here would
      # re-leak a foreign meeting into an index that mounted correctly —
      # the live-update half of the same rule, not a separate one.
      meetings = Meetings.list_meetings_for_user(socket.assigns[:current_user_record])

      {:noreply,
       socket
       |> assign(:meetings, meetings)
       |> assign(:grouped_meetings, group_meetings_by_status(meetings))
       |> refresh_calendar_week()}
    else
      {:noreply, socket}
    end
  end

  # The minute tick that keeps the now-line honest. Re-arms itself so the
  # cadence survives as long as the index is mounted.
  #
  # It MUST re-assign the instant, and this clause used to claim the
  # opposite ("re-assigns nothing: the render reads the clock, this only
  # forces the beat"). That premise is false and it shipped a now-line
  # frozen at mount for the life of the session. LiveView diffs on
  # ASSIGNS: a beat that changes no assign produces no diff, the
  # template's offset expression is never re-evaluated, and it does not
  # matter what that expression would have read had it run. Observed
  # directly — an unrelated broadcast that re-rendered the page left the
  # line's `top` byte-identical two minutes on, because the broadcast
  # dirtied the meetings list and nothing the line depends on.
  #
  # The timer itself was never the fault: traced on the LiveView process,
  # `:calendar_tick` lands 60s after mount and again 60s after that.
  def handle_info(:calendar_tick, socket),
    do: handle_info({:calendar_tick, DateTime.utc_now()}, socket)

  # The instant arrives as an argument on this clause so the beat is
  # drivable at a chosen time without sleeping through a real minute —
  # which is the only way to assert that the rendered offset MOVED,
  # rather than that a now-line element exists (it always did).
  def handle_info({:calendar_tick, %DateTime{} = now}, socket) do
    schedule_calendar_tick()
    {:noreply, assign(socket, :calendar_now, now)}
  end

  # The GUEST half of the two-surface agent-activity tick (task 01a06e07
  # stage 3, correction 1). See `enter_guest_topics/2` for why this needs
  # its own message name and its own clause here rather than reusing
  # `MeetingHooks`' hook-owned `:agent_activity_tick`: `attach_guest/1`
  # installs no `:meeting_info` hook, by existing design, so nothing but
  # this module ever sees a guest socket's info messages.
  #
  # Same shape as `:calendar_tick` just above and the same reason it must
  # actually reassign the clock rather than merely re-arm: LiveView diffs
  # on assigns, and a beat that changes nothing produces nothing for the
  # client to redraw. `MUST stay ABOVE the catch-all below — see that
  # clause's own comment.
  def handle_info(:agent_activity_tick_guest, socket) do
    schedule_agent_activity_tick_guest()
    {:noreply, assign(socket, :agent_activity_now, DateTime.utc_now())}
  end

  # ── Intents-collapse live updates (task 019f70b8 stage 7) ────────────────
  #
  # MUST stay ABOVE the catch-all below — the catch-all swallows anything
  # declared after it, silently, and a silently-swallowed queue event is
  # exactly the invisibility this task exists to remove.
  #
  # All nine events carry the full row map, so the strip updates from
  # the broadcast without a second trip to the queue server. The row is
  # upserted by id and the list re-sorted on the server's monotonic
  # `seq`, so an out-of-order delivery cannot reorder the bar.
  def handle_info({event, %{id: _id, meeting_id: _meeting_id} = row}, socket)
      when event in @intent_events do
    if intents_for_this_meeting?(socket, row) do
      {:noreply,
       socket
       |> assign(:intents, upsert_intent(socket.assigns.intents, row))
       |> resolve_pending_cancel(event, row)}
    else
      {:noreply, socket}
    end
  end

  # Mid-meeting role change. Re-resolves the gate and, when the bar has
  # just become visible, seeds it from the live queue — a producer
  # appointed at minute 20 needs the intents from minutes 0-20, not only
  # the ones broadcast after their appointment.
  def handle_info({:role_assignment_changed, %{role_key: @intent_producer_role}}, socket) do
    case socket.assigns[:meeting] do
      %{id: meeting_id} ->
        socket = assign_intents_gate(socket)

        socket =
          if socket.assigns.intents_visible? do
            assign(socket, :intents, IntentQueue.list(meeting_id))
          else
            # Gate closed under them: drop the queue contents along with
            # the DOM so a stale render can't leak rows the viewer may no
            # longer see.
            socket
            |> assign(:intents, [])
            |> assign(:intent_edit_row, nil)
            |> assign(:intent_reason_picker_id, nil)
            |> assign(:intents_expanded, false)
          end

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # A candidate lifecycle event (task 01a03fba stage 4).
  #
  # MUST stay ABOVE the catch-all, for the same reason the mute clause
  # below does: a swallowed event is a stop button that needs a page
  # reload before the card disappears, and a countdown ring that keeps
  # counting after somebody else stopped it.
  #
  # The whole open list is re-read rather than patched from the event.
  # The event says WHAT happened, not what the rail should now contain,
  # and three of the writes that reach this clause (a stop, a fire, a
  # retraction) REMOVE a card while a fourth (`:threaded`) moves one
  # card's `acts_at` — deriving the new list from the payload would mean
  # reimplementing `open_for_meeting/1`'s predicate in the view, where it
  # could disagree with the sweeper's.
  #
  # This is ALSO the "crumble" signal for the ask-floor veil (task
  # 01a0cf5c stage 3): `resolve_ask_outcome_on_candidate_closed/2` below
  # fires the client's crumble transition off this SAME broadcast, not a
  # client-side guess — see its doc for why.
  def handle_info({:candidate_event, %{meeting_id: meeting_id} = event}, socket) do
    socket = resolve_ask_outcome_on_candidate_closed(socket, event)

    if socket.assigns[:meeting] && socket.assigns.meeting.id == meeting_id do
      {:noreply, assign_candidate_board(socket, meeting_id)}
    else
      {:noreply, socket}
    end
  end

  # Per-meeting intent mute changed (task 019fbaac stage 3).
  #
  # MUST stay ABOVE the catch-all below, like the intent-queue clauses.
  # A clause declared after it is silently swallowed, and a swallowed
  # mute event is a toggle that needs a page reload — which fails the one
  # requirement of this task that cannot be traded away.
  #
  # No `push_event` and no new subscription: every MeetingLive is already
  # subscribed to `meeting_topic(meeting.id)` at mount, and each one
  # re-renders from its own assign. Same shape as the
  # `:role_assignment_changed` clause above, which is how the intents bar
  # already appears and disappears mid-meeting.
  #
  # The id guard reuses `intents_for_this_meeting?/2` — the payload
  # carries `:meeting_id`, which is the only key that predicate reads —
  # so one LiveView cannot be muted by another meeting's broadcast.
  def handle_info(
        {:intent_mute_changed, %{meeting_id: _id, muted_at: muted_at} = payload},
        socket
      ) do
    if intents_for_this_meeting?(socket, payload) do
      {:noreply, assign(socket, :intent_muted?, not is_nil(muted_at))}
    else
      {:noreply, socket}
    end
  end

  # Someone saved the whiteboard (task 019fcfcf stage 4).
  #
  # MUST stay ABOVE the catch-all, like the clauses above it.
  #
  # This is a NOTICE, not a sync. v1 is SINGLE-EDITOR: we set an assign
  # that renders a passive badge with a Reload link and we do NOT push the
  # remote scene down — applying it would paint over strokes the local user
  # is drawing right now, which is precisely the loss the `scene_version`
  # compare-and-set exists to prevent.
  #
  # Two guards, both load-bearing:
  #
  #   * `by_user_id != user_id` — the saver's own broadcast comes back to
  #     them too, and telling someone their own save happened elsewhere is
  #     a false alarm that trains people to dismiss the real one.
  #   * `scene_version > the version this socket holds` — a replay or an
  #     out-of-order delivery must not raise a badge for a state this
  #     client already has.
  def handle_info(
        {:whiteboard_scene_saved,
         %{meeting_id: meeting_id, scene_version: version, by_user_id: by_user_id}},
        socket
      ) do
    mine? = not is_nil(by_user_id) and by_user_id == socket.assigns[:user_id]

    cond do
      not whiteboard_for_this_meeting?(socket, meeting_id) -> {:noreply, socket}
      mine? -> {:noreply, socket}
      version <= (socket.assigns[:whiteboard_version] || 0) -> {:noreply, socket}
      true -> {:noreply, assign(socket, :whiteboard_remote_version, version)}
    end
  end

  # ── Per-meeting agent activity (task 01a04a98) ───────────────────────────
  #
  # MUST stay ABOVE the catch-all. `{:agent_typing, …}` was already being
  # delivered to this pid and was already being swallowed here, which is
  # how the tile came to render a hardcoded `:idle` while a real signal
  # went past it every reply.
  #
  # `{:agent_activity, …}` arrives on the meeting SHELL topic from
  # `AgentActivity.mirror_intent_row/2` — one publisher per transition,
  # and the one topic guests hold.
  def handle_info(
        {:agent_activity,
         %{meeting_id: meeting_id, agent_id: agent_id, signal: signal, active?: active?}},
        socket
      ) do
    if activity_for_this_meeting?(socket, meeting_id) do
      {:noreply,
       update(socket, :agent_activity, &AgentActivity.put(&1, signal, agent_id, active?))}
    else
      {:noreply, socket}
    end
  end

  # `{:agent_typing, …}` rides the meeting's `chat:space:<id>` topic and
  # carries a `Chat.Participant` id, NOT an `Agents.Agent` id — every
  # meeting surface keys agents by the latter, so the bridge is what makes
  # the signal addressable at all. It returns nil for a human participant,
  # so a person typing in the meeting chat cannot light an agent tile.
  # The bridge AND the fold live in `AgentActivity.put_typing/3`, shared
  # with the quickmeet (`MeetingHooks.apply_agent_typing/2`); this clause
  # owns only the "is this my meeting's space" guard.
  #
  # NOT re-broadcast onto the shell topic: every authenticated MeetingLive
  # already receives this event once, and a rebroadcast from each of them
  # would fan one keystroke toggle out N×N. The cost is that guests, who
  # hold no chat-space topic, do not see typing — stated in
  # `Platform.Meetings.AgentActivity`'s moduledoc rather than papered over.
  def handle_info(
        {:agent_typing, %{space_id: space_id, participant_id: participant_id, typing: typing}},
        socket
      ) do
    if meeting_space?(socket, space_id) do
      {:noreply,
       update(socket, :agent_activity, &AgentActivity.put_typing(&1, participant_id, typing))}
    else
      {:noreply, socket}
    end
  end

  # An agent was added to, removed from, or promoted on a space's roster
  # (task 01a0691d stage 3). `refresh_participants/1` re-derives
  # `:invite_rows` and its clickable projection, so the People tab gains or
  # loses the row without a reload.
  #
  # Matched on the MEETING'S space, and the second clause is not decoration:
  # `ShellLive`'s roster branch holds `space_agents:<id>` on this same pid for
  # ITS visible space, which is not necessarily this meeting's, so a message
  # for an unrelated space genuinely arrives here. `refresh_participants/1` is
  # keyed on the meeting's own space and would answer the same thing either
  # way, so the guard skips a pointless refetch rather than closing a leak —
  # said plainly because a reader who assumes otherwise would delete it.
  def handle_info(
        {:roster_changed, space_id},
        %{assigns: %{meeting: %Meeting{chat_space_id: space_id}}} = socket
      ) do
    {:noreply, refresh_participants(socket)}
  end

  def handle_info({:roster_changed, _space_id}, socket), do: {:noreply, socket}

  # Recording started or stopped in this room (task 01a0740d stage 2).
  # Arrives on the ROOM topic, which this pid already holds via
  # `subscribe_room_once/2` — stage 1 deliberately put the broadcast on the
  # existing `MeetingsPubSub.room_topic/1` rather than a topic of its own, so
  # there is no second subscription here and nothing to unsubscribe.
  #
  # The payload is ignored on purpose; see `room_recording?/1`. Re-reading is
  # what makes the pill track the room's live capture rather than the last
  # event that happened to reach this pid.
  #
  # Only `:room_recording?` moves. A recording write does not change the
  # roster, so calling `refresh_participants/1` here would spend four reads
  # to re-derive assigns nothing asked for.
  def handle_info(
        {:recording_updated, _recording},
        %{assigns: %{meeting: %{chat_space_id: space_id}}} = socket
      )
      when is_binary(space_id) do
    {:noreply, assign(socket, :room_recording?, room_recording?(space_id))}
  end

  def handle_info({:recording_updated, _recording}, socket), do: {:noreply, socket}

  # Discussion unread marker (task 01a0740d).
  #
  # MUST STAY ABOVE THE CATCH-ALL. Until this ticket `meeting_live.ex` had
  # no `{:new_message, _}` clause at all and every one of these fell into
  # the ignore-everything clause below. The data was already arriving: the
  # connected-mount branch takes `SpaceTopics.hold(socket, chat_space_id,
  # :meeting)`, which subscribes `chat:space:<id>`, and `Platform.Chat`
  # broadcasts `{:new_message, %Message{}}` there on every post. Nothing
  # was listening.
  #
  # The real handler for a message is `ChatLive.MessagesHooks`, running
  # inside the SEPARATE embedded `ChatLive.Embedded` that the drawer
  # `live_render`s. That process streams the message; this one only needs
  # to know whether the viewer SAW it.
  def handle_info({:new_message, %Platform.Chat.Message{} = msg}, socket) do
    {:noreply, maybe_raise_rail_unread(socket, msg)}
  end

  # Catch-all: chat-space topic carries many event shapes (messages,
  # reactions, pins, …). The shell only cares about roster + canvas
  # events; ignore the rest so a broadcast can't crash the LV.
  def handle_info(_event, socket), do: {:noreply, socket}

  # Three gates, each closing a different way the dot would lie.
  #
  #   * chat is on screen — the viewer is looking at the message as it
  #     lands, and a message you are reading is not unread. This used to
  #     read `:chat_panel_open`; task 01a084bf stage 3 deleted that drawer
  #     and made chat a rail pane, so the question became "is the Chat tab
  #     the pane on screen" (see `chat_on_screen?/1`). Left FALSE rather
  #     than set, never cleared here: the clear belongs to
  #     `"toggle_chat_panel"` and to selecting the Chat tab.
  #   * space — this pid holds more than one `chat:space:<id>` topic (the
  #     shell holds the viewer's whole presence set on the same process),
  #     so an unrelated room's traffic would otherwise raise a dot on this
  #     meeting's rail.
  #   * author — `author_user_id` is the ADR 0038 identity snapshot written
  #     at post time, so the viewer's own message never marks itself
  #     unread. It is a real column on `Platform.Chat.Message`, not a
  #     guess, which is why this sub-rule is implemented rather than
  #     skipped.
  defp maybe_raise_rail_unread(socket, %Platform.Chat.Message{} = msg) do
    if rail_unread_worthy?(socket, msg) do
      assign(socket, :call_rail_unread, true)
    else
      socket
    end
  end

  defp rail_unread_worthy?(socket, %Platform.Chat.Message{} = msg) do
    not chat_on_screen?(socket.assigns) and
      message_for_this_meeting?(socket, msg) and
      not own_chat_message?(socket, msg)
  end

  # Is the discussion the pane the viewer is actually looking at?
  #
  # Two assigns, because the rail can be showing Chat and still not be
  # showing it: at `lg` a collapsed rail is a 44px icon strip with no pane
  # in it at all, so `:active_meeting_tab` alone would suppress a dot the
  # viewer has no way to read.
  #
  # `:call_rail_open` is deliberately NOT consulted. It is the `<lg` drawer
  # latch and is `false` on a desktop viewport where the rail is a
  # permanently in-flow column, so folding it in would raise a dot for every
  # desktop viewer sitting on the Chat tab — the exact lie this predicate
  # exists to prevent. The server cannot see the viewport; between the two
  # errors available to it, missing a dot for a phone viewer who left the
  # rail drawer closed on the Chat tab is the cheaper one.
  #
  # Subscript access and `!` rather than `not`: both assigns are seeded at
  # both mount sites, but `not nil` would RAISE on any path that ever missed
  # one, and a crashed LiveView is a worse answer than a wrong dot.
  #
  # `normalize_tab/1` — THE VOCABULARY, NOT `served_meeting_tabs/1`, AND THAT
  # IS A DECISION (task 01a089fe stage 3, which gated the `<:chat>` slot on
  # `@shell?` and was handed this call site as a follow-on).
  #
  # The concern is real in shape: this reads the four-tab vocabulary while
  # `call_rail/1` coerces against the list the caller actually serves, so on
  # an `@shell?`-false surface this answers "chat is on screen" for a viewer
  # whose rail is drawing People. It is defect 1's shape one layer out, and
  # `normalize_tab/2`'s `\\ @tabs` default is what makes it silent.
  #
  # IT WAS CHANGED AND THE CHANGE WAS MEASURED AND WITHDRAWN. Passing the
  # served list here reds `meeting_live_rail_collapse_test.exs:497`, "a
  # message arriving while the drawer is OPEN does not raise the flag" — a
  # test on the `:meet_member` surface (`open_meeting/3`: signed-in account on
  # the `meet.` host, `chrome_mode: "none"`, so `@shell?` FALSE), which unlike
  # the guest DOES hold `chat:space:<id>` (`handle_params/3` reaches
  # `SpaceTopics.hold/3` because that mount leaves `:state` nil). So this is
  # not dead state on every `@shell?`-false surface, and "correcting" it
  # rewrites the unread-flag contract on a third surface that has its own
  # describe and its own reasoning. That is a separate piece of work from "a
  # guest's chat slot is absent", so it is reported rather than smuggled in.
  #
  # WHAT IT IS NOT: it is not the guest defect stage 1 predicted. On the GUEST
  # surface this predicate cannot be observed at either answer —
  # `enter_guest_topics/2` subscribes to presence, agents and the meeting
  # topic and takes NO `SpaceTopics.hold/3`, so `{:new_message, _}` never
  # arrives and the flag cannot rise; and the flag's only two renderers sit
  # inside tab loops (`id == "chat" and @call_rail_unread` in the strip,
  # `data-role="call-rail-tab-unread-dot"` in `call_rail/1`) which hold no
  # `"chat"` entry for a guest now. Neither producer nor renderer exists
  # there, which is also why no test in this repo can cover the guest half.
  #
  # AND THE LIVE TWIN IS SOMEWHERE ELSE ENTIRELY: the `"meeting_tab_select"`
  # clause in THIS module is dead on `/meetings` (see it below), and the
  # normalisation that actually runs is
  # `PlatformWeb.ChatLive.MeetingHooks.handle_event("meeting_tab_select", …)`,
  # which also calls `normalize_tab/1`.
  defp chat_on_screen?(assigns) do
    CallShell.normalize_tab(assigns[:active_meeting_tab]) == "chat" and
      !assigns[:chat_panel_collapsed]
  end

  # The call rail tabs THIS surface serves, for a viewer with this `@shell?`
  # (task 01a089fe stages 1 and 3).
  #
  # ONE READER TODAY: the COLLAPSED 44px icon strip in
  # `meeting_live.html.heex`. The expanded rail is `CallShell.call_rail/1`,
  # which computes `served_tabs/1` off the slots it was handed and coerces
  # `active_tab` against THAT list. The strip is markup in this module's
  # template, holds no slots, and cannot be filtered by reading them; it used
  # to loop `CallShell.tabs/0`, the unfiltered vocabulary, which is defect 1
  # of this task (stage 1).
  #
  # TWO OTHER CALL SITES LOOK LIKE THEY BELONG HERE AND DELIBERATELY DO NOT —
  # `chat_on_screen?/1` and the `"meeting_tab_select"` clause, both of which
  # call `CallShell.normalize_tab/1` and so read the vocabulary. Pointing them
  # at this function was tried, measured and withdrawn in stage 3: one reds an
  # existing `:meet_member` test and the other is dead code on `/meetings`.
  # The measurement and the reasoning are on each of those two functions, and
  # this note exists so the next reader finds them BEFORE concluding the
  # inconsistency is an oversight.
  #
  # `chat: shell?` IS THIS SURFACE'S CAPABILITY, NOT A SPELLING OF
  # `CallShell.tabs/0`, and it is the same `@shell?` the `<:chat>` slot's own
  # `:if` reads — one condition, stated once, reached by both presentations
  # and both coercions. NOT a `tabs` attr on `call_rail/1` and NOT a literal
  # list here: either would be the second tab list `served_tabs/1`'s own docs
  # exist to refuse.
  #
  # `shell? == true` rather than `!!shell?`: both mount sites seed the assign,
  # but a nil arriving from some future path must read as "no chat" instead of
  # raising in a render.
  #
  # `serve_canvas_tab: false` because this strip is the DESKTOP collapsed rail
  # (`hidden lg:flex`), and at `lg` the card board is the first-class LEFT rail
  # beside the agents rather than a Canvas tab here (task 01a0693e). The
  # expanded rail passes the same `serve_canvas_tab={@mobile_viewport?}` — false
  # at `lg` — so the strip and the expanded tablist stay one derivation.
  @spec served_meeting_tabs(term()) :: [{String.t(), String.t()}]
  defp served_meeting_tabs(shell?) do
    CallShell.served_tabs(%{chat: shell? == true, serve_canvas_tab: false})
  end

  # A struct that carries NO space id is not attributed to another room, so
  # it is not filtered out on that basis — only a space id that is present
  # and different disqualifies.
  defp message_for_this_meeting?(socket, %Platform.Chat.Message{space_id: space_id}) do
    case socket.assigns[:meeting] do
      %{chat_space_id: meeting_space_id} when is_binary(meeting_space_id) ->
        not is_binary(space_id) or space_id == meeting_space_id

      _ ->
        false
    end
  end

  defp own_chat_message?(socket, %Platform.Chat.Message{author_user_id: author_user_id}) do
    is_binary(author_user_id) and author_user_id == socket.assigns[:user_id]
  end

  # Flip a `scheduled` meeting to `live` (stamping `started_at` and
  # broadcasting `{:meeting_started, _}` so the index re-buckets it under
  # "Live now"). Guarded on `"scheduled"` because `status_changeset` rejects
  # illegal transitions (a live→live attempt errors); any other status is a
  # no-op. On success the updated meeting is re-assigned so the render path
  # sees the live status.
  defp maybe_start_meeting(%{assigns: %{meeting: %{status: "scheduled"} = m}} = socket) do
    case Meetings.start_meeting(m) do
      {:ok, started} -> assign(socket, :meeting, started)
      {:error, _} -> socket
    end
  end

  defp maybe_start_meeting(socket), do: socket

  # Upsert by id, preserving `list_canvases/1`'s oldest-first ordering so
  # `latest_canvas/1`'s `List.last/1` keeps meaning what it says.
  defp append_canvas(socket, canvas) do
    existing = socket.assigns[:meeting_canvases] || []

    if Enum.any?(existing, &(&1.id == canvas.id)) do
      Enum.map(existing, fn c -> if c.id == canvas.id, do: canvas, else: c end)
    else
      existing ++ [canvas]
    end
  end

  # Only the `:index` action holds calendar assigns; the `:show` and guest
  # surfaces share this PubSub clause and must not be re-queried.
  defp refresh_calendar_week(socket) do
    case socket.assigns do
      %{calendar_anchor_date: %Date{} = anchor, calendar_selected_date: selected} ->
        assign_calendar_week(socket, anchor, selected)

      _ ->
        socket
    end
  end

  # Mirror ChatLive's terminate hook so a tab-close mid-meeting
  # broadcasts the "left" event and the mini-bar doesn't ghost.
  #
  # Task 01a0cf5c stage 3 audit: a dropped socket — tab close, browser
  # crash, navigating away — is a hold-to-ask exit path with no
  # `push_to_talk_release` event to carry it, exactly like the tab-close
  # this hook already exists for. Without this, a held floor would sit
  # locked for `AskFloor.stuck_claim_ms/0` (mirrors
  # `PressWindow.max_hold_ms/0`, two minutes) before the stuck-claim
  # timer evicts it on its own — correct as a backstop, wrong as the
  # ONLY path, since every other viewer's button stays frozen the whole
  # time for a press that is already gone. Releasing here, using the
  # exact same `release_ask_floor/4` the explicit release path calls,
  # closes that gap immediately instead of waiting out the backstop.
  # `PressWindow.release/3` is released alongside it for the same
  # reason: a disconnect mid-press must not leave the presser's speech
  # window claiming segments nobody is still holding a button for.
  @impl true
  def terminate(_reason, socket) do
    release_held_ask_floor_on_terminate(socket)
    MeetingHooks.on_terminate(socket)
    maybe_broadcast_guest_leave(socket)
    :ok
  end

  defp release_held_ask_floor_on_terminate(socket) do
    agent_id = socket.assigns[:pressed_agent_id]

    with %{id: meeting_id} <- socket.assigns[:meeting],
         identity when is_binary(identity) <- press_identity(socket) do
      PressWindow.release(meeting_id, identity)
      release_ask_floor(socket, meeting_id, agent_id, identity)
    end

    :ok
  end

  # 019f498d re-dispatch: guest surface leave-broadcast. The auth surface
  # is subscribed to the room + presence topics, so marking the guest row
  # as `left_at` here retires the guest tile on the host without waiting
  # for LiveKit's `participant_left` webhook (which isn't reachable in
  # dev / test — see meeting_hooks.ex v4 comment). Best-effort:
  # tolerated as a safe no-op when the guest never fully entered the
  # meeting (name-entry state, invalid token, etc.).
  defp maybe_broadcast_guest_leave(%{
         assigns: %{chrome_mode: :none, state: :in_meeting, identity: identity, meeting: meeting}
       })
       when is_binary(identity) do
    with %{chat_space_id: space_id} when is_binary(space_id) <- meeting,
         %{} = room <- Meetings.get_active_room(space_id) do
      Meetings.mark_live_participant_left(room, %{identity: identity, name: nil})
    end

    :ok
  end

  defp maybe_broadcast_guest_leave(_socket), do: :ok

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Guest ingress transition (task 019f498d stage 3): mint the LiveKit
  # bundle for `display_name`, seed the same assigns MeetingLive normally
  # sets in `handle_params/3` for the meeting shell (participants,
  # agents_by_id, canvas, active_space, stage mode, guest-invite sheet
  # defaults so the render doesn't crash on missing keys), install the
  # guest-safe meeting-event hook via `MeetingHooks.attach_guest/1`, and
  # push `join-meeting` with the exact payload shape MeetingClient
  # consumes.
  #
  # ON MINT FAILURE, DO NOT LAND ON `:invalid` (task 019f9cb7 stage 2).
  # This comment used to argue the opposite — that a mint issue is
  # "indistinguishable from an invalid invite from the guest's POV", so
  # both should share the invalid-invite card. That reasoning is wrong in
  # the only direction that matters: the two are trivially distinguishable
  # to US, and we are the only party who can act on the difference. The
  # guest, told their link is bad, goes back to their host for a
  # replacement that fails identically, while the real fault stays silent
  # to operators. `guest_mint_failure/3` below now splits the outcomes.
  #
  # Called from both the mount clause (invite payload carried a
  # display_name) and the `"submit_name"` event handler (guest typed
  # their own name). Keeping the code in ONE helper means the two
  # entry points cannot drift.
  defp enter_meeting_as_guest(socket, meeting, display_name)
       when is_binary(display_name) do
    case Meetings.mint_guest_join_bundle(meeting, display_name) do
      {:ok, bundle} ->
        # RELEASE BEFORE RE-SUBSCRIBING (task 01a02c4e stage 4). This helper
        # has TWO entry points and one of them can run while the guest is
        # already `:in_meeting`: `"submit_name"` re-enters here, so without
        # this line the three subscribes below would land ON TOP of the
        # subscriptions taken by the previous entry.
        #
        # That is not a harmless repeat. `Phoenix.PubSub` starts its registry
        # with `keys: :duplicate`; `Phoenix.PubSub.subscribe/3` is a bare
        # `Registry.register/3`, so a second subscribe ADDS a second
        # registration for the same pid and every broadcast on the topic is
        # then delivered TWICE to this LiveView. (`Phoenix.PubSub.unsubscribe/2`
        # is `Registry.unregister/2`, which removes ALL of the pid's
        # registrations for the topic — the asymmetry that makes
        # subscribe-without-release a real duplicate rather than a no-op.)
        socket = MeetingHooks.release_guest_topics(socket)

        socket =
          if connected?(socket) and is_binary(meeting.chat_space_id) do
            enter_guest_topics(socket, meeting)
          else
            socket
          end

        # 019f498d re-dispatch: land the guest in the shared live-presence
        # table so the auth-side MeetingLive session (subscribed to the
        # same presence + room topics) refreshes `@participants` and
        # renders a `.video_tile` with `data-participant="guest:<random>"`
        # matching the identity the guest publishes on LiveKit. Without
        # this the LiveKit RTP flow arrives on the auth surface but has
        # no DOM element to mount onto — the failing V1/V5 e2e symptom.
        maybe_upsert_guest_presence(socket, meeting, bundle, display_name)

        socket =
          socket
          |> seed_guest_shell_tree_assigns(meeting)
          |> assign(:state, :in_meeting)
          |> assign(:page_title, meeting.name)
          |> assign(:display_name, display_name)
          |> assign(:token, bundle.token)
          |> assign(:identity, bundle.identity)
          |> assign(:room_name, bundle.room_name)
          |> assign(:livekit_url, bundle.livekit_url)
          # attach_guest (from seed_guest_shell_tree_assigns) seeds
          # :in_meeting = false to mirror attach/2; flip to true because we
          # push the join event immediately below.
          |> assign(:in_meeting, true)

        push_event(socket, "join-meeting", guest_join_payload(bundle, meeting, socket))

      {:error, reason} ->
        guest_mint_failure(socket, meeting, reason)
    end
  end

  # The lobby's "who is already in" line (task 01a07410 / FE-17 stage 4),
  # from the same `@participants` the in-call roster reads. A presence row
  # whose name did not resolve (`resolve_identity/1` returns nil for an
  # orphaned or unsuffixed row) is still a person in the call, so it is
  # counted as "Someone" rather than dropped or rendered blank.
  @doc false
  def lobby_roster_line([]), do: "Nobody is in the call yet."

  def lobby_roster_line([only]), do: "#{lobby_name(only)} is already in the call."

  def lobby_roster_line([first, second]) do
    "#{lobby_name(first)} and #{lobby_name(second)} are already in the call."
  end

  def lobby_roster_line([first | rest]) do
    "#{lobby_name(first)} and #{length(rest)} others are already in the call."
  end

  defp lobby_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp lobby_name(_), do: "Someone"

  # THE LOBBY'S OWN AGENT LIST -- the gap the meeting-vs-mockups audit named
  # as the single biggest divergence: "an agent silently unable to hear the
  # room, discovered mid-call" is exactly the failure this section exists to
  # surface BEFORE anyone joins, the same way the mock's "Coming" / "Agents"
  # lobby draws it.
  #
  # `@invite_rows` IS ALREADY COMPUTED AND ASSIGNED ON MOUNT
  # (`assign_invite_rows/3`), BEFORE `@state` is decided -- this is not a new
  # query, only a new READ of data the lobby already had sitting in the
  # socket unread. Filtered to `in_space?`, not the full active-agent picker
  # list `invite_rows/2` unions in: the lobby is telling a member which OF
  # THIS MEETING'S OWN agents will be able to hear them, not offering a
  # deployment-wide add-agent picker a pre-join screen has no button for.
  @doc false
  def lobby_agent_rows(invite_rows) do
    Enum.filter(invite_rows, & &1.in_space?)
  end

  # THE SAME TWO STRINGS `CallShell.invite_reason/1` ALREADY SHIPS for
  # `:capable`/`:incapable` ("Voice runtime online" / "No voice runtime
  # online"), not a second spelling of the same fact -- restated here rather
  # than imported because that function is keyed on the INVITE picker's
  # `:state` (invitable/pending/incapable/in_call), a shape the lobby has no
  # equivalent of: a lobby row has nothing to click and nothing pending.
  # `:unknown` renders NO LINE AT ALL, matching `invite_reason/1`'s own
  # `:invitable` + `:unknown` case: a client core the deployment has never
  # heard from is announced as present, not guessed at.
  @doc false
  def lobby_agent_capability_line(:capable), do: "Voice runtime online"
  def lobby_agent_capability_line(:incapable), do: "No voice runtime online"
  def lobby_agent_capability_line(:unknown), do: nil

  # The join payload PLUS the lobby's choice (task 01a07410 / FE-17 stage 4).
  # `:mic_enabled` / `:camera_enabled` are read off the socket AFTER
  # `seed_guest_shell_tree_assigns/2` has run above, which is the point:
  # `MeetingHooks.attach_guest/1` used to reset both to `true` on this
  # transition, and this is the value `meeting_client.js` enters the room
  # with. Read here, not in `Meetings.guest_join_event_payload/2`, because
  # the context has no socket and the pair is LiveView state.
  defp guest_join_payload(bundle, meeting, socket) do
    bundle
    |> Meetings.guest_join_event_payload(meeting)
    |> Map.merge(%{
      mic_enabled: socket.assigns.mic_enabled,
      camera_enabled: socket.assigns.camera_enabled
    })
  end

  # ── Mint-failure presentation for the guest surface (019f9cb7 stage 2) ──
  #
  # A `mint_guest_join_bundle/2` failure is NOT a statement about the
  # invite. The invite was verified by `Meetings.resolve_guest_invite/2`
  # before this helper is reachable, and that resolver — not this one — owns
  # the genuine `:invalid` / `:revoked` / `:expired` decisions. Everything
  # reachable here is ours.
  #
  # Three outcomes, split by what the guest can DO next:
  #
  #   * `:livekit_not_configured` — our media plane is not switched on.
  #     Nothing the guest can fix, so a terminal `:unavailable` card, and a
  #     `Logger.warning` because this was previously silent to operators
  #     while the visitor got blamed for it.
  #   * `:missing_display_name` on a meeting that HAS a chat space — the
  #     name we were handed is unusable (an invite signed with a
  #     whitespace-only name resolves to `:in_meeting` and only fails
  #     here). Recoverable input: back to the name-entry form, which is a
  #     working exit, not a dead end.
  #   * anything else — operational. Logged, `:unavailable`.
  #
  # The CATCH-ALL takes the operational branch deliberately. An unknown
  # future reason must be loud to us; it must never be quietly recast as
  # the visitor's fault. `mint_guest_join_bundle/2` has a closed error set
  # today (`:livekit_not_configured`, `:missing_display_name` — confirmed
  # against the implementation, not just the `@spec`), so the catch-all is
  # currently unreachable and exists to keep the NEXT atom safe.
  #
  # ── Permanence (task 01a04353) ──────────────────────────────────────────
  #
  # `{:fault, …}` carries a SECOND axis the guest copy needs: whether
  # waiting can plausibly help. The `:unavailable` card used to say "please
  # try again in a few minutes" for every fault, which is a promise neither
  # KNOWN fault can keep:
  #
  #   * `:livekit_not_configured` is a synchronous read of
  #     `Application.get_env(:platform, :livekit)`, falling back to the
  #     `LIVEKIT_*` env vars (`Meetings.livekit_config/0`). No network hop,
  #     no retryable I/O — nothing in the request path can turn it green.
  #     Only an operator configuring the node can.
  #   * a nil `chat_space_id` is a data defect. `Meetings.create_meeting/1`
  #     writes the space and the meeting row in ONE `Repo.transaction`, so
  #     there is no async backfill for a guest to outwait; the row is
  #     wrong, and stays wrong until someone repairs it.
  #
  # Both are therefore `:permanent`, and the card says so and points at the
  # only lever that exists — the person who sent the invite, who can reach
  # whoever runs the deployment.
  #
  # The catch-all is `:unknown`, NOT `:permanent`. We have no idea what a
  # future atom means, and a transient upstream failure is exactly the
  # shape it is most likely to take, so it keeps the retry wording. Guessing
  # "permanent" there would just trade one lie for the opposite one.
  defp guest_mint_failure(socket, meeting, reason) do
    case classify_guest_mint_failure(meeting, reason) do
      {:recoverable_name, message} ->
        # Deliberately NOT `:meeting, nil` — the name-entry card titles
        # itself with `@meeting.name`, and the guest is being asked to
        # retry against a meeting they were legitimately invited to.
        socket
        |> assign(:state, :name_entry)
        |> assign(:page_title, "Join #{meeting.name}")
        |> assign(:display_name, nil)
        |> assign(:name_value, "")
        |> assign(:name_error, message)
        |> seed_guest_shell_tree_assigns(meeting)

      {:fault, permanence, log_detail} ->
        # GUEST SURFACE: the log may name the fault and the meeting, never
        # the guest. `meeting.id` is an internal UUID and never rendered.
        #
        # `reason=` carries the RAW atom (task 01a04353). The prose is what
        # a human reading the log wants; the atom is what a grep wants, and
        # the atom is the token that appears in the `@spec`, in
        # `meetings.ex` and in every ticket about this failure. An operator
        # searching `livekit_not_configured` used to get nothing back from
        # the one log line that exists to tell them. Both, not either.
        Logger.warning(
          "Guest meeting ingress refused by a LiveKit mint failure: " <>
            log_detail <>
            ". The invite itself verified; the guest was shown the " <>
            "meeting-unavailable card (" <>
            to_string(permanence) <>
            "). reason=" <>
            to_string(reason) <> " meeting_id=" <> to_string(meeting.id)
        )

        # `:meeting` is KEPT here, where the old clause nil'd it (task
        # 019f9cb7 stage 2). The card names the meeting the guest was
        # invited to, which is the whole difference between "we can't get
        # you into <meeting>" and "your link is junk". Seeding the index
        # fallback rather than the shell tree mirrors `:invalid`: this is a
        # terminal card, it reads `@meeting.name` and nothing else, and one
        # of the faults it renders is a meeting with no chat space — which
        # the shell-tree seeder is not built to survive.
        socket
        |> assign(:state, :unavailable)
        |> assign(:unavailable_kind, permanence)
        |> assign(:page_title, unavailable_page_title(permanence))
        |> assign(:meeting, meeting)
        |> seed_guest_index_fallback_assigns()
    end
  end

  # The title is part of the claim, so it splits with the body copy. A
  # permanently-down media plane is not "temporarily" anything, and the
  # browser tab is the one bit of the card a guest keeps looking at.
  defp unavailable_page_title(:permanent), do: "We can't connect you to this meeting"
  defp unavailable_page_title(:unknown), do: "Meetings are temporarily unavailable"

  # Public (`@doc false`) purely so the permanence decision is testable in
  # both directions (task 01a04353). The `:unknown` clause is the one that
  # keeps the retry wording honest, and it is NOT reachable through
  # `mint_guest_join_bundle/2`'s closed error set — so without this seam the
  # only branch a test could reach is the permanent one, and "the retry copy
  # still exists for a fault that might actually be transient" would be an
  # untested claim. Not part of any stable API; call it from tests only.
  @doc false
  @spec classify_guest_mint_failure(Meeting.t(), atom()) ::
          {:recoverable_name, String.t()} | {:fault, :permanent | :unknown, String.t()}
  def classify_guest_mint_failure(meeting, reason)

  def classify_guest_mint_failure(_meeting, :livekit_not_configured) do
    {:fault, :permanent, "the LiveKit media server is not configured on this node"}
  end

  # `:missing_display_name` has TWO causes and only one of them is about a
  # name. `Meetings.guest_livekit_token/2` guards its happy clause on
  # `is_binary(chat_space_id)`, so a meeting with a nil chat-space FK falls
  # to the catch-all clause and is reported as `:missing_display_name` even
  # when the name was perfect — pinned by
  # `test/platform/meetings/guest_token_test.exs`, whose own comment calls
  # it "an odd label for the shape".
  #
  # Taking the atom at face value would send that guest back to the
  # name-entry form to retype a name that was never the problem, and the
  # retry would fail identically: a loop with no exit. The mislabel lives
  # in `meetings.ex` and cannot be fixed from here, so we discriminate on
  # the shape the atom is hiding instead.
  def classify_guest_mint_failure(%Meeting{chat_space_id: nil}, :missing_display_name) do
    {:fault, :permanent,
     "the meeting has no backing chat space, so no room name can be derived " <>
       "(the mint reports this as a missing display name)"}
  end

  def classify_guest_mint_failure(_meeting, :missing_display_name) do
    {:recoverable_name,
     "We couldn't read the name on your invite. Please enter the name others in the meeting will see."}
  end

  def classify_guest_mint_failure(_meeting, reason) do
    {:fault, :unknown, "an unrecognised mint failure, " <> inspect(reason)}
  end

  # The guest surface's THREE meetings-family subscriptions, taken together
  # and RECORDED (task 01a02c4e stage 4).
  #
  # Every topic subscribed here is written into `:guest_topic_subs` so
  # `MeetingHooks.release_guest_topics/1` can release exactly what was
  # taken. The record exists rather than re-deriving on release for one
  # concrete reason: the room id comes from `Meetings.get_active_room/1`, a
  # DB read whose answer can CHANGE between entry and leave (a room ends,
  # another starts). Re-deriving would then unsubscribe a topic this pid
  # never held and leak the one it does.
  #
  # `subscribe_room_once/2` is the single writer of `:subscribed_room_id`,
  # so the room third of the release below reads the room this pid ACTUALLY
  # holds rather than whatever `get_active_room/1` answers at leave time — a
  # DB read whose answer can change between entry and leave (a room ends,
  # another starts), which would otherwise unsubscribe a topic never held and
  # leak the one that is.
  defp enter_guest_topics(socket, meeting) do
    MeetingsPubSub.subscribe_presence(meeting.chat_space_id)

    # Roster changes for the People tab (task 01a0691d stage 3). Needed HERE
    # for the same reason the intent-mute line below is: the guest mount seeds
    # `:state`, so it never reaches the `:show` body where the member surface
    # takes this hold.
    #
    # NOT recorded in `:guest_topic_subs`, and that is not an omission —
    # `SpaceTopics` IS the record, and a second bookkeeping copy of the same
    # fact is exactly the drift the module exists to remove. The
    # `:guest_meeting` live_session (`router.ex:570`) carries no `ShellLive`
    # on_mount, so on this surface there is no co-owner and no halt to opt out
    # of; a guest cannot invite, but the rail still lists the roster.
    socket = SpaceTopics.hold_agents(socket, meeting.chat_space_id, :meeting)

    # Per-meeting intent mute (task 019fbaac stage 4). This one line
    # is what makes the guest badge live-update, and it is needed
    # HERE precisely because it cannot be inherited: the guest mount
    # clause seeds `:state`, which makes `handle_params/3` no-op, so
    # the guest surface never reaches the `:show` body where the
    # authenticated surface subscribes to `meeting_topic/1`. Same
    # topic string, same `{:intent_mute_changed, …}` clause — the
    # guest LiveView is the SAME module, so no second handler.
    #
    # Ordered BEFORE `seed_guest_shell_tree_assigns/2` reads the
    # current value below: subscribe-then-read leaves no window in
    # which a toggle lands between the read and the subscription.
    MeetingsPubSub.subscribe_meeting(meeting.id)

    socket =
      case Meetings.get_active_room(meeting.chat_space_id) do
        %{id: room_id} -> subscribe_room_once(socket, room_id, meeting.id)
        _ -> socket
      end

    # THE GUEST HALF OF THE TWO-SURFACE AGENT-ACTIVITY TICK (task 01a06e07
    # stage 3, correction 1). `MeetingHooks.attach_guest/1` deliberately
    # installs NO `:meeting_info` hook (see its own @doc — the guest
    # surface owns its presence/canvas handlers directly in THIS module),
    # so the shared hook clause in `MeetingHooks` that drives
    # `/meetings`-authenticated and the quickmeet never reaches a guest
    # socket. This is the guest's own equivalent, under its own message
    # name (`:agent_activity_tick_guest`, handled below) so it can never
    # collide with the hook-owned `:agent_activity_tick` loop that
    # `MeetingHooks.attach/2` would install on a socket that also happened
    # to call `attach_guest/1` — which does not currently happen, but
    # sharing one atom across two independent schedulers is exactly the
    # kind of coincidence that becomes a double-speed clock later.
    if connected?(socket), do: schedule_agent_activity_tick_guest()

    assign(socket, :guest_topic_subs, %{
      space_id: meeting.chat_space_id,
      meeting_id: meeting.id
    })
  end

  # Idempotent room-topic subscription, and the ONLY writer of
  # `:subscribed_room_id`. Subscribing twice to one topic from one process is
  # a real duplicate (`keys: :duplicate` + `Registry.register/3`), and
  # `Phoenix.PubSub.unsubscribe/2` is `Registry.unregister/2`, which removes
  # ALL of a pid's registrations for the topic — so the two are asymmetric
  # and "just subscribe again" is never safe.
  #
  # Switching rooms releases the previous topic first: without that the pid
  # would keep receiving events from a room it left.
  #
  # `meeting_id` is a THIRD, explicit argument (every call site now
  # passes it) rather than read off `socket.assigns[:meeting]` — the
  # mount call site (the one that matters most, since it is where a
  # viewer joining an already-live meeting first needs to see who
  # already holds what) calls this BEFORE `:meeting` lands in assigns,
  # so reading the assign here would silently skip seeding on the one
  # call site where seeding matters most.
  defp subscribe_room_once(socket, room_id, meeting_id) when is_binary(room_id) do
    case socket.assigns[:subscribed_room_id] do
      ^room_id ->
        socket

      previous ->
        if is_binary(previous), do: MeetingsPubSub.unsubscribe_room(previous)
        MeetingsPubSub.subscribe_room(room_id)

        socket
        |> assign(:subscribed_room_id, room_id)
        |> seed_ask_floor_holders(
          meeting_id || (socket.assigns[:meeting] && socket.assigns.meeting.id)
        )
    end
  end

  # `:ask_floor_holders` is otherwise only ever UPDATED incrementally by
  # the `:ask_floor_taken` / `:ask_floor_released` room-topic clauses
  # above, which only fire for presses/releases that happen AFTER this
  # pid subscribes. A viewer joining mid-meeting — or reconnecting after
  # a room switch — would see every already-held agent as free until the
  # NEXT press anywhere, which is exactly the stale-owner gap this stage
  # exists to close. Re-derived in full from `AskFloor.list_meeting/1`
  # each time this pid (re)subscribes, rather than trusted to have
  # tracked every event correctly.
  defp seed_ask_floor_holders(socket, meeting_id) when is_binary(meeting_id) do
    holders =
      meeting_id
      |> AskFloor.list_meeting()
      |> Map.new(&{&1.agent_id, &1.display_name})

    assign(socket, :ask_floor_holders, holders)
  end

  defp seed_ask_floor_holders(socket, _meeting_id), do: socket

  # Ensure a live meeting room + guest participant row exist so both the
  # guest's OWN LV (which subscribed above) and any authenticated
  # MeetingLive subscribed to the same space refresh `@participants` and
  # render a tile for this guest. Idempotent by construction: `ensure_room`
  # returns the existing row; `upsert_live_participant` find-or-inserts
  # by (room_id, display_name) when the identity is nil-FK (guests).
  #
  # Only runs on connected? mounts — the initial dead render doesn't need
  # to broadcast, and we don't want a stale row from a mount that never
  # fully connects. Best-effort: a failure here (LiveKit misconfig,
  # meetings disabled, etc.) is logged and swallowed. The guest surface
  # still renders and joins LiveKit; the auth surface just won't get the
  # server-broadcast presence signal (LiveKit's webhook is the prod
  # fallback that still fires).
  defp maybe_upsert_guest_presence(socket, meeting, bundle, display_name) do
    with true <- connected?(socket),
         space_id when is_binary(space_id) <- meeting.chat_space_id,
         {:ok, room} <- Meetings.ensure_room(space_id),
         {:ok, room} <- Meetings.activate_room(room),
         {:ok, _participant} <-
           Meetings.upsert_live_participant(room, %{
             identity: bundle.identity,
             name: "#{display_name} (guest)"
           }) do
      :ok
    else
      _ -> :ok
    end
  end

  defp refresh_participants(%{assigns: %{meeting: %{chat_space_id: space_id}}} = socket)
       when is_binary(space_id) do
    participants = build_meeting_participants(space_id)

    socket
    |> assign(:participants, participants)
    |> assign(:room_live?, room_live?(space_id))
    |> assign(:room_recording?, room_recording?(space_id))
    |> assign(:agents_by_id, load_agents_by_id(participants))
    |> assign_invite_rows(space_id, participants)
  end

  defp refresh_participants(socket), do: socket

  # The three invite assigns move together (task 01a0691d): `:invite_rows` is
  # the model, `:invitable_agents` its clickable projection, and
  # `:pending_invite_agent_ids` the presentational set the rail already reads.
  # Deriving the projection from the rows is one roster read per refresh
  # instead of one per assign, and it is what keeps the button list and the
  # row list from ever disagreeing about the same agent.
  defp assign_invite_rows(socket, space_id, participants) do
    rows = invite_rows(space_id, participants)

    socket
    |> assign(:invite_rows, rows)
    |> assign(:invitable_agents, invitable_agents_from_rows(rows))
    |> assign(:pending_invite_agent_ids, pending_invite_agent_ids(participants))
  end

  # Whether this meeting's space has a LIVE room right now (task 01a05b14
  # stage 5). Drives the top bar's `meeting live` pill, which follows the
  # invite banner's rule: OBSERVED, not inferred. `Meetings.get_active_room/1`
  # answers from the `meeting_rooms.status` column, which only the join
  # path (`activate_room/1`, on a participant actually entering) and the
  # LiveKit `room_finished` webhook (`finish_room/1`) write — and both of
  # those broadcast `{:meeting_presence_update, _}` on the space topic, the
  # clause that re-runs `refresh_participants/1`. So the pill flips on the
  # same tick the roster does and reads a row that the media plane, not
  # this LiveView, decided. A scheduled meeting with no room renders NO
  # pill rather than a green one that lies.
  defp room_live?(space_id) when is_binary(space_id) do
    match?(%Room{}, Meetings.get_active_room(space_id))
  end

  defp room_live?(_space_id), do: false

  # Whether this meeting's space is being CAPTURED right now (task 01a0740d
  # stage 2). Drives the top bar's red `recording` pill, and it is observed
  # on exactly the terms `room_live?/1` above is: it answers from a row, and
  # the row is `meeting_recordings` at `status == "recording"` — the only
  # status that means capture is happening (`Meetings.live_recording_for_room/1`,
  # stage 1, where `processing` / `ready` / `failed` all answer nil because a
  # row that outlives the capture would keep telling people they are being
  # recorded after they have stopped being recorded).
  #
  # Recomputed rather than carried from the `{:recording_updated, recording}`
  # broadcast payload. The payload says which recording changed; it does not
  # say whether the ROOM still has a live one, and those differ the moment a
  # room holds more than one row. The broadcast is the wake-up, the read is
  # the answer.
  #
  # KNOWN INTERACTION, reported in stage 1 and unchanged here: `start_recording/2`
  # sets `meeting_rooms.status` to `"recording"`, and `get_active_room/1` matches
  # `"active"` only. So on the real write path this read finds no active room and
  # answers false — and the green live pill above disappears on the same tick,
  # for the same reason. That is backend lifecycle, outside this ticket, and it
  # is why nothing in production lights this pill today.
  defp room_recording?(space_id) when is_binary(space_id) do
    case Meetings.get_active_room(space_id) do
      %Room{id: room_id} -> Meetings.live_recording_for_room(room_id) != nil
      _ -> false
    end
  end

  defp room_recording?(_space_id), do: false

  # ── Agent invitation (task 01a04c2f) ───────────────────────────────────
  #
  # The agents this control may offer, sourced from the meeting space's OWN
  # roster (`Chat.list_space_agents/1`) minus the agents already in the call.
  #
  # The roster, not `Chat.list_agents_for_picker/0`: the picker lists every
  # active agent in the deployment, and an invite writes a participant row in
  # this space and dispatches a join token to that agent's runtime. Offering
  # only agents already trusted with the space keeps the handler's id
  # resolution (below) a lookup in a server-built list rather than a lookup in
  # the whole `agents` table, which is what makes a forged `agent-id` a miss
  # instead of a cross-space reach.
  #
  # Excluding the in-call agents is not cosmetic: an agent already in the
  # room does not need inviting, and offering it invites a pointless
  # re-dispatch at a worker that is already connected.
  #
  # ## The exclusion is on ARRIVAL, not on the participant row (01a04e0f)
  #
  # It used to be on the row: any agent with a `meeting_participants` row was
  # dropped from this list. `Meetings.invite_agent/3` writes that row BEFORE
  # it broadcasts `meeting_join`, and `Phoenix.Endpoint.broadcast/3` returns
  # `:ok` whether or not anybody is subscribed. So an invite sent to an agent
  # whose runtime is registered but whose voice worker has not connected
  # reached nobody, logged "dispatched", left a row — and the row removed the
  # only control that could have fired the invite again. The founder hit this
  # on the first real use and had to abandon the meeting.
  #
  # `invite_agent/3` already refuses an agent with NO runtime for exactly
  # this reason (task 01a04f31, quoting itself: a row for it "would remove
  # the control that is the only way to try again"). "Runtime resolved,
  # nobody listening" is the same hazard one step further out, and unlike the
  # first it cannot be pre-flighted — a broadcast into an empty topic is
  # indistinguishable from a delivered one. The fix is therefore not a
  # sharper pre-flight; it is to stop treating a dispatch-time row as proof
  # of arrival.
  #
  # `metadata["identity"]` is that proof, and it is not a proxy for it:
  # `Meetings.upsert_live_participant/2` — the LiveKit webhook path, the only
  # writer of real presence — stamps the joiner's LiveKit identity there, and
  # backfills it onto a row that already exists. `invite_agent/3` writes no
  # metadata at all. An `"agent:…"` identity therefore means a worker
  # published itself into the room; its absence means only that a human
  # clicked Invite.
  #
  # This is not "show everyone always": an agent that has arrived is still
  # excluded, which is what `agent_in_call?/2` below decides.
  #
  # Nor is it "every agent in the space" any more (task 01a0554f). It was, and
  # that is why a text-only agent was offered a seat in a call it could never
  # take: the founder clicked it through five test meetings. An agent whose
  # runtime DECLARED its features and did not name `meeting_voice` is dropped
  # here — the control could only ever have failed.
  #
  # `:incapable` specifically, NOT `!= :capable`. An agent that has never
  # declared anything is `:unknown` and stays in the list; see
  # `Meetings.join_capability/1` for why that distinction is kept rather than
  # collapsed. Silently hiding a client core has never heard from would
  # reproduce this task's defect one layer over.
  #
  # ## The row model this list is a projection of (task 01a0691d)
  #
  # `invitable_agents/2` answers only "who gets a button". The People tab has
  # to say more than that: the design canvas
  # (01a064fc-5c89-7001-9ea1-491f076b6746, "Where this lives now") keeps every
  # roster agent LISTED and replaces the button with the reason it cannot be
  # pressed — an agent that silently vanishes from the list is a second
  # mystery on top of the first, and the founder went looking for one five
  # times. So `invite_rows/2` is the model both surfaces render from, and
  # `invitable_agents/2` is derived from it rather than being a second
  # predicate that could drift from the first.
  #
  # Per agent, first match wins:
  #
  #   * `:in_call`   — a participant row proves arrival (`agent_in_call?/2`).
  #   * `:incapable` — its runtime declared features without voice
  #                    (`Meetings.join_capability/1`); the control could only
  #                    ever have failed.
  #   * `:pending`   — a roster row from an invite nobody has answered yet
  #                    (`pending_invite_agent_ids/1`); still clickable, which
  #                    is what makes an undelivered invite recoverable.
  #   * `:invitable` — everything else, INCLUDING `capability: :unknown`.
  #                    01a0554f's ruling, kept: a client core has never heard
  #                    from is offered, not hidden.
  #
  # `:capability` is carried on every row, not only the blocked ones, so the
  # template can decide what the second line says without re-running the
  # predicate.
  #
  # ## The list is the ACTIVE AGENT ROSTER, not the space (task 01a05553)
  #
  # It was the space, and that is the whole reason inviting an agent to a
  # meeting took six screens. Every meeting mints a FRESH chat space, so
  # `Chat.list_space_agents/1` on it answers `[]` on the first render of every
  # meeting that has ever been created. The rail could therefore only ever
  # offer an agent that somebody had already put in that space by hand — which
  # meant leaving the call, finding the space, adding the agent, coming back.
  # The founder walked that path live and gave up. A control whose list is
  # empty by construction is not a control.
  #
  # So the source is `Chat.list_agents_for_picker/0` — `status == "active"`,
  # ordered by name, the same roster the conversation picker offers — and
  # membership of THIS meeting's space becomes a fact carried ON the row
  # (`:in_space?`) rather than the filter that decides whether the row exists.
  # That is the smallest change that makes the list non-empty without
  # inventing a new notion of who may be invited: "active agent" is a status
  # the product already maintains and already exposes elsewhere.
  #
  # The space roster is still read, for two reasons, and they are not the same
  # reason:
  #
  #   1. It answers `:in_space?`.
  #   2. It is UNIONED IN, so widening this list can never narrow it. An agent
  #      whose status is no longer `"active"` but which is in the space — or
  #      standing in the call right now — keeps its row and its `:in_call`
  #      state. Without the union, "source from the roster instead" would
  #      quietly delete a participant from the People tab mid-call, which is
  #      the same class of vanishing-row defect as 01a0554f.
  #
  # Removing an agent from the space therefore no longer removes its row; it
  # flips `:in_space?`. Deactivating an agent is what removes it.
  #
  # ORDER: invitable, pending, incapable, in_call — the canvas's "one ordered
  # list, invitable first, then blocked". Within a state, space members come
  # first in their roster order (`Chat.list_space_agents/1`, ascending
  # `joined_at`) and then the rest of the active roster by name:
  # `Enum.sort_by/2` is stable, so the concatenation order below survives it.
  @invite_state_order %{invitable: 0, pending: 1, incapable: 2, in_call: 3}

  @doc false
  def invite_rows(space_id, participants) when is_binary(space_id) do
    pending_ids = pending_invite_agent_ids(participants)
    {agents, member_ids} = invitable_roster(space_id)

    agents
    |> Enum.map(&agent_invite_row(&1, participants, pending_ids, member_ids))
    |> Enum.sort_by(&Map.fetch!(@invite_state_order, &1.state))
  end

  def invite_rows(_space_id, _participants), do: []

  # Every agent the rail should LIST, plus the ids of the ones that hold a
  # roster row on this meeting's space. Members first (see the ORDER note
  # above), then every other active agent, each exactly once.
  defp invitable_roster(space_id) do
    members =
      space_id
      |> Chat.list_space_agents()
      |> Enum.flat_map(fn
        %{agent: %Agent{} = agent} -> [agent]
        _ -> []
      end)

    member_ids = MapSet.new(members, & &1.id)

    outsiders =
      Chat.list_agents_for_picker()
      |> Enum.reject(&MapSet.member?(member_ids, &1.id))

    {members ++ outsiders, member_ids}
  end

  # `agent_invite_row`, not `invite_row`: the calendar detail surface above
  # already owns `invite_row/3` for its human-invite rows.
  #
  # `:in_space?` is a fact about the agent, deliberately NOT folded into
  # `:state`. The four states answer "can this be clicked, and if not why" —
  # membership answers neither. An agent that is not in the space is fully
  # invitable (that is this task's whole point), so making it a fifth state
  # would have taken the button away again.
  defp agent_invite_row(%Agent{} = agent, participants, pending_ids, member_ids) do
    capability = Meetings.join_capability(agent)

    state =
      cond do
        agent_in_call?(agent, participants) -> :in_call
        capability == :incapable -> :incapable
        MapSet.member?(pending_ids, agent.id) -> :pending
        true -> :invitable
      end

    %{
      agent: agent,
      state: state,
      capability: capability,
      in_space?: MapSet.member?(member_ids, agent.id)
    }
  end

  # Public so the exclusion can be exercised against hand-built participant
  # lists, for the same reason `build_meeting_participants/1` is. Since task
  # 01a0691d this is `invite_rows/2` filtered to the CLICKABLE states; the
  # exclusions documented above are now decided there.
  @doc false
  def invitable_agents(space_id, participants) do
    space_id
    |> invite_rows(participants)
    |> invitable_agents_from_rows()
  end

  # Public for `MeetingHooks.assign_roster/2`, which builds the same three
  # assigns for the quickmeet from one roster read (task 01a0691d stage 2).
  @doc false
  def invitable_agents_from_rows(rows) do
    rows
    |> Enum.filter(&(&1.state in [:invitable, :pending]))
    |> Enum.map(& &1.agent)
  end

  # True when some participant row proves THIS agent published into the room.
  #
  # Matched on the identity STRING as well as on the `agent_id` FK because
  # the two come apart in practice: `dispatch_meeting_join/3` hands the
  # worker `agent_identity: "agent:<slug>"`, `Meetings.parse_identity/1`
  # casts an identity suffix as a UUID and so answers `:unknown` for a slug,
  # and `upsert_live_participant/2` then falls back to matching by display
  # name. A worker that publishes under a name that does not match the
  # invite's `display_name` gets its own row carrying the identity and NO
  # agent FK — still proof of arrival, and invisible to an FK-only test.
  defp agent_in_call?(%Agent{} = agent, participants) do
    Enum.any?(participants, fn participant ->
      case Map.get(participant, :identity) do
        "agent:" <> suffix when suffix != "" ->
          suffix == agent.id or suffix == agent.slug or
            (Map.get(participant, :participant_type) == "agent" and
               Map.get(participant, :participant_id) == agent.id)

        _ ->
          false
      end
    end)
  end

  # The agents holding a roster row from an earlier invite that has never
  # been answered. Purely presentational: the control is offered either way,
  # but a dispatch nobody received and one that worked are otherwise
  # indistinguishable on this screen, and that is half of what made the
  # original defect unrecoverable — the founder had no way to tell.
  @doc false
  def pending_invite_agent_ids(participants) do
    for %{participant_type: "agent", participant_id: id} = participant <- participants,
        is_binary(id),
        not Meetings.agent_identity?(Map.get(participant, :identity)),
        into: MapSet.new(),
        do: id
  end

  @doc false
  def invite_pending?(pending_ids, agent_id) do
    is_struct(pending_ids, MapSet) and MapSet.member?(pending_ids, agent_id)
  end

  # The `"meeting_invite_agent"` body lives in
  # `MeetingHooks.invite_agent_into_call/3` since task 01a0691d, so this page
  # and the quickmeet panel run ONE `with` chain and flash ONE set of
  # messages (its comment explains why every failure is a flash and not a
  # raise). What stays here is the part only this LiveView can do: refresh
  # the roster it renders, which reads `:meeting` off THIS socket.
  defp invite_agent_into_call(socket, agent_id) do
    space_id =
      case socket.assigns[:meeting] do
        %Meeting{chat_space_id: space_id} -> space_id
        _ -> nil
      end

    socket
    |> MeetingHooks.invite_agent_into_call(space_id, agent_id)
    |> refresh_participants()
  end

  # True only when the deleted row is THIS viewer's participant row on THIS
  # meeting's chat space. Pattern-matched on `%Chat.Participant{}` rather than
  # a loose map so the meetings ROOM topic's `{:participant_left,
  # %Meetings.LiveParticipant{}}` — a different struct with no `:space_id`,
  # broadcast on `meeting_room:<id>` — falls through to `false` instead of
  # raising or, worse, matching on a field that happens to be named alike.
  defp viewer_lost_meeting_space?(socket, %Chat.Participant{
         participant_type: "user",
         participant_id: participant_id,
         space_id: space_id
       }) do
    meeting_space_id =
      case socket.assigns[:meeting] do
        %{chat_space_id: id} -> id
        _ -> nil
      end

    is_binary(meeting_space_id) and participant_id == socket.assigns[:user_id] and
      space_id == meeting_space_id
  end

  defp viewer_lost_meeting_space?(_socket, _participant), do: false

  @doc """
  Build the participant view-model for the rail + gallery from LIVE meeting
  presence (`Meetings.active_participants_for_space/1`) rather than durable
  chat-space membership.

  This is the root-cause fix for the "Participant List not reflective" bug:
  the rail used to read `Chat.list_participants/1` (durable membership, whose
  `display_name` is frequently nil and renders as the literal "User", and
  whose count is membership not presence). `Meetings.Participant` rows are
  fed by the LiveKit webhook (`participant_joined`/`participant_left`),
  `left_at`-filtered, and preload `:user`/`:agent` — so this returns who is
  actually in the room with their resolved identity.

  Returns a list of maps shaped exactly like the `Chat.Participant`-derived
  view-model the rail/gallery already pattern-match on: `:id`,
  `:participant_id`, `:participant_type`, `:display_name`, `:avatar_url`,
  `:attention_config`.
  """
  def build_meeting_participants(space_id) when is_binary(space_id) do
    space_id
    |> Meetings.active_participants_for_space()
    |> Enum.map(&meeting_participant_view_model/1)
  end

  def build_meeting_participants(_), do: []

  # Map a single live `Meetings.Participant` row into the rail/gallery
  # view-model. `:participant_id` is the preloaded `user.id` / `agent.id`
  # (NOT the meeting_participants row id) so `gallery_identity/1` produces
  # the same `"user:<user_id>"` LiveKit identity MeetingHooks joins with.
  # Public for the same reason `resolve_identity/1` below is: the rail reads
  # `avatar_url` off THIS map, so the wrapping is worth asserting directly and
  # not only through a mounted LiveView.
  def meeting_participant_view_model(%Meetings.Participant{} = p) do
    {participant_type, participant_id} =
      cond do
        is_binary(p.agent_id) -> {"agent", p.agent_id}
        is_binary(p.user_id) -> {"user", p.user_id}
        true -> {"user", nil}
      end

    {display_name, avatar_url} = resolve_identity(p)

    # 019f498d re-dispatch: surface the LiveKit identity stored on the
    # participant row (populated by `Meetings.upsert_live_participant/2`)
    # so `gallery_identity/1` can produce a `data-participant` attribute
    # matching the LiveKit-published identity. Auth-user rows will be
    # `"user:<uuid>"` (same string the previous `"user:" <> participant_id`
    # fallback yielded); guest rows will be `"guest:<random>"` which the
    # previous fallback would have mangled into `"user:<row-id>"`.
    identity = Map.get(p.metadata || %{}, "identity")

    %{
      id: p.id,
      participant_id: participant_id,
      participant_type: participant_type,
      display_name: display_name,
      avatar_url: avatar_url,
      identity: identity,
      # Live presence rows carry NO mic state, and nothing has ever
      # written `"mic_on"` here. Per-identity mic and camera state now
      # arrives from LiveKit on `:muted_identities` /
      # `:camera_off_identities` (task 01a0740c), and `mic_on?/1` — the
      # placeholder read that made the rail claim everyone was muted
      # forever — is deleted. The key stays because `agent_role/1` still
      # reads `attention_config["role"]` and wants the map total.
      attention_config: %{}
    }
  end

  # Resolve `{display_name, avatar_url}` for a live meeting participant,
  # preferring the strongest identity signal available.
  #
  #   * Agent rows: the preloaded agent name (then the join name).
  #   * User rows WITH a loaded user: user.name, then the join name, then
  #     user.email.
  #   * Rows with NO loaded user and NO loaded agent (orphaned presence —
  #     e.g. the backing account was deleted, which `on_delete: :nilify_all`
  #     turns into a `user_id: nil` row): we deliberately return `nil` so
  #     the render layer labels them "Unknown participant". An orphaned
  #     identity is honestly unknown — not a generic "User" (the symptom
  #     this task fixes), and we do NOT trust the stale join-time
  #     `display_name` as if it were a live identity.
  def resolve_identity(%Meetings.Participant{agent: %Agent{} = agent} = p) do
    name =
      first_present([
        agent.name,
        nilify(p.display_name)
      ])

    # The avatar comes off the preloaded `%Agent{}` (`active_participants/1`
    # preloads `[:user, :agent]`), NOT off the participant row — `meetings.participants`
    # has no `avatar_url` column and deliberately gains none, for the same
    # reason `chat_participants` is not backfilled: an avatar is one mutable
    # fact about the agent, and denormalising it onto every presence row would
    # mean rewriting them all whenever it changes. `nilify/1` keeps a blank
    # column from reaching the render layer as an empty string. The stored URL
    # carries a `?v=` cache token and is passed through verbatim.
    {name, nilify(agent.avatar_url)}
  end

  def resolve_identity(%Meetings.Participant{user: %{} = user} = p) do
    name =
      first_present([
        Map.get(user, :name),
        nilify(p.display_name),
        Map.get(user, :email)
      ])

    {name, Map.get(user, :avatar_url)}
  end

  # Guest-shape presence row: no user_id, no agent_id, `display_name` was
  # populated by the guest-join gate with a trailing " (guest)" suffix
  # (e.g. "Ada (guest)"). The catch-all below would nil this out — which
  # leaked "Unknown participant" onto the rail AND starved `via_guest_link?/1`
  # (line ~1330) of the suffix it needs to render the "via guest link"
  # sub-line. Requiring the suffix here keeps the "we don't trust stale join
  # names for orphaned real users" invariant (see the ghost-user test in
  # meeting_live_test.exs) — orphaned rows never carry the " (guest)" marker.
  def resolve_identity(
        %Meetings.Participant{user_id: nil, agent_id: nil, display_name: name} = _p
      )
      when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {nil, nil}
      String.ends_with?(trimmed, " (guest)") -> {trimmed, nil}
      true -> {nil, nil}
    end
  end

  # Orphaned presence row: neither user nor agent resolved. Honestly unknown.
  def resolve_identity(%Meetings.Participant{}) do
    {nil, nil}
  end

  defp first_present(candidates) do
    Enum.find_value(candidates, fn
      v when is_binary(v) ->
        case String.trim(v) do
          "" -> nil
          _ -> v
        end

      _ ->
        nil
    end)
  end

  defp nilify(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      _ -> v
    end
  end

  defp nilify(_), do: nil

  @doc """
  Build a `%{agent_id => %Agent{}}` map for any agent-typed participants.

  Empty when no agents are seated. Drives the rail's role chip + status
  dot. PUBLIC as of task 01a05b14 stage 6: the in-chat quickmeet mounts
  the same `CallShell.call_rail/1` and therefore needs the same map. A
  second copy in `ChatLive.MeetingHooks` would be a second query shape
  to keep in step with `ParticipantRail`'s expectations — which is the
  exact two-surface drift this task exists to end.
  """
  @spec load_agents_by_id([map()]) :: %{binary() => Agent.t()}
  def load_agents_by_id(participants) when is_list(participants) do
    agent_ids =
      participants
      |> Enum.flat_map(fn
        %{participant_type: "agent", participant_id: id} when is_binary(id) -> [id]
        _ -> []
      end)
      |> Enum.uniq()

    case agent_ids do
      [] ->
        %{}

      ids ->
        import Ecto.Query

        from(a in Agent, where: a.id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
    end
  end

  def load_agents_by_id(_), do: %{}

  @doc """
  Per-meeting PubSub topic.

  INTEGRATION POINT: sibling task 019e2474-11c1 is expected to own the
  authoritative meeting PubSub helper (mirroring
  `Platform.Meetings.PubSub` for rooms). When it lands, swap this for the
  shared helper. Kept local here so this branch is independently runnable.
  """
  def meeting_topic(meeting_id), do: "meeting:#{meeting_id}"

  # ── Intents-collapse helpers (task 019f70b8 stage 7) ─────────────────────

  @doc """
  Resolve the `meeting_producer` role gate into `:intents_visible?`.

  Computed ONCE per mount (and again on a role-change broadcast) into an
  assign, never called from the template: a template call would run this
  query on every diff of every meeting render.

  The role key is passed as a STRING — `Platform.Roles.agent_id_for_role/1`
  is guarded `when is_binary(role_key)` and an atom raises
  FunctionClauseError, which in a LiveView mount is a blank meeting.
  """
  def assign_intents_gate(socket) do
    visible? = not is_nil(Roles.agent_id_for_role(@intent_producer_role))

    socket
    |> assign(:intents_visible?, visible?)
    |> assign(:intent_agent_options, if(visible?, do: intent_agent_options(), else: []))
  end

  # Agents offered as a re-target in the correction modal. Every active
  # agent, not only the ones already in this meeting: "you sent it to the
  # wrong agent" is usually about an agent who ISN'T here.
  defp intent_agent_options do
    Chat.list_agents_for_picker()
    |> Enum.map(&{&1.name || &1.slug, &1.id})
  end

  # Run `fun` only when the viewer holds the producer role. A hidden bar
  # is a rendering decision; this is the authorization.
  # The LiveKit participant identity for whoever owns this socket, or nil
  # for a session with no user (a guest joins with a `guest:` identity
  # minted elsewhere and does not get push-to-talk in this stage).
  #
  # Read from `:current_user_record`, NOT `:current_user`. On the member
  # mount `PlatformWeb.ShellLive.on_mount/4` assigns `:current_user` as
  # the display STRING (name or email) and keeps the `%User{}` under
  # `:current_user_record`; matching `%{id: id}` on the string never
  # succeeded, so no authenticated press ever reached `PressCard.open/3`
  # (task 01a06638 stage 5 — measured: zero press-card rows in either
  # production install since PR #910). A guest session runs neither
  # assign and still answers nil here.
  defp press_identity(socket) do
    case socket.assigns[:current_user_record] do
      %{id: id} when is_binary(id) -> "user:#{id}"
      _ -> nil
    end
  end

  # The agent a per-agent hold-to-talk press names, or nil for a press
  # carrying no agent (an untargeted press, which takes the configured
  # default downstream).
  defp pressed_agent_id_param(%{"agent_id" => id}) when is_binary(id) and id != "", do: id
  defp pressed_agent_id_param(_params), do: nil

  # Attempt to claim `agent_id`'s floor for a per-agent press (task
  # 01a0cf5c stage 1). An UNTARGETED press (`agent_id` nil — no
  # `data-agent-id` on the control that fired it) has no floor to
  # claim: `PressCard.open/3`'s own default-target resolution stands,
  # exactly as it did before per-agent hold-to-talk existed.
  #
  # On a successful (or idempotent-repeat) claim this ALSO broadcasts
  # `:ask_floor_taken` on the meeting's room topic — every OTHER
  # connected client needs to know before anything is said, per the
  # design canvas (01a0cf5e-9cb0). The stuck-claim timeout's own
  # `:ask_floor_released` broadcast lives inside `AskFloor` itself (it
  # fires with no LiveView process involved), but this one is ordinary
  # request/response and belongs with every other room-topic publish
  # this module already owns.
  defp claim_ask_floor(_socket, _meeting_id, nil, _identity), do: :untargeted

  defp claim_ask_floor(socket, meeting_id, agent_id, identity) do
    room_id = socket.assigns[:subscribed_room_id]

    case AskFloor.claim(meeting_id, agent_id, identity, socket.assigns[:display_name], room_id) do
      {:ok, holder} = ok ->
        if is_binary(room_id) do
          MeetingsPubSub.broadcast_room(
            room_id,
            {:ask_floor_taken, %{agent_id: agent_id, display_name: holder.display_name}}
          )
        end

        ok

      error ->
        error
    end
  end

  # The other half of `claim_ask_floor/4`: release `agent_id`'s floor
  # and broadcast `:ask_floor_released` so every other client's button
  # un-freezes immediately, not on the next re-render. A release for a
  # `nil` agent_id (an untargeted press never claimed a floor to begin
  # with) is a no-op, and a release this socket does not actually hold
  # (`AskFloor.release/3` checks identity) is left alone rather than
  # broadcast — nothing changed, so nothing to tell anyone.
  defp release_ask_floor(_socket, _meeting_id, nil, _identity), do: :ok

  defp release_ask_floor(socket, meeting_id, agent_id, identity) do
    case AskFloor.release(meeting_id, agent_id, identity) do
      :ok ->
        case socket.assigns[:subscribed_room_id] do
          room_id when is_binary(room_id) ->
            MeetingsPubSub.broadcast_room(room_id, {:ask_floor_released, %{agent_id: agent_id}})

          _ ->
            :ok
        end

      _not_held_or_missing ->
        :ok
    end
  end

  # ── Live transcript feed + release outcome for the ask-floor veil ────────
  # (task 01a0cf5c stage 3)
  #
  # Wires the veil's transcript slot onto the segment stream that
  # already exists for exactly this purpose
  # (`Platform.Meetings.IntentClassifier` subscribes to the same
  # broadcast for the same reason: `PressWindow.claim/3` is only true
  # about a window at the instant a segment ARRIVES, not seconds later
  # once a debounce or a model call has run). This module does not
  # build a second transcription path — it reads the one the classifier
  # already reads, and decides nothing the classifier does not already
  # decide the same way for its own purpose.
  #
  # ## The PER-ROOM topic, never the canonical one
  #
  # `Platform.Meetings.PubSub.subscribe_transcript_chunk/0` (no
  # argument) is the GLOBAL, cross-org topic every appended segment in
  # the whole install broadcasts on — `IntentClassifier` may hold it
  # because it is a supervised singleton no human sits behind, and
  # `test/platform/regression/pubsub_topic_inventory_audit_test.exs`
  # asserts, by name, that nothing else does: a per-USER process (this
  # LiveView) subscribing to it would mean any viewer holding a press
  # anywhere receives every OTHER meeting's speech, across orgs, for as
  # long as the button is held. That is the leak this module must not
  # reopen.
  #
  # `subscribe_transcript_chunk/1` (per room) is the correct, scoped
  # subscription — but the id it is keyed on is `Transcript.room_id`,
  # the LIVEKIT room NAME (`MeetingAgentController`'s
  # `params["room_name"] || room_sid`), which is NOT
  # `Platform.Meetings.Room.id` (the UUID this LiveView tracks as
  # `:subscribed_room_id` for the ask-floor broadcasts above — a
  # different id space entirely). `Platform.Meetings.room_name_for_space/1`
  # is the one function that derives the LiveKit room name from
  # `meeting.chat_space_id` (`"space-<chat_space_id>"`, the same string
  # every room this meeting could ever open is named with — federation's
  # tool surface and `MeetingHooks` both derive it the same way), so
  # that — not `:subscribed_room_id` — is what this subscribes with.
  defp start_ask_transcript_tracking(socket, meeting_id, identity, agent_id, intent) do
    candidate_id =
      case Candidates.get_by_intent_id(intent.id) do
        %{id: id} -> id
        _ -> nil
      end

    room_name = Meetings.room_name_for_space(socket.assigns.meeting.chat_space_id)

    socket =
      if socket.assigns[:ask_transcript_room_name] do
        socket
      else
        :ok = MeetingsPubSub.subscribe_transcript_chunk(room_name)
        socket
      end

    socket
    |> assign(:ask_transcript_room_name, room_name)
    |> assign(:ask_transcript_identity, identity)
    |> assign(:ask_transcript_meeting_id, meeting_id)
    |> assign(:ask_transcript_agent_id, agent_id)
    |> assign(:ask_transcript_candidate_id, candidate_id)
    |> assign(:ask_transcript_claimed?, false)
    |> assign(:ask_transcript_released?, false)
  end

  defp stop_ask_transcript_tracking(socket) do
    case socket.assigns[:ask_transcript_room_name] do
      room_name when is_binary(room_name) ->
        MeetingsPubSub.unsubscribe_transcript_chunk(room_name)

      _ ->
        :ok
    end

    socket
    |> assign(:ask_transcript_room_name, nil)
    |> assign(:ask_transcript_identity, nil)
    |> assign(:ask_transcript_meeting_id, nil)
    |> assign(:ask_transcript_agent_id, nil)
    |> assign(:ask_transcript_candidate_id, nil)
    |> assign(:ask_transcript_claimed?, false)
    |> assign(:ask_transcript_released?, false)
  end

  # A segment claimed by THIS socket's own press window. Marks the
  # press as having claimed at least one segment (what
  # `resolve_ask_outcome_on_release/1` reads to decide the fly
  # transition immediately versus waiting), and — for a FINAL segment
  # only — pushes the text into the veil's transcript slot. Interim
  # (non-final) segments still count as a claim, matching
  # `PressWindow`'s own counter exactly (the classifier does not filter
  # them either), but are not displayed: the transcriber revises interim
  # text as it finalises, and echoing every revision would make the
  # card visibly rewrite itself mid-sentence.
  defp claim_ask_transcript_segment(socket, segment) do
    socket = assign(socket, :ask_transcript_claimed?, true)

    socket =
      if Map.get(segment, "final") == true do
        text = segment_text(segment)

        if text != "" do
          push_event(socket, "meeting_ask_transcript_chunk", %{
            "agent_id" => socket.assigns[:ask_transcript_agent_id],
            "text" => text
          })
        else
          socket
        end
      else
        socket
      end

    # A late claim landing AFTER the button was already released (still
    # inside `PressWindow.release_grace_ms/0`) is exactly the case
    # `resolve_ask_outcome_on_release/1` left pending rather than
    # guessing about. Now it is known: at least one segment was claimed,
    # so the outcome is "fly" — resolve it the instant that becomes
    # true rather than waiting for the grace timer to expire and prove
    # a negative that is no longer true.
    if socket.assigns[:ask_transcript_released?] do
      push_ask_outcome(socket, "fly")
    else
      socket
    end
  end

  # Read at the moment the key comes up (task 01a0cf5c stage 3's release
  # outcome). Two cases:
  #
  #   * At least one segment already claimed — the outcome is known NOW
  #     ("fly"), so resolve it immediately rather than waiting on
  #     nothing.
  #   * Nothing claimed yet — this does NOT mean the press was empty. A
  #     trailing segment can still arrive and be claimed during
  #     `PressWindow.release_grace_ms/0` (the same grace that covers the
  #     transcriber's finalisation lag), and `PressWindow` itself will
  #     not decide "empty" until that grace elapses. So this branch
  #     marks the press released and otherwise does nothing — the
  #     outcome resolves later, either from a late claim above (fly) or
  #     from the server's own empty-press close, in
  #     `resolve_ask_outcome_on_candidate_closed/2` below (crumble).
  defp resolve_ask_outcome_on_release(socket) do
    cond do
      is_nil(socket.assigns[:ask_transcript_identity]) ->
        socket

      socket.assigns[:ask_transcript_claimed?] ->
        push_ask_outcome(socket, "fly")

      true ->
        assign(socket, :ask_transcript_released?, true)
    end
  end

  # The crumble half. Fires off the SAME broadcast `PressCard.close_
  # silent/1` produces when `PressWindow`'s release-grace timer finds
  # nothing was claimed (`reason: :unclassified`) — the identical path
  # `Platform.Meetings.CandidateSweeper`'s backstop reaper takes for the
  # same condition, so either producer of "empty press" resolves the
  # veil the same way. Deliberately NOT derived from this socket's own
  # claimed-segment count: that count can race a trailing segment still
  # in flight, which is precisely the guess the stage's own spec forbids
  # ("rather than guessing client-side from segment counts that could
  # race").
  defp resolve_ask_outcome_on_candidate_closed(socket, %{
         candidate_id: candidate_id,
         kind: :closed,
         detail: detail
       }) do
    tracked_id = socket.assigns[:ask_transcript_candidate_id]

    if is_binary(tracked_id) and tracked_id == candidate_id and
         Map.get(detail, "reason") == "unclassified" do
      push_ask_outcome(socket, "crumble")
    else
      socket
    end
  end

  defp resolve_ask_outcome_on_candidate_closed(socket, _event), do: socket

  defp push_ask_outcome(socket, outcome) when outcome in ["fly", "crumble"] do
    socket =
      push_event(socket, "meeting_ask_outcome", %{
        "agent_id" => socket.assigns[:ask_transcript_agent_id],
        "candidate_id" => socket.assigns[:ask_transcript_candidate_id],
        "outcome" => outcome
      })

    stop_ask_transcript_tracking(socket)
  end

  # The segment's `participant_identity` and nothing else — same
  # accessor shape as `IntentClassifier`'s (segments arrive with
  # string keys from `MeetingAgentController.normalize_segment/1`).
  defp segment_participant_identity(segment) when is_map(segment) do
    Map.get(segment, "participant_identity") || Map.get(segment, :participant_identity)
  end

  defp segment_participant_identity(_segment), do: nil

  defp segment_text(segment) when is_map(segment) do
    Map.get(segment, "text") || Map.get(segment, :text) || ""
  end

  defp segment_text(_segment), do: ""

  defp apply_candidate_stop(socket, candidate) do
    result =
      Candidates.stop(
        candidate,
        participant_id(socket.assigns[:current_participant]),
        actor_name: socket.assigns[:display_name]
      )

    case result do
      {:ok, _stopped} ->
        socket
        |> assign(:candidate_error, nil)
        |> assign(:candidate_undo, undo_stash(candidate))
        |> assign_candidate_board(candidate.meeting_id)

      # The sweeper won the race. Said out loud rather than swallowed:
      # the deliverable now exists, and a stop button that silently did
      # nothing would leave the human believing they had prevented it.
      {:error, :already_fired} ->
        socket
        |> assign(:candidate_error, "Too late — this one already went ahead.")
        |> assign_candidate_board(candidate.meeting_id)

      {:error, _reason} ->
        assign(socket, :candidate_error, "Could not stop this one.")
    end
  end

  # WHERE THE CARD WAS, and until when.
  #
  # `do_stop/3` nulls `acts_at` as part of the UPDATE that wins the race
  # against the sweeper, so once the write has landed the card's sort
  # position no longer exists anywhere. The struct this function is
  # handed was read BEFORE that write, and its `acts_at` is the only
  # surviving copy of the deadline the rail sorted on — which is why the
  # stash is taken here and not from the row `stop/3` returns, and why
  # no column was added to preserve it.
  #
  # Stashed only for a stop that this click actually made. `stop/3` is
  # idempotent and answers `{:ok, _}` for an already-closed card, so a
  # double-click would otherwise replace a real stash with one whose
  # `acts_at` is nil — an undo row with no slot to sit in.
  defp undo_stash(%{id: id, acts_at: %DateTime{} = acts_at, state: state})
       when state != :closed do
    %{
      id: id,
      acts_at: acts_at,
      expires_at: DateTime.add(DateTime.utc_now(), Countdown.undo_seconds(), :second)
    }
  end

  defp undo_stash(_candidate), do: nil

  defp apply_candidate_undo_stop(socket, candidate) do
    result =
      Candidates.reopen(candidate, participant_id(socket.assigns[:current_participant]))

    # The stash is cleared on EVERY outcome. It is a ten-second offer
    # about one click; whether the offer was taken or refused, leaving
    # the row up would invite a second press against a card that has
    # already answered.
    socket = assign(socket, :candidate_undo, nil)

    case result do
      {:ok, _reopened} ->
        socket
        |> assign(:candidate_error, nil)
        |> assign_candidate_board(candidate.meeting_id)

      # The sweeper won the race after all, or somebody graduated the
      # card from another session. Same sentence `stop_candidate` uses,
      # because it is the same fact: the deliverable exists.
      {:error, :already_fired} ->
        socket
        |> assign(:candidate_error, "Too late — this one already went ahead.")
        |> assign_candidate_board(candidate.meeting_id)

      {:error, _reason} ->
        socket
        |> assign(:candidate_error, "Could not bring this one back.")
        |> assign_candidate_board(candidate.meeting_id)
    end
  end

  # Resolve a candidate id against THIS socket's meeting before touching
  # it. Same posture as `stop_candidate`: a click on a card belonging to
  # another meeting writes nothing and says nothing, because an error
  # message would only tell a prober that the id exists.
  defp with_own_candidate(socket, candidate_id, fun) do
    meeting_id = socket.assigns[:meeting] && socket.assigns.meeting.id

    case Candidates.get(candidate_id) do
      %{meeting_id: ^meeting_id} = candidate when is_binary(meeting_id) -> fun.(socket, candidate)
      _ -> socket
    end
  end

  defp apply_candidate_approve(socket, candidate) do
    case Candidates.graduate(candidate) do
      {:ok, _graduated} ->
        socket
        |> assign(:candidate_error, nil)
        |> assign_candidate_board(candidate.meeting_id)

      {:error, _reason} ->
        socket
        |> assign(:candidate_error, "Could not start this one.")
        |> assign_candidate_board(candidate.meeting_id)
    end
  end

  defp apply_candidate_decline(socket, candidate) do
    note = decline_note(socket.assigns[:display_name])

    case Candidates.close(candidate, {:dismissed, note}) do
      {:ok, _closed} ->
        socket
        |> assign(:candidate_error, nil)
        |> assign_candidate_board(candidate.meeting_id)

      {:error, _reason} ->
        assign(socket, :candidate_error, "Could not close this one.")
    end
  end

  defp decline_note(name) when is_binary(name), do: "Not now — " <> name
  defp decline_note(_name), do: "Not now — a participant"

  # ── Correction (task 01a0740e stage 2) ──────────────────────────────────

  # Open the panel, and give the card its countdown back on the way.
  #
  # The re-arm happens on OPEN rather than only on a completed
  # correction because the cost this ticket is removing is the cost of
  # LOOKING. A panel that re-armed only once you had chosen would still
  # charge you for reading the three choices, and the reader who decides
  # the card was right after all would have paid the most.
  #
  # `{:error, :not_armed}` is not reported. It means the card was closed
  # or disarmed between this participant's last paint and their click —
  # the board refresh below is what tells them that, by removing the
  # card, and a second sentence about a card that is no longer on screen
  # would be noise.
  defp open_candidate_correction(socket, candidate) do
    socket =
      case Candidates.rearm(candidate) do
        {:ok, _rearmed} -> assign(socket, :candidate_error, nil)
        {:error, :not_armed} -> socket
        {:error, _reason} -> assign(socket, :candidate_error, "Could not reopen the window.")
      end

    socket
    |> assign(:candidate_correcting_id, candidate.id)
    |> assign_candidate_board(candidate.meeting_id)
  end

  # One of the three choices.
  #
  # The result is CHECKED. On `{:error, _}` the panel stays open and the
  # message goes to `:candidate_error`, which the rail renders at
  # `[data-role="meeting-candidate-error"]`: a correction that silently
  # failed while the panel closed underneath it would leave the
  # participant believing they had taught the classifier something, and
  # a panel whose buttons write nothing passes every rendering test
  # there is.
  #
  # `:candidate_correcting_id` is cleared ONLY on the success branch,
  # and the error branch deliberately does not touch the countdown —
  # `correct/3` re-arms as part of a write that succeeded, so a refused
  # correction has moved nothing to draw.
  defp apply_candidate_correction(socket, candidate, kind, opts) do
    opts =
      opts
      |> Keyword.put(:actor_participant_id, participant_id(socket.assigns[:current_participant]))
      |> Keyword.put(:actor_name, socket.assigns[:display_name])

    case Candidates.correct(candidate, kind, opts) do
      {:ok, _corrected} ->
        socket
        |> assign(:candidate_error, nil)
        |> assign(:candidate_correcting_id, nil)
        |> assign_candidate_board(candidate.meeting_id)

      {:error, reason} ->
        socket
        |> assign(:candidate_error, correction_error(reason))
        |> assign_candidate_board(candidate.meeting_id)
    end
  end

  # Said out loud, never swallowed. Each sentence names what the reader
  # can do about it; `Could not record this correction.` is the fallback
  # for a changeset, which is a shape a participant cannot act on.
  defp correction_error(:same_agent), do: "That is already the agent on this one."

  defp correction_error(reason) when reason in [:no_agent, :unknown_agent],
    do: "That agent is no longer in this meeting."

  # The same sentence `stop_candidate` uses, because it is the same
  # fact: the deliverable exists.
  defp correction_error(:already_fired), do: "Too late — this one already went ahead."
  defp correction_error(_reason), do: "Could not record this correction."

  @doc """
  THE AGENTS IN THIS ROOM, as `[%{id:, name:}]` — the re-target options
  a card's correction panel offers (task 01a0740e stage 2).

  Deliberately not every active agent. `intent_agent_options/0` offers
  the global picker because on the producer's bar "wrong agent" usually
  means an agent who is NOT here. On a meeting card the question is
  narrower — the classifier handed a piece of work to the wrong one of
  the agents in the room — so this reads the meeting's own roster.

  `:participants` is LIVE PRESENCE (`build_meeting_participants/1`,
  which reads `Meetings.active_participants_for_space/1`), NOT
  `Chat.list_participants/1`; the moduledoc above still says the latter
  and is stale. `:participant_id` on that view-model is the AGENT id and
  not the presence row's id — see `meeting_participant_view_model/1` —
  which is what makes it the value `Candidates.correct/3` can look up,
  and getting that wrong would write exemplars pointing at rows that are
  not agents. Public so that mapping is asserted directly rather than
  only through a mounted LiveView, the same reason
  `meeting_participant_view_model/1` is.

  An agent whose identity did not resolve is dropped rather than
  labelled: `resolve_identity/1` answers nil for an orphaned presence
  row, and `Hand to <nothing>` is not a choice anybody can make.
  `uniq_by/2` because a rejoin can leave two live rows for one agent.

  The CURRENTLY ASSIGNED agent is not excluded here — that is per-card
  and the rail does it, because one roster serves every card on it.
  """
  def candidate_correction_agents(participants) when is_list(participants) do
    participants
    |> Enum.filter(fn p ->
      Map.get(p, :participant_type) == "agent" and is_binary(Map.get(p, :participant_id)) and
        is_binary(Map.get(p, :display_name))
    end)
    |> Enum.map(&%{id: &1.participant_id, name: &1.display_name})
    |> Enum.uniq_by(& &1.id)
  end

  def candidate_correction_agents(_participants), do: []

  # The board's own live/closed split, and it is NOT
  # `open_for_meeting/1`.
  #
  # That function answers a THREADING question — "what could an
  # incoming utterance still attach to" — and so excludes `:acting`
  # (`@open_states` stops before it). A board asking the same question
  # would drop a card off the rail at the exact moment the sweeper
  # claimed it and began doing the work, which is the one moment a
  # participant most wants to see it. Stage 4 of the mockup IS `:acting`.
  #
  # So the split is stated once, here, over a single `list_for_meeting/1`
  # read: a card is closed when its `state` says so OR when it carries a
  # `closed_reason` — the second clause for the same reason
  # `open_for_meeting/1` carries it, namely that `closed_reason` is the
  # durable mark and a row carrying it must not be offered as live
  # whatever its `state` column happens to say.
  #
  # Events are fetched for the whole meeting in ONE query and grouped,
  # rather than per card: a rail of twenty cards would otherwise issue
  # twenty queries on every broadcast, and candidate broadcasts arrive
  # at transcript speed.
  # ── After-call recap (task 01a07410 / FE-17 stage 6) ──────────────────
  #
  # `ChatLive.MeetingHooks` owns the leave lifecycle and its `meeting_leave`
  # / `meeting_left` clauses `:halt`, so MeetingLive never sees either
  # event in `handle_event/3`. This hook is attached FIRST (see the mount
  # pipeline) and `:cont`s, so it observes the leave without changing it.
  #
  # Built once per leave: `meeting_leave` (the button) is followed by
  # `meeting_left` (RoomEvent.Disconnected from the client), and by then
  # `stamp_local_left/1` has removed the viewer from the roster. The
  # `is_nil` guard keeps the first snapshot, the one that still lists the
  # person who is reading it.
  #
  # Idempotent on purpose: room -> room is a live patch on ONE pid, so
  # `handle_params/3` re-enters this pipeline and `attach_hook/4` raises on
  # a name already attached. `meeting_live_space_topic_holders_test.exs`
  # pins that the crash on that path is `MeetingHooks`' `:meeting_events`
  # attach and nothing else; this hook must not get there first.
  defp attach_call_recap_hook(%{assigns: %{call_recap_hooked?: true}} = socket), do: socket

  defp attach_call_recap_hook(socket) do
    socket
    |> assign(:call_recap_hooked?, true)
    |> attach_hook(:call_recap, :handle_event, fn
      leave, _params, %{assigns: %{call_recap: nil}} = socket
      when leave in ["meeting_leave", "meeting_left"] ->
        {:cont, assign(socket, :call_recap, build_call_recap(socket))}

      "meeting_join", _params, socket ->
        {:cont, assign(socket, :call_recap, nil)}

      _event, _params, socket ->
        {:cont, socket}
    end)
  end

  # The snapshot the recap renders from. Candidates are re-read rather
  # than taken from the board assigns because the board splits them and
  # the recap wants the whole narrative, oldest first (`list_for_meeting/1`).
  defp build_call_recap(%{assigns: %{meeting: %{id: meeting_id}} = assigns}) do
    %{
      left_at: DateTime.utc_now(),
      participants:
        assigns
        |> Map.get(:participants, [])
        |> Enum.map(& &1.display_name)
        |> Enum.reject(&is_nil/1),
      candidates: Candidates.list_for_meeting(meeting_id)
    }
  end

  @doc """
  Assign the Canvas tab's candidate board for `meeting_id`.

  PUBLIC as of task 01a05b14 stage 6, for the same reason as
  `load_agents_by_id/1`: the in-chat quickmeet renders the identical
  `CandidateRail` through `CallShell.call_rail/1`, and the live/closed
  split plus the grouped-event map is a CONTRACT of that component, not
  an implementation detail of this LiveView. Duplicating the split in
  `ChatLive.MeetingHooks` would let the two surfaces disagree about
  what "closed" means.
  """
  @spec assign_candidate_board(Phoenix.LiveView.Socket.t(), binary() | nil) ::
          Phoenix.LiveView.Socket.t()
  def assign_candidate_board(socket, meeting_id) when is_binary(meeting_id) do
    {closed, live} =
      meeting_id
      |> Candidates.list_for_meeting()
      |> Enum.split_with(&candidate_closed?/1)

    socket
    |> assign(:meeting_candidates, live)
    |> assign(:meeting_candidates_closed, closed)
    |> assign(:soonest_candidate, soonest_candidate(live))
    |> assign(
      :meeting_candidate_events,
      meeting_id |> CandidateEvents.list_for_meeting() |> Enum.group_by(& &1.candidate_id)
    )
  end

  def assign_candidate_board(socket, _meeting_id), do: socket

  @doc """
  The open candidate whose deadline lands FIRST, or `nil`.

  Derived rather than stored, and derived from the same `live` list the
  rail is handed, so the two cannot disagree about which card is next.
  It exists because the countdown that matters on a phone is not on the
  rail: `CallShell.call_rail/1` renders `candidate_rail/1` only inside
  the Canvas tab, and below `lg` that rail is a shut drawer, so the
  30-second window is two taps deep. The bottom-sheet handle needs ONE
  deadline, and this is which one.

  ## The `acts_at` filter is not defensive

  `meeting_candidates.acts_at` is nullable — a candidate is ARMED by
  `Countdown` writing a deadline onto it, and an unarmed open card has
  none. `Enum.min_by/4` over a list containing a `nil` would either
  crash on `DateTime.compare/2` or, worse under a plain `&<=/2`, sort
  `nil` below every DateTime and elect an unarmed card as "soonest",
  which paints a handle that never counts down. So unarmed cards are
  rejected before the comparison rather than handled inside it.

  `DateTime` is passed as the SORTER. The default `&<=/2` is Erlang
  term order, which on two `%DateTime{}` structs compares struct fields
  alphabetically — `:calendar` before `:day` before `:hour` — and is
  simply not chronology. It agrees with chronology often enough on
  same-day timestamps to pass a careless test.

  Returns the whole candidate, not its `acts_at`: the handle needs the
  id to be the thing a tap acts on, and a bare timestamp would make
  that a second lookup that could resolve to a different card.
  """
  @spec soonest_candidate([map()]) :: map() | nil
  def soonest_candidate(candidates) when is_list(candidates) do
    candidates
    |> Enum.reject(&is_nil(&1.acts_at))
    |> Enum.min_by(& &1.acts_at, DateTime, fn -> nil end)
  end

  def soonest_candidate(_candidates), do: nil

  defp candidate_closed?(%{state: :closed}), do: true
  defp candidate_closed?(%{closed_reason: reason}) when not is_nil(reason), do: true
  defp candidate_closed?(_candidate), do: false

  defp with_intents_gate(%{assigns: %{intents_visible?: true}} = socket, fun) do
    {:noreply, fun.(socket)}
  end

  defp with_intents_gate(socket, _fun), do: {:noreply, socket}

  defp find_intent(socket, intent_id) when is_binary(intent_id) do
    Enum.find(socket.assigns.intents, &(&1.id == intent_id))
  end

  defp find_intent(_socket, _intent_id), do: nil

  # Only accept a reason the corpus schema already knows. Parsing a
  # client string with `String.to_atom/1` would let a crafted click leak
  # arbitrary atoms into the VM, and `Ecto.Enum` would reject it one
  # layer later anyway — with a changeset error nobody sees.
  defp parse_correction_reason(reason) when is_binary(reason) do
    case Enum.find(IntentCorrection.reasons(), &(Atom.to_string(&1) == reason)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  defp parse_correction_reason(_), do: :error

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp apply_intent_cancel(socket, row, opts) do
    {IntentQueue.cancel(socket.assigns.meeting.id, row.id, opts), socket}
  end

  # Reconcile the strip with what `IntentQueue.cancel/3` actually did.
  #
  # `:cancel_requested` is the one that matters and the one the design
  # mock predates: the row is STILL `:dispatched`/`:acked` — it moves
  # only when the target answers `intent_ack(:cancel_honored)`. So the
  # row stays put and joins the pending-cancel set, which renders a
  # "Cancelling" chip and disables its controls. Optimistically showing
  # `:cancelled` while a subagent kept working would be the exact
  # invisibility this task removes.
  defp apply_cancel_result(socket, row, {:ok, :deleted, _row}) do
    assign(socket, :intents, Enum.reject(socket.assigns.intents, &(&1.id == row.id)))
  end

  defp apply_cancel_result(socket, row, {:ok, :cancel_requested, _row}) do
    assign(
      socket,
      :intent_pending_cancels,
      MapSet.put(socket.assigns.intent_pending_cancels, row.id)
    )
  end

  defp apply_cancel_result(socket, _row, {:ok, outcome, updated})
       when outcome in [:cancelled, :cancelled_late] do
    assign(socket, :intents, upsert_intent(socket.assigns.intents, updated))
  end

  # A row already terminal when the click landed — the correction is
  # still written (the classifier was still wrong), but there is nothing
  # to cancel, so the row is simply dropped from the strip.
  defp apply_cancel_result(socket, row, {:error, {:not_cancellable, _status}}) do
    assign(socket, :intents, Enum.reject(socket.assigns.intents, &(&1.id == row.id)))
  end

  defp apply_cancel_result(socket, row, {:error, :not_found}) do
    assign(socket, :intents, Enum.reject(socket.assigns.intents, &(&1.id == row.id)))
  end

  defp apply_cancel_result(socket, _row, _other), do: socket

  # Stage 6 decided the X/pencil is the corrections writer:
  # `IntentQueue.cancel/3` deliberately writes NO corpus row, so that the
  # queue can be exercised without a table. This is the other half of
  # that decision.
  #
  # `transcript_chunk_excerpt` is denormalized in because by the time
  # anyone reads the corpus the ETS row carrying the utterance is gone
  # with its meeting.
  defp write_intent_correction(socket, row, attrs) do
    base = %{
      meeting_id: socket.assigns.meeting.id,
      transcript_chunk_excerpt: row.chunk_excerpt,
      classified_intent: to_string(row.classified_intent || ""),
      classified_target_agent_id: row.target_agent_id,
      actor_participant_id: participant_id(socket.assigns[:current_participant])
    }

    case IntentCorrections.create_correction(Map.merge(base, attrs)) do
      {:ok, correction} ->
        {:ok, correction}

      {:error, changeset} ->
        Logger.warning(
          "[MeetingLive] intent correction rejected meeting_id=#{socket.assigns.meeting.id} " <>
            "intent_id=#{row.id} errors=#{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp participant_id(%{id: id}), do: id
  defp participant_id(_), do: nil

  # Replace-or-append by id, then re-sort on the queue server's
  # monotonic `seq`. Sorting on `seq` rather than on arrival order means
  # an out-of-order PubSub delivery cannot reorder the bar under a
  # producer who is mid-click.
  defp upsert_intent(intents, row) do
    intents
    |> Enum.reject(&(&1.id == row.id))
    |> Kernel.++([row])
    |> Enum.sort_by(&intent_sort_key/1)
  end

  defp intent_sort_key(%{seq: seq}) when is_integer(seq), do: seq
  defp intent_sort_key(_), do: 0

  defp intents_for_this_meeting?(%{assigns: %{meeting: %{id: id}}}, %{meeting_id: id}), do: true
  defp intents_for_this_meeting?(_socket, _row), do: false

  # Both guard the same way the intents bar does: the topic already
  # scopes delivery, but a socket that has not yet resolved `:meeting`
  # (the index action, or a guest still on the name-entry card) has no
  # `:agent_activity` to update and must not KeyError on one.
  defp activity_for_this_meeting?(%{assigns: %{meeting: %{id: id}}}, id), do: true
  defp activity_for_this_meeting?(_socket, _meeting_id), do: false

  defp meeting_space?(%{assigns: %{meeting: %{chat_space_id: space_id}}}, space_id)
       when is_binary(space_id),
       do: true

  defp meeting_space?(_socket, _space_id), do: false

  defp resolve_pending_cancel(socket, event, row) when event in @cancel_resolving_events do
    assign(
      socket,
      :intent_pending_cancels,
      MapSet.delete(socket.assigns.intent_pending_cancels, row.id)
    )
  end

  defp resolve_pending_cancel(socket, _event, _row), do: socket

  # ── Stage-mode presentation helpers (used by the heex shell) ─────────────

  # Parse an untrusted stage-mode string into one of the four known mode
  # atoms. Uses an explicit allow-list rather than `String.to_atom/1` so a
  # crafted phx-click value can't leak arbitrary atoms into the VM.
  defp parse_stage_mode(mode) when is_binary(mode) do
    Enum.find_value(@stage_modes, :error, fn known ->
      if Atom.to_string(known) == mode, do: {:ok, known}
    end)
  end

  defp parse_stage_mode(_), do: :error

  # Normalize the `session["chrome_mode"]` value into one of `:shell` or
  # `:none`. Session-injected values from the `:guest_meeting` router
  # `live_session` block arrive as the string `"none"`; direct-mount
  # tests (bypassing the live_session boundary) may pass the atom
  # `:none` directly. Anything else — including an absent key from the
  # default authenticated `/meetings` mount — falls back to `:shell`.
  # Explicit allow-list rather than String.to_atom/1 for the same reason
  # `parse_stage_mode/1` uses one: no untrusted atom coinage into the VM.
  # Task 019f498d stage 1.
  defp normalize_chrome_mode("none"), do: :none
  defp normalize_chrome_mode(:none), do: :none
  defp normalize_chrome_mode(_), do: :shell

  # The name to show for a signed-in ACCOUNT on the chrome-less member
  # surface (task 019fb955-f8b1 stage 5). Same `name || email` precedence
  # `ShellLive.on_mount/4` uses for `:current_user`, so the member badge
  # and the shell header never disagree about what to call someone.
  #
  # No fallback string. A nil here renders NO member badge, which is the
  # honest outcome for a mount with no account behind it (the anonymous
  # `Ecto.UUID.generate()` test path); inventing "User" would put a name
  # on the surface that names nobody.
  defp member_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp member_display_name(%{email: email}) when is_binary(email) and email != "", do: email
  defp member_display_name(_), do: nil

  # ── Index helpers (`:index` action) ──────────────────────────────────────
  #
  # `group_meetings_by_status/1` outlived the grouped section/row list it
  # was written for: task 019fb954-8ead stage 3 replaced that list with the
  # mobile week strip and day view, and the calendar buckets by DATE, not
  # by status. The projection stays because `:grouped_meetings` is still
  # maintained across the index's PubSub handlers and is the only
  # status-partitioned view of the index's meetings; the four view helpers
  # that rendered the sections (`meeting_status_sections/0`,
  # `meeting_section_label/1`, `meeting_section_icon/1`,
  # `meeting_status_pill/1`) were deleted with the markup, having had no
  # other caller.

  @doc """
  Group a list of meetings into a `%{live: …, upcoming: …, ended: …}` map.

  Each bucket is itself ordered newest-first. `scheduled` rows land in
  `:upcoming`; anything else (defensive) falls through to `:upcoming`.
  """
  @spec group_meetings_by_status([Meetings.Meeting.t()]) :: %{
          live: [Meetings.Meeting.t()],
          upcoming: [Meetings.Meeting.t()],
          ended: [Meetings.Meeting.t()]
        }
  def group_meetings_by_status(meetings) when is_list(meetings) do
    base = %{live: [], upcoming: [], ended: []}

    grouped =
      Enum.reduce(meetings, base, fn meeting, acc ->
        bucket = status_bucket(meeting.status)
        Map.update!(acc, bucket, &[meeting | &1])
      end)

    # `Enum.reduce/3` builds each list in reverse insertion order. The
    # input is already newest-first (Repo `desc: :inserted_at`), so a
    # reverse here restores newest-first within each bucket.
    %{
      live: Enum.reverse(grouped.live),
      upcoming: Enum.reverse(grouped.upcoming),
      ended: Enum.reverse(grouped.ended)
    }
  end

  def group_meetings_by_status(_), do: %{live: [], upcoming: [], ended: []}

  defp status_bucket("live"), do: :live
  defp status_bucket("ended"), do: :ended
  defp status_bucket(_), do: :upcoming

  # Default create-sheet form values. When exactly one project exists we
  # pre-fill it so a single-project workspace doesn't show a useless
  # one-option select.
  #
  # `date` and `start_time` default to BLANK, which is the ad-hoc meeting:
  # `create_meeting/1` takes the intended-time pair as both-or-neither, and
  # both nil is the supported "started but never scheduled" state. Nothing
  # here invents a start time the user did not choose.
  defp blank_start_meeting_form(projects) when is_list(projects) do
    project_id =
      case projects do
        [%{id: id}] -> id
        _ -> ""
      end

    %{
      "name" => "",
      "project_id" => project_id,
      "date" => "",
      "start_time" => "",
      "duration_minutes" => to_string(@default_duration_minutes)
    }
  end

  defp blank_start_meeting_form(_), do: blank_start_meeting_form([])

  # Echo the submitted params back into the form assign so a refusal
  # re-render keeps what the user typed. Raw, not trimmed: trimming here
  # would edit the field under the cursor.
  defp start_meeting_form(attrs) do
    %{
      "name" => attrs |> Map.get("name", "") |> to_string(),
      "project_id" => attrs |> Map.get("project_id", "") |> to_string(),
      "date" => attrs |> Map.get("date", "") |> to_string(),
      "start_time" => attrs |> Map.get("start_time", "") |> to_string(),
      "duration_minutes" =>
        attrs
        |> Map.get("duration_minutes", @default_duration_minutes)
        |> to_string()
    }
  end

  defp refuse_create(socket, attrs, message) do
    {:noreply,
     socket
     |> assign(:start_meeting_form, start_meeting_form(attrs))
     |> assign(:start_meeting_error, message)}
  end

  # `mode` is `:stay` for the scheduling form and `:enter` for Meet now.
  #
  # The COMMIT is identical in both — same `Meetings.create_meeting/1`, same
  # staged-invite replay, same undelivered-invite flash — and only what
  # happens to the viewer afterwards differs. That split is deliberate and
  # is the reason the mode is a caller's argument rather than something
  # this function infers: a meeting scheduled for next Wednesday must not
  # open its room now (see the long note above `open_start_meeting_sheet`),
  # and a meeting started now must. Inferring it from `starts_at` would
  # make "is this meeting starting soon enough to jump into" a threshold
  # nobody chose.
  #
  # `:enter` drops the "Meeting created." flash: the viewer is about to be
  # looking at the room, so the confirmation is redundant with the evidence
  # in front of them. It keeps the undelivered-invite flash, which is a
  # report of something that did NOT happen and survives the navigation.
  defp create_from_sheet(socket, attrs, name, project_id, starts_at, ends_at, mode) do
    case Meetings.create_meeting(%{
           project_id: project_id,
           name: name,
           scheduled_start_at: starts_at,
           scheduled_end_at: ends_at
         }) do
      {:ok, meeting} ->
        undelivered = replay_draft_invites(meeting, socket.assigns.meeting_create_invites)

        socket =
          socket
          |> assign(:show_start_meeting_sheet, false)
          |> reset_create_sheet()
          |> flash_undelivered_invites(undelivered)

        case mode do
          :stay ->
            {:noreply, put_flash(socket, :info, "Meeting created.")}

          :enter ->
            # Re-asserted AFTER `reset_create_sheet/1`, which clears it.
            # Without this the double-tap guard is vacuous: a LiveView
            # handles its events one at a time, so the second tap is not
            # racing the first — it arrives after the first has already
            # completed and reset the flag, and it would commit a second
            # meeting. This process is about to be replaced by the
            # navigation, so leaving the flag set costs nothing.
            {:noreply,
             socket
             |> assign(:meet_now_pending?, true)
             |> push_navigate(to: ~p"/meetings/#{meeting.slug}")}
        end

      {:error, _reason} ->
        # Cleared here so a failed Meet now can be retried in place. A
        # button left disabled after a failure would need a sheet reopen to
        # recover and the viewer has no way to know that.
        socket
        |> assign(:meet_now_pending?, false)
        |> refuse_create(attrs, "Could not create meeting.")
    end
  end

  # The default name. `"Meeting · 25 Sep 2026, 7:14 PM"` in the viewer's
  # zone — the same shift-then-fall-back shape `archive_strftime/3` uses.
  #
  # A nil zone must NOT refuse the way `resolve_window/4` does. That clause
  # refuses because there is no honest way to turn "9:00" into an instant
  # without a zone; here the instant is already known and the zone only
  # decides how to LABEL it. Refusing to create a meeting over the wording
  # of its own title would be the wrong trade.
  defp meet_now_name(%DateTime{} = at, time_zone) do
    zone = time_zone || "Etc/UTC"

    formatted =
      case DateTime.shift_zone(at, zone) do
        {:ok, shifted} -> Calendar.strftime(shifted, "%-d %b %Y, %-I:%M %p")
        {:error, _reason} -> Calendar.strftime(at, "%-d %b %Y, %-I:%M %p")
      end

    "Meeting · " <> formatted
  end

  # Which project an instant meeting lands in, or nil when nothing can be
  # resolved. `meetings.project_id` is NOT NULL, so nil here means refuse,
  # never "create it without one".
  #
  # Every branch reads an assign the index already holds. Deliberately no
  # query: this runs on a click that is supposed to feel instant, and the
  # "most recent" answer a query would give is the same one `@meetings`
  # already carries — `list_meetings_for_user/1` orders `desc: inserted_at`.
  # Resolve ONCE and store both halves, so the label on the tile and the
  # project the click commits to cannot disagree. The alternative — the
  # template deriving a name and the handler re-resolving an id — is two
  # answers to one question, and the sheet would eventually name one
  # project and create the meeting in another.
  defp assign_meet_now_project(socket) do
    id = meet_now_project_id(socket)

    name =
      id &&
        (socket.assigns[:projects] || [])
        |> Enum.find(&(&1.id == id))
        |> then(&(&1 && &1.name))

    socket
    |> assign(:meet_now_project_id, id)
    |> assign(:meet_now_project_name, name)
  end

  defp meet_now_project_id(socket) do
    projects = socket.assigns[:projects] || []
    project_ids = MapSet.new(projects, & &1.id)

    selected =
      socket.assigns[:start_meeting_form]
      |> Kernel.||(%{})
      |> Map.get("project_id", "")
      |> to_string()
      |> String.trim()

    cond do
      # Covers two cases at once: the single-project pre-fill in
      # `blank_start_meeting_form/1`, and a viewer who picked a project in
      # the form and then decided to start the call now instead. Membership
      # is re-checked because the form echoes back whatever was submitted.
      selected != "" and MapSet.member?(project_ids, selected) ->
        selected

      true ->
        recent =
          (socket.assigns[:meetings] || [])
          |> Enum.find_value(fn meeting ->
            id = Map.get(meeting, :project_id)
            if id && MapSet.member?(project_ids, id), do: id
          end)

        recent || projects |> List.first() |> then(&(&1 && &1.id))
    end
  end

  # ── The intended-time pair ───────────────────────────────────────────────
  #
  # `Meeting.changeset/2` validates `scheduled_start_at` and
  # `scheduled_end_at` as a pair, so this returns both or neither. It never
  # synthesises one endpoint from the other beyond the duration the user
  # picked.

  defp scheduled_window(attrs, time_zone) do
    date = attrs |> Map.get("date", "") |> to_string() |> String.trim()
    start_time = attrs |> Map.get("start_time", "") |> to_string() |> String.trim()

    case {date, start_time} do
      {"", ""} -> {:ok, nil, nil}
      {"", _} -> {:error, @schedule_pair_error}
      {_, ""} -> {:error, @schedule_pair_error}
      {date, start_time} -> resolve_window(date, start_time, attrs, time_zone)
    end
  end

  # A nil zone is the DEAD RENDER's answer: `resolve_time_zone/1` returns
  # nil when the browser sent no usable IANA name, which on the index means
  # the LiveSocket has not connected yet. A submit cannot arrive over a
  # dead render, so reaching here with nil means the browser genuinely
  # could not name its zone — and there is no honest way to turn "9:00" into
  # an instant without one. Refuse rather than quietly reading it as UTC:
  # a meeting silently placed hours off is worse than one not created.
  # Unscheduled creates are unaffected, because they never reach this
  # clause.
  defp resolve_window(_date, _start_time, _attrs, nil), do: {:error, @no_time_zone_error}

  defp resolve_window(date, start_time, attrs, time_zone) do
    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, time} <- Time.from_iso8601(with_seconds(start_time)),
         {:ok, minutes} <- duration_minutes(attrs),
         {:ok, starts_at} <- local_datetime(date, time, time_zone) do
      {:ok, starts_at, DateTime.add(starts_at, minutes * 60, :second)}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _reason} -> {:error, @invalid_time_error}
    end
  end

  # `<input type="time">` submits `HH:MM` when the step is a minute and
  # `HH:MM:SS` when it is finer. `Time.from_iso8601/1` requires seconds.
  defp with_seconds(<<_h::binary-2, ?:, _m::binary-2>> = value), do: value <> ":00"
  defp with_seconds(value), do: value

  # An allowlist, not a range check. The select offers exactly these, so a
  # value outside them did not come from this form.
  defp duration_minutes(attrs) do
    raw = attrs |> Map.get("duration_minutes", "") |> to_string() |> String.trim()

    case Integer.parse(raw) do
      {minutes, ""} when minutes in @duration_options -> {:ok, minutes}
      _ -> {:error, @invalid_duration_error}
    end
  end

  # `{:ambiguous, …}` is the autumn DST repeat: the wall clock reads this
  # time twice and both instants are real. The FIRST is chosen because it
  # is the one still on the pre-transition offset, which is what someone
  # reading a clock that day means. `{:gap, …}` is the spring skip — that
  # wall time does not occur, so there is nothing to choose and it is
  # refused rather than nudged to a neighbour.
  defp local_datetime(date, time, time_zone) do
    case DateTime.new(date, time, time_zone) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, _after} -> {:error, @nonexistent_time_error}
      {:error, _reason} -> {:error, @invalid_time_error}
    end
  end

  # ── Draft invites ────────────────────────────────────────────────────────

  defp reset_create_sheet(socket) do
    socket
    |> assign(:start_meeting_form, blank_start_meeting_form(socket.assigns[:projects] || []))
    |> assign(:start_meeting_error, nil)
    # Cleared on the OPEN path, which is where the sheet's reset lives, so
    # a Meet now that navigated away leaves no disabled button behind for
    # the next open. The failure path clears it separately — that one never
    # reaches here.
    |> assign(:meet_now_pending?, false)
    |> assign_meet_now_project()
    |> seed_create_invite_assigns()
  end

  defp seed_create_invite_assigns(socket) do
    socket
    |> assign(:meeting_create_invites, [])
    |> clear_create_invite_search()
  end

  # Staging closes the dropdown by emptying what it dispatches on, rather
  # than by a separate "open?" flag that could disagree with the list.
  defp clear_create_invite_search(socket) do
    socket
    |> assign(:meeting_create_invite_query, "")
    |> assign(:meeting_create_invite_candidates, [])
    |> assign(:meeting_create_invite_email, nil)
  end

  defp assign_create_invite_candidates(socket, query) do
    staged = socket.assigns.meeting_create_invites

    %{users: users, email: email} =
      Meetings.resolve_invite_candidates(query,
        exclude_user_ids: for(%{kind: :user, user_id: id} <- staged, do: id),
        exclude_emails: for(%{email: address} <- staged, is_binary(address), do: address)
      )

    socket
    |> assign(:meeting_create_invite_query, query)
    |> assign(:meeting_create_invite_candidates, users)
    |> assign(:meeting_create_invite_email, email)
  end

  # The staged shapes. `:user` resolves against the RENDERED candidate
  # list, not the database: the only legal source of that id is a row this
  # socket just drew, so an id from anywhere else is a forged event and
  # raises instead of quietly staging a stranger.
  defp build_draft_invite("user", %{"id" => user_id}, socket) do
    case Enum.find(socket.assigns.meeting_create_invite_candidates, &(&1.id == user_id)) do
      nil ->
        raise ArgumentError,
              "cannot stage invite: no candidate is currently offered for that id"

      user ->
        %{
          id: "user:" <> user.id,
          kind: :user,
          user_id: user.id,
          email: user.email,
          display_name: user.name || user.email,
          subtitle: user.name && user.email,
          avatar_url: nil
        }
    end
  end

  defp build_draft_invite("guest", %{"email" => email}, _socket) do
    address = email |> to_string() |> String.trim()

    %{
      id: "guest:" <> address,
      kind: :guest,
      user_id: nil,
      email: address,
      display_name: address,
      subtitle: "expires in #{Meetings.guest_invite_default_expiry_hours()}h",
      avatar_url: nil
    }
  end

  defp build_draft_invite("external", %{"email" => email}, _socket) do
    address = email |> to_string() |> String.trim()

    %{
      id: "external:" <> address,
      kind: :external,
      user_id: nil,
      email: address,
      display_name: address,
      subtitle: nil,
      avatar_url: nil
    }
  end

  defp build_draft_invite(kind, _params, _socket) do
    raise ArgumentError, "no draft invite kind #{inspect(kind)}"
  end

  @doc """
  Map staged create-sheet entries onto `InviteControl.invite_list/1`'s
  entry contract.

  `:expires_at` on a guest row is a PROJECTION, not a record: no token has
  been minted, so this is the expiry `invite_guest/2` would mint if the
  sheet were submitted now. It exists because `InviteControl.tag/1` reads
  a `%DateTime{}` expiry as the thing that distinguishes a guest from an
  external address awaiting a grant — the two differ in nothing else at
  draft time.
  """
  def draft_invite_rows(entries) when is_list(entries), do: Enum.map(entries, &draft_invite_row/1)

  defp draft_invite_row(entry) do
    %{
      id: entry.id,
      name: entry.display_name,
      subtitle: entry.subtitle,
      user_id: entry.user_id,
      email: entry.email,
      expires_at: projected_expiry(entry.kind),
      # External-ness of an ACCOUNT is an org-membership property that the
      # candidate list does not carry, so a staged member is tagged by what
      # is known: they hold an account.
      external: false,
      agent: false,
      avatar_url: entry.avatar_url,
      removable: true,
      copy_url: nil
    }
  end

  defp projected_expiry(:guest) do
    DateTime.add(
      DateTime.utc_now(),
      Meetings.guest_invite_default_expiry_hours() * 3600,
      :second
    )
  end

  defp projected_expiry(_kind), do: nil

  # One call per staged entry, after the meeting is committed. Returns the
  # entries that did NOT produce a row.
  defp replay_draft_invites(meeting, entries) do
    Enum.reject(entries, &match?({:ok, _}, deliver_draft_invite(meeting, &1)))
  end

  defp deliver_draft_invite(meeting, %{kind: :user} = entry),
    do: Meetings.invite_user(meeting, entry.user_id, display_name: entry.display_name)

  defp deliver_draft_invite(meeting, %{kind: :guest} = entry),
    do: Meetings.invite_guest(meeting, %{display_name: entry.display_name, email: entry.email})

  defp deliver_draft_invite(meeting, %{kind: :external} = entry),
    do: Meetings.invite_external_user(meeting, entry.email, display_name: entry.display_name)

  # ── Live invites (private) ───────────────────────────────────────────────

  # Closed, empty, and no candidates. Called on open as well as on close so
  # the control never re-appears carrying the previous meeting's query.
  defp seed_live_invite_assigns(socket) do
    socket
    |> assign(:meeting_invite_open, false)
    |> clear_live_invite_search()
  end

  defp clear_live_invite_search(socket) do
    socket
    |> assign(:meeting_invite_query, "")
    |> assign(:meeting_invite_candidates, [])
    |> assign(:meeting_invite_email, nil)
  end

  # The exclusions come from the WRITTEN rows, not from a staging list:
  # in live mode the invite exists the moment it is chosen, so "already
  # invited" is a fact about the database. Without them the picker keeps
  # offering someone who is already on the list one row above it.
  defp assign_live_invite_candidates(socket, query) do
    invites =
      case selected_meeting(socket.assigns) do
        %Meeting{} = meeting -> Meetings.list_invites(meeting.id)
        nil -> []
      end

    %{users: users, email: email} =
      Meetings.resolve_invite_candidates(query,
        exclude_user_ids: for(%Invite{user_id: id} <- invites, is_binary(id), do: id),
        exclude_emails: for(%Invite{email: address} <- invites, is_binary(address), do: address)
      )

    socket
    |> assign(:meeting_invite_query, query)
    |> assign(:meeting_invite_candidates, users)
    |> assign(:meeting_invite_email, email)
  end

  # The control only renders inside a rendered detail surface, and that
  # surface only renders for a meeting in the loaded week — so an invite
  # event arriving with no selection did not come from this UI. Raise
  # rather than no-op: a silently-dropped invite is the failure mode this
  # whole surface exists to remove.
  defp selected_live_invite_meeting!(socket) do
    case selected_meeting(socket.assigns) do
      %Meeting{} = meeting ->
        meeting

      nil ->
        raise ArgumentError, "cannot invite: no meeting is selected in the detail surface"
    end
  end

  # `:user` resolves against the RENDERED candidate list rather than the
  # database, the same rule the draft path follows: the only legal source
  # of that id is a row this socket just drew.
  defp deliver_live_invite(meeting, "user", %{"id" => user_id}, socket) do
    case Enum.find(socket.assigns.meeting_invite_candidates, &(&1.id == user_id)) do
      nil ->
        raise ArgumentError,
              "cannot invite: no candidate is currently offered for that id"

      user ->
        Meetings.invite_user(meeting, user.id, display_name: user.name || user.email)
    end
  end

  defp deliver_live_invite(meeting, "guest", %{"email" => email}, socket) do
    address = email |> to_string() |> String.trim()

    Meetings.invite_guest(meeting, %{
      display_name: address,
      email: address,
      host_user_id: socket.assigns.user_id
    })
  end

  defp deliver_live_invite(meeting, "external", %{"email" => email}, _socket) do
    address = email |> to_string() |> String.trim()

    Meetings.invite_external_user(meeting, address, display_name: address)
  end

  defp deliver_live_invite(_meeting, kind, _params, _socket) do
    raise ArgumentError, "no live invite kind #{inspect(kind)}"
  end

  defp flash_undelivered_invites(socket, []), do: socket

  defp flash_undelivered_invites(socket, undelivered) do
    count = length(undelivered)
    noun = if count == 1, do: "invite", else: "invites"

    put_flash(socket, :error, "#{count} #{noun} could not be sent.")
  end

  # `blank_guest_invite_form/0`, `trim_or_nil/1` and `parse_expires_hours/1`
  # lived here until task 019fb955-1d7b stage 1. They existed only to feed the
  # meeting-wide guest-invite sheet, which minted an unattributable forwardable
  # link; with that sheet gone they had no other caller. Guest tokens are now
  # produced solely by `Meetings.invite_guest/2`, which does its own trimming
  # and expiry defaulting against a persisted `meeting_invites` row.

  # `meeting_section_label/1`, `meeting_section_icon/1` and
  # `meeting_status_pill/1` lived here until task 019fb954-8ead stage 3.
  # All three took a SECTION atom and existed only to draw the grouped
  # section/row list that the mobile week strip and day view replaced. A
  # meeting-status pill on the stage-4 detail surface is a different
  # function with a different argument (a status string), so keeping
  # these as a starting point would have been keeping the wrong shape.

  @doc "Hero-icon class for a stage-mode segmented-control button."
  def stage_mode_icon(:canvas), do: "hero-rectangle-stack"
  def stage_mode_icon(:screen), do: "hero-computer-desktop"
  def stage_mode_icon(:gallery), do: "hero-squares-2x2"
  def stage_mode_icon(:whiteboard), do: "hero-pencil-square"

  @doc "Human label for a stage-mode segmented-control button."
  def stage_mode_label(:canvas), do: "Canvas"
  def stage_mode_label(:screen), do: "Screen"
  def stage_mode_label(:gallery), do: "Gallery"
  def stage_mode_label(:whiteboard), do: "Whiteboard"

  # ── Canvas-mode helpers ──────────────────────────────────────────────────
  #
  # Canvas mode renders the RESOLVED canvas: the viewer's explicit pick
  # when they have made one, otherwise the default below. When the space
  # has no canvas at all, the heex renders the "No canvas yet"
  # empty-state CTA which routes back to
  # `handle_event("create_meeting_canvas", …)` above.

  # THE default rule, in one place. Every path that needs "which canvas
  # when nobody has chosen" goes through here — `latest_canvas/1` for a
  # space id, `resolve_meeting_canvas/2` for an already-loaded list — so
  # the decision below is stated once and cannot drift between them.
  #
  # `Chat.list_canvases/1` returns oldest-first (it orders
  # `[asc: c.inserted_at]`), so the last element is the most recently
  # CREATED.
  #
  # Decision (task 019ff704 stage 3) — this stays most-recently-CREATED.
  # It is NOT changed to most-recently-UPDATED, and that is deliberate
  # rather than an oversight: `Canvas` carries both `updated_at` and
  # `revision`, so the switch would be a one-line change.
  #
  # The reason to refuse it: "most recently updated" makes the default
  # view MOVE whenever an agent edits some OTHER canvas. That is the
  # same silent yank this ticket exists to prevent — a participant
  # watching one canvas is dragged to another by an edit they did not
  # make — merely applied to the people who have not picked yet instead
  # of the people who have. The complaint that motivates "latest
  # updated" is really staleness, and staleness is what the PICKER and
  # the just-changed dot answer: a viewer who wants the freshly-edited
  # canvas can see which one changed and choose it. Choosing is stable;
  # being moved is not.
  defp default_canvas(canvases) when is_list(canvases), do: List.last(canvases)
  defp default_canvas(_), do: nil

  # `default_canvas/1` for a space id rather than a loaded list.
  defp latest_canvas(space_id) when is_binary(space_id) do
    space_id
    |> Chat.list_canvases()
    |> default_canvas()
  end

  defp latest_canvas(_), do: nil

  # Load the space's canvases and (re)resolve the rendered one. Used at
  # both mount clauses and after any broadcast that can change the set,
  # so `:meeting_canvases` and `:meeting_canvas` are never derived from
  # different snapshots.
  defp assign_meeting_canvases(socket, space_id) do
    canvases = if is_binary(space_id), do: Chat.list_canvases(space_id), else: []
    selected = socket.assigns[:selected_canvas_id]

    socket
    |> assign(:meeting_canvases, canvases)
    |> assign(:selected_canvas_id, selected)
    |> assign(:meeting_canvas, resolve_meeting_canvas(canvases, selected))
    |> seed_canvas_seen_revisions(canvases)
    # The explorer's own state, preserved across a peer's canvas arriving
    # the same way `:selected_canvas_id` is above — re-deriving from
    # `socket.assigns` rather than resetting means a viewer who collapsed
    # the group or paged past the first screen does not snap back to page 1
    # every time someone else creates a canvas. Seeded open (not collapsed)
    # on first load, matching the old `<details>` list's always-visible rows.
    |> assign(
      :canvas_explorer_expanded_keys,
      socket.assigns[:canvas_explorer_expanded_keys] || ["space:" <> to_string(space_id)]
    )
    |> assign(:canvas_explorer_offset, socket.assigns[:canvas_explorer_offset] || 0)
  end

  # The session's "state of the world when you arrived" baseline. Every
  # canvas already in the space counts as seen, so the picker opens with
  # no dots: the dot answers "what changed since I got here", not "what
  # have I never opened". A meeting with five canvases would otherwise
  # open with four permanent dots that nothing but clicking each one can
  # clear — a signal that is on by default is not a signal.
  #
  # Existing entries WIN over the freshly-seeded ones so a re-entry into
  # this function cannot silently re-baseline a canvas the viewer has an
  # unacknowledged change for.
  defp seed_canvas_seen_revisions(socket, canvases) do
    existing = socket.assigns[:canvas_seen_revisions] || %{}
    seeded = Map.new(canvases, fn c -> {c.id, canvas_revision(c)} end)

    assign(socket, :canvas_seen_revisions, Map.merge(seeded, existing))
  end

  # Record `canvas` as seen at its current revision — i.e. the viewer is
  # looking at it now, so it has no news left to carry.
  defp mark_canvas_seen(socket, %{id: id} = canvas) do
    seen = socket.assigns[:canvas_seen_revisions] || %{}

    assign(socket, :canvas_seen_revisions, Map.put(seen, id, canvas_revision(canvas)))
  end

  defp mark_canvas_seen(socket, _), do: socket

  # `revision` is NOT a column on `Chat.Canvas`. It lives inside the
  # canonical `document` map (ADR 0036) and is read through
  # `CanvasDocument.revision/1`, which returns 0 for a document that has
  # no integer revision. Reading `canvas.revision` would compile (structs
  # raise only on unknown keys at build time, and this one is fetched
  # dynamically in places) but would be `nil` forever, and `nil > 3` is
  # `true` in Elixir's term order — a silently always-dotted picker.
  defp canvas_revision(%{document: document}) when is_map(document),
    do: CanvasDocument.revision(document)

  defp canvas_revision(_), do: 0

  @doc """
  Display name for a canvas in the picker.

  Canvas titles are user-written, so blank and whitespace-only titles are
  both real. They collapse to the same placeholder the canvas tile uses —
  a picker row with no visible text is unclickable in practice.
  """
  @spec canvas_picker_label(Canvas.t() | map() | nil) :: String.t()
  def canvas_picker_label(%{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> "Untitled canvas"
      trimmed -> trimmed
    end
  end

  def canvas_picker_label(_), do: "Untitled canvas"

  @doc """
  Does `canvas` carry news this viewer has not seen?

  True when its document revision has moved past the recorded baseline,
  or when it has no baseline at all (it arrived after the viewer did).

  The canvas currently ON SCREEN never reports changed, whatever the map
  says. That is the "clear the marker when it is the displayed canvas"
  rule stated once, at the point of render, so no future handler can
  reintroduce a dot on the thing the viewer is already looking at by
  forgetting to clear it.

  HONEST NOTE (task 019ff704 stage 4): a mutation deleting that first
  clause SURVIVED the suite. Every path that currently puts a canvas on
  screen also calls `mark_canvas_seen/2`, so the guard changes no
  observable outcome and the tests cannot tell it is there. It is kept
  rather than deleted because one reachable path does NOT mark:
  `resolve_meeting_canvas/2` falls back to the default when a selection
  stops resolving (the picked canvas was deleted mid-call), which can
  put a canvas with an unseen edit on screen without any handler
  recording it. No test drives a mid-session delete, so that path is
  argued rather than demonstrated — which is exactly why the surviving
  mutant is recorded here instead of being papered over with a test
  written backwards from the mutation.
  """
  @spec canvas_changed?(map(), Canvas.t() | map(), Canvas.t() | map() | nil) :: boolean()
  def canvas_changed?(seen, canvas, shown)

  def canvas_changed?(_seen, %{id: id}, %{id: id}), do: false

  def canvas_changed?(seen, %{id: id} = canvas, _shown) when is_map(seen) do
    case Map.fetch(seen, id) do
      :error -> true
      {:ok, revision} -> canvas_revision(canvas) > revision
    end
  end

  def canvas_changed?(_, _, _), do: false

  @doc """
  This meeting's own canvases, shaped as the ONE `CanvasExplorer` group the
  canvas-mode picker renders (task 019ff704, `CanvasExplorer` swap).

  A `t:Platform.Chat.canvas_group/0` map, built here rather than through
  `Chat.list_canvas_groups/2` on purpose: that function is a bounded,
  paged DATABASE query built for `ChatLive`'s MANY-space drawer, and this
  LiveView already holds the meeting's full, live-kept `:meeting_canvases`
  list in memory (kept in step by its own PubSub subscriptions, not by
  `ChatHooks.put/2`) — querying again would be a second, redundant source
  of truth for data already on the socket. `offset`/`take` here is the
  in-memory equivalent of that query's own `:limit`/`:offset`, paired with
  `@canvas_explorer_page_size` the same way `ChatLive.CanvasHooks` pairs
  its own query limit with the component's page size.

  `space_name: "This meeting"` rather than the chat space's own row name:
  a meeting's bound chat space is an internal implementation detail the
  viewer has never seen named, and the component always needs SOME label
  for its one group header.

  Row order is NOT re-sorted — `canvases` keeps `:meeting_canvases`' own
  oldest-first order (`Chat.list_canvases/1`), the same order the old
  `<details>` list rendered in, and the order `resolve_meeting_canvas/2`
  relies on (`List.last/1` for "most recently created").
  """
  @spec meeting_canvas_explorer_group([Canvas.t()], binary() | nil, non_neg_integer()) ::
          Chat.canvas_group()
  def meeting_canvas_explorer_group(canvases, space_id, offset) do
    %{
      space_id: space_id || "",
      space_name: "This meeting",
      total_count: length(canvases),
      rows:
        canvases
        |> Enum.drop(offset)
        |> Enum.take(@canvas_explorer_page_size)
        |> Enum.map(&canvas_explorer_row/1),
      offset: offset
    }
  end

  # `t:Platform.Chat.canvas_group_row/0`'s exact key set, off a live
  # `%Canvas{}` rather than a second query — see the group builder's own
  # doc. `Map.take/2` rather than a literal `%{}` so a future field added to
  # BOTH the struct and the type is picked up without this drifting, and a
  # field REMOVED from the struct fails loudly (`KeyError`) rather than
  # silently handing the explorer a row one key short.
  @explorer_row_keys [
    :id,
    :title,
    :space_id,
    :updated_at,
    :inserted_at,
    :cloned_from,
    :created_by_display_name
  ]

  defp canvas_explorer_row(canvas), do: Map.take(canvas, @explorer_row_keys)

  @doc """
  Ids of this meeting's own canvases the viewer has not seen change —
  exactly the set `CanvasExplorer`'s own `changed_ids` attr wants, derived
  from `canvas_changed?/3` rather than a second rule: the picker's dot and
  the stage-mode button's dot (`any_canvas_changed?/1`) must never be able
  to disagree about which canvases carry news.
  """
  @spec meeting_canvas_changed_ids(map(), [Canvas.t()], Canvas.t() | map() | nil) :: [binary()]
  def meeting_canvas_changed_ids(seen, canvases, shown) do
    canvases
    |> Enum.filter(&canvas_changed?(seen, &1, shown))
    |> Enum.map(& &1.id)
  end

  @doc """
  Does ANY canvas in the picker carry unseen news?

  Drives the subtle dot on the stage-mode Canvas button, so a viewer
  whose eyes are on the gallery grid — where the picker is not rendered
  at all — still gets a signal that there is something to go and look
  at. Without it the entire signal would be invisible from three of the
  four stage modes.
  """
  @spec any_canvas_changed?(map()) :: boolean()
  def any_canvas_changed?(assigns) when is_map(assigns) do
    seen = assigns[:canvas_seen_revisions] || %{}
    shown = canvas_tile_canvas(assigns)

    Enum.any?(assigns[:meeting_canvases] || [], &canvas_changed?(seen, &1, shown))
  end

  def any_canvas_changed?(_), do: false

  @doc """
  The canvas to render, given the loaded set and the viewer's pick.

  An explicit `selected_id` wins, but ONLY while it still resolves to a
  live canvas: a canvas can be deleted out from under a viewer who
  picked it, and falling back to the default is better than rendering
  the empty state at someone whose canvas merely went away. A stale
  selection is therefore ignored rather than honoured — but it is NOT
  cleared, because the row can come back and re-clearing on every
  resolve would silently discard a pick during a transient miss.
  """
  @spec resolve_meeting_canvas([Canvas.t()], String.t() | nil) :: Canvas.t() | nil
  def resolve_meeting_canvas(canvases, selected_id)

  def resolve_meeting_canvas(canvases, nil), do: default_canvas(canvases)

  def resolve_meeting_canvas(canvases, selected_id) when is_binary(selected_id) do
    Enum.find(canvases, fn c -> c.id == selected_id end) || default_canvas(canvases)
  end

  def resolve_meeting_canvas(canvases, _), do: default_canvas(canvases)

  # Strict "newer than" comparison for two %Canvas{} structs. Falls back
  # to id-comparison when timestamps tie (extremely unlikely with µs
  # precision, but the comparison must be total to avoid flapping).
  defp newer?(%{inserted_at: a, id: a_id}, %{inserted_at: b, id: b_id}) do
    case DateTime.compare(a, b) do
      :gt -> true
      :lt -> false
      :eq -> a_id > b_id
    end
  end

  defp newer?(_, _), do: false

  # Look up the existing participant row for `user_id` in `space_id`,
  # returning `nil` if no such row exists. Read-only: this no longer
  # inserts on miss (canvas creation is NOT a join trigger; the meeting
  # bar / livekit hook owns the explicit join in a sibling stage).
  # ── Whiteboard helpers (task 019fcfcf stage 4) ───────────────────────────

  # On a stale version we do NOT write and we do NOT send the winner's
  # scene down. The client keeps its elements and shows a notice. The
  # second saver is told; they are never silently clobbered.
  defp save_whiteboard_scene(socket, meeting, user_id, scene, expected) do
    case Meetings.upsert_whiteboard_scene(meeting.id, user_id, scene, expected) do
      {:ok, whiteboard} ->
        {:noreply,
         socket
         |> assign(:whiteboard_version, whiteboard.scene_version)
         |> assign(:whiteboard_remote_version, nil)
         |> push_event("whiteboard_saved", %{scene_version: whiteboard.scene_version})}

      {:error, :stale_version, current} ->
        # Deliberately NO badge assign here. The hook draws its own notice on
        # `whiteboard_stale` — "your save was refused, keep drawing or save a
        # copy" — which is strictly more informative than the passive "updated
        # by someone else" badge, and both were rendering at `top-0` of the
        # same overlay, one on top of the other. One event, one message.
        # `:whiteboard_remote_version` is cleared for the same reason: if the
        # badge was already up, the notice now supersedes it.
        {:noreply,
         socket
         |> assign(:whiteboard_remote_version, nil)
         |> push_event("whiteboard_stale", %{scene_version: current.scene_version})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't save the whiteboard.")}
    end
  end

  # ── Whiteboard → canvas export helpers (task 019fcfcf stage 5) ───────────

  defp reserve_whiteboard_export(socket, meeting, user_id, png_size, json_size) do
    space_id = meeting.chat_space_id
    context = %{user_id: user_id}
    slug = whiteboard_export_slug(meeting)

    with {:ok, png} <-
           AttachmentHandlers.upload_start(
             %{
               "space_id" => space_id,
               "filename" => "#{slug}.png",
               "content_type" => "image/png",
               "byte_size" => png_size
             },
             context
           ),
         {:ok, json} <-
           AttachmentHandlers.upload_start(
             %{
               "space_id" => space_id,
               "filename" => "#{slug}#{whiteboard_scene_extension()}",
               "content_type" => "application/json",
               "byte_size" => json_size
             },
             context
           ) do
      pending = %{
        png: %{id: png.id, url: png.url},
        json: %{id: json.id, url: json.url}
      }

      {:noreply,
       socket
       |> assign(:whiteboard_export_pending, pending)
       |> push_event("whiteboard_export_reserved", %{
         png: %{id: png.id, upload_url: png.upload_url},
         json: %{id: json.id, upload_url: json.upload_url}
       })}
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't prepare the whiteboard export.")}
    end
  end

  # The `.excalidraw` extension is built rather than written as a literal so
  # `grep` over lib/ does not suggest the server knows the format — it does
  # not. The server never parses the scene; it stores bytes and links them.
  defp whiteboard_scene_extension, do: ".excalidraw"

  defp whiteboard_export_slug(meeting) do
    meeting.name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "whiteboard"
      slug -> "#{slug}-whiteboard"
    end
  end

  defp write_whiteboard_canvas_card(socket, meeting, user_id, pending) do
    with {:ok, canvas} <- whiteboard_target_canvas(socket, meeting, user_id),
         {:ok, canvas} <-
           Chat.patch_canvas({:user, user_id}, canvas, [
             {:append_child, "root", whiteboard_canvas_card(meeting, pending)}
           ]) do
      {:noreply,
       socket
       |> assign(:meeting_canvas, canvas)
       |> assign(:whiteboard_export_pending, nil)
       |> put_flash(:info, "Whiteboard sent to the meeting canvas.")}
    else
      _ ->
        {:noreply,
         socket
         |> assign(:whiteboard_export_pending, nil)
         |> put_flash(:error, "Couldn't add the whiteboard to the canvas.")}
    end
  end

  # Reuse the meeting's canvas if it has one; otherwise mint one exactly the
  # way the "create a canvas" CTA does, so a board exported into a meeting
  # with no canvas yet does not need a second click.
  defp whiteboard_target_canvas(socket, meeting, user_id) do
    case socket.assigns[:meeting_canvas] || latest_canvas(meeting.chat_space_id) do
      %{} = canvas ->
        {:ok, canvas}

      nil ->
        with %{} = participant <- find_participant(meeting.chat_space_id, user_id),
             {:ok, canvas, _message} <-
               Chat.create_canvas_with_message(meeting.chat_space_id, participant.id, %{
                 "title" => "#{meeting.name} canvas"
               }) do
          {:ok, canvas}
        else
          _ -> {:error, :no_canvas}
        end
    end
  end

  # One card per export. `src` is the URL `upload_start` returned verbatim —
  # never constructed here and never taken from the client, because
  # `Platform.Chat.Canvas.Kinds.Image` rejects anything that is not exactly
  # `/chat/attachments/<uuid>` and that guard is the last line of defence.
  defp whiteboard_canvas_card(meeting, pending) do
    base = "whiteboard-export-#{pending.png.id}"
    title = "#{meeting.name} whiteboard"

    %{
      "id" => base,
      "type" => "card",
      "props" => %{"variant" => "outlined"},
      "children" => [
        %{
          "id" => "#{base}-heading",
          "type" => "heading",
          "props" => %{"value" => title, "level" => 3}
        },
        %{
          "id" => "#{base}-image",
          "type" => "image",
          "props" => %{"src" => pending.png.url, "alt" => title}
        },
        %{
          "id" => "#{base}-scene",
          "type" => "markdown",
          "props" => %{
            "content" =>
              "[Editable scene file](#{pending.json.url}) — download and reopen it to keep drawing."
          }
        }
      ]
    }
  end

  defp whiteboard_for_this_meeting?(socket, meeting_id) do
    case socket.assigns[:meeting] do
      %{id: ^meeting_id} -> true
      _ -> false
    end
  end

  defp find_participant(space_id, user_id) do
    space_id
    |> Chat.list_participants()
    |> Enum.find(fn p -> p.participant_type == "user" and p.participant_id == user_id end)
  end

  # ── Gallery-mode helpers ─────────────────────────────────────────────────
  #
  # Gallery mode lays out one tile per human participant in a responsive
  # grid (the bottom strip's tile component, reused). Agent participants
  # are intentionally excluded — Gallery is a face-grid, and agents have
  # no camera. They're surfaced in the bottom strip's right-hand section
  # via `<.agent_tile>` (sibling task 019e2475-0037), not here.

  @doc """
  Filter participants to the human (`participant_type == "user"`) subset
  that the Gallery mode renders. Public for tests + heex consumers.
  """
  def gallery_participants(participants), do: gallery_participants(participants, MapSet.new())

  @doc """
  Gallery roster, widened by the viewer's ACTIVE SPEAKER set.

  Humans are always in the grid. An agent is in the grid only while its
  identity (`"agent:" <> participant_id`) is in `speaking_identities` —
  the target design's commitment that "an agent grows into a tile only
  while speaking". When it stops speaking it falls out of this list and
  is rendered by the bottom agent dock again.

  `speaking_identities` is viewer-local (see the `active_speakers`
  handler); the arity-1 clause above is the "nobody speaking" case and is
  what non-gallery callers and older tests get.
  """
  def gallery_participants(participants, speaking_identities) when is_list(participants) do
    speaking = speaking_identities || MapSet.new()

    Enum.filter(participants, fn
      %{participant_type: "user"} ->
        true

      %{participant_type: "agent"} = agent ->
        MapSet.member?(speaking, agent_gallery_identity(agent))

      _ ->
        false
    end)
  end

  def gallery_participants(_, _), do: []

  @doc """
  LiveKit identity for an agent participant: `"agent:" <> participant_id`.

  Deliberately a named function rather than an inline string concat at the
  three call sites (gallery filter, dock tile, promoted grid tile) — the
  promotion only works if all three spell the identity identically.
  """
  def agent_gallery_identity(%{participant_id: pid}) when is_binary(pid) and pid != "",
    do: "agent:" <> pid

  def agent_gallery_identity(_), do: "agent:"

  @doc """
  True when a gallery roster entry is a promoted AGENT rather than a human.

  Only ever true for entries `gallery_participants/2` admitted, i.e. an
  agent that is currently speaking.
  """
  def agent_participant?(%{participant_type: "agent"}), do: true
  def agent_participant?(_), do: false

  @doc """
  The canvas the meeting's canvas TILE displays, or `nil` when the
  meeting has no canvas at all.

  Deliberately a named seam rather than reading `:meeting_canvas` at the
  call sites: the tile and the canvas view happen to share a source
  today, and a later stage gives the view a per-session selection. When
  that lands, only this function moves.

  `nil` is load-bearing: with no canvas the tile must not render at all,
  and the canvas view's "No canvas yet" CTA stays the only canvas
  affordance in the meeting.
  """
  def canvas_tile_canvas(assigns) when is_map(assigns), do: assigns[:meeting_canvas]
  def canvas_tile_canvas(_), do: nil

  @doc """
  Number of CELLS the gallery grid lays out: one per gallery participant,
  plus one for the canvas tile when the meeting has a canvas.

  This exists so the canvas tile can influence the grid SHAPE without
  being laundered through the participant list. The tile is a UI slot,
  not a roster entry — appending a fake participant so the arithmetic
  came out right would put it in reach of every roster query in the
  module (`gallery_participants/1`, `strip_humans/1`, `strip_agents/1`)
  and reproduce the synthetic-participant scars the component moduledoc
  documents. Counting cells is the honest statement of what the grid
  needs to know.
  """
  @spec gallery_cell_count(non_neg_integer(), boolean()) :: non_neg_integer()
  def gallery_cell_count(participant_count, canvas_tile?)
      when is_integer(participant_count) and participant_count >= 0 do
    participant_count + if canvas_tile?, do: 1, else: 0
  end

  @doc """
  Stable LiveKit-style identity key for a participant tile, mirroring the
  `"user:" <> participant_id` convention used by sibling member 4's bottom
  strip. Keeping the format identical means the same JS hook
  (`MeetingVideoTile`) will find a single track per identity regardless of
  whether the bottom-strip tile or the gallery-mode tile mounts first.
  """
  # Explicit LiveKit identity wins when present. Written into view-model
  # maps by `meeting_participant_view_model/1` from
  # `p.metadata["identity"]`. Guests carry `"guest:<random>"` here; auth
  # rows carry `"user:<uuid>"` (byte-identical to the historical
  # `"user:" <> participant_id` fallback). See task 019f498d re-dispatch
  # notes on why guest tiles must render with the LiveKit-side identity
  # so MeetingVideoTile's `data-participant` attribute matches the
  # remote participant's `identity` field.
  def gallery_identity(%{identity: identity}) when is_binary(identity) and identity != "",
    do: identity

  def gallery_identity(%{participant_id: pid}) when is_binary(pid) and pid != "",
    do: "user:" <> pid

  def gallery_identity(%{id: id}) when is_binary(id) and id != "", do: "user:" <> id
  def gallery_identity(_), do: "user:unknown"

  @doc """
  Column count (Tailwind class string) for `count` gallery cells.

  Task 01a05b14 stage 3 replaced the previous shape table. That table
  paired an explicit `grid-cols-N grid-rows-M` with a per-TILE 16:9
  binding and `place-items-center`, which is what produced the layout
  the sponsor rejected: at two participants on a 744px stage the grid
  measured 520px wide and the tiles floated as a centred column with
  224px of dead margin either side.

  Now the CELL owns the aspect and the tile fills it (`object-cover`),
  so the only thing the shape has to say is how many columns:

    1      -> grid-cols-1
    2..4   -> grid-cols-2
    5..9   -> grid-cols-3
    10+    -> grid-cols-4

  Rows come from `auto-rows-fr`, which partitions the stage height
  evenly across however many rows the column count implies — so the grid
  fills the stage on BOTH axes with no explicit row class to keep in
  sync. There is deliberately no `sm:` prefix: the mockup's 2x2 is the
  layout at every width, and stretched cells stay legible at 390px in a
  way the old width-bound 16:9 thumbnails did not.

  Classes are literal strings in the function bodies so Tailwind's
  scanner sees them. Don't switch to interpolation like
  `"grid-cols-\#{n}"` — that goes invisible to the JIT.
  """
  @spec gallery_grid_class(non_neg_integer()) :: String.t()
  def gallery_grid_class(count)
  def gallery_grid_class(0), do: "grid-cols-1"
  def gallery_grid_class(1), do: "grid-cols-1"
  def gallery_grid_class(n) when n in 2..4, do: "grid-cols-2"
  def gallery_grid_class(n) when n in 5..9, do: "grid-cols-3"
  def gallery_grid_class(_n), do: "grid-cols-4"

  @doc """
  True when the grid should render a GHOST cell — a dimmed, empty cell
  that completes the 2x2 block the mockup draws.

  Only at exactly three cells. Three cells in a two-column grid leaves a
  visibly ragged hole; the mockup fills it with a 30%-opacity outline so
  the stage reads as a call rather than as three floating cards. Every
  other count is either already rectangular (1, 2, 4) or lives in a
  three/four-column grid where "one ghost per empty slot" would paint up
  to six dead boxes — which is emphatically NOT what the drawing shows,
  so the rule stays pinned to 3 rather than generalised to
  `rem(count, cols)`.
  """
  @spec gallery_ghost_cell?(non_neg_integer()) :: boolean()
  def gallery_ghost_cell?(count) when is_integer(count), do: count == 3

  @doc """
  Chrome-aware variant of `gallery_grid_class/1`.

  Kept as a distinct arity because every call site passes a chrome mode,
  but the shape no longer diverges: since task 01a05b14 stage 3 the cells
  STRETCH to fill the stage on both surfaces, so the guest surface's old
  side-by-side special-cases for 2 and 3 (which existed only to reclaim
  width the stacked shell layout wasted) are exactly what the shared
  column rule now does anyway.
  """
  @spec gallery_grid_class(non_neg_integer(), :shell | :none) :: String.t()
  def gallery_grid_class(count, _chrome_mode), do: gallery_grid_class(count)

  # ── Participant rail helpers (task 019e2475-4395) ────────────────────────
  #
  # Used by `PlatformWeb.Components.Meetings.ParticipantRail` to drive the
  # left-rail sectioned participant list (humans on top, agents below).

  @doc """
  Split participants into `{humans, agents}` lists by `participant_type`.
  """
  @spec partition_participants([Platform.Chat.Participant.t()]) ::
          {[Platform.Chat.Participant.t()], [Platform.Chat.Participant.t()]}
  def partition_participants(participants) do
    Enum.split_with(participants, &(&1.participant_type == "user"))
  end

  @doc """
  `{people, agents}` counts for the top bar's `N people · M agents`
  readout (task 01a05b14 stage 5).

  Derived from `partition_participants/1` — the SAME split
  `ParticipantRail` renders its two sections from — rather than from a
  second predicate, so the number in the bar and the rows in the rail
  cannot disagree: whatever the rail files under "In this call" is a
  person here, and whatever it files under "Agents" is an agent.
  """
  @spec roster_count([map()]) :: {non_neg_integer(), non_neg_integer()}
  def roster_count(participants) do
    {humans, agents} = partition_participants(participants)
    {length(humans), length(agents)}
  end

  @doc """
  The bar's readout for one `{people, agents}` pair, pluralised —
  "1 person · 2 agents", "3 people · 1 agent". The approved target draws
  `3 people · 4 agents`; a bar that said "1 people" would be the kind of
  thing a sponsor notices first.
  """
  @spec roster_label({non_neg_integer(), non_neg_integer()}) :: String.t()
  def roster_label({people, agents}) do
    "#{count_noun(people, "person", "people")} · #{count_noun(agents, "agent", "agents")}"
  end

  defp count_noun(1, singular, _plural), do: "1 #{singular}"
  defp count_noun(n, _singular, plural), do: "#{n} #{plural}"

  # The top bar's `N people · M agents` readout (approved target embed 1
  # `.mini`: 11px, muted). A function component and NOT a LiveComponent,
  # for the reason `CallShell`'s moduledoc gives: a hook `pushEvent`
  # ignores `phx-target`, and this bar hosts `MeetingShareButton`'s
  # neighbour, so nothing here may move into its own target.
  #
  # `hidden sm:flex`, MEASURED (stage 5, 390x844): with the pill and this
  # readout both in the bar the meeting name collapsed from its full
  # 53px to 7px, and no re-weighting recovers it — at `basis-[80%]` the
  # title still gets 26px. Something yields below `sm`, and it is this:
  # a count is information, not state, and the same two numbers are
  # one tap away as the drawer's "In this call" and "Agents" lists. The
  # pill stays at every width because "live" IS state, and this bar
  # never hides state on a phone (see the mute-badge note in the
  # template). The full sentence is in `title` for hover.
  attr(:participants, :list, required: true)

  defp roster_readout(assigns) do
    {people, agents} = roster_count(assigns.participants)

    assigns =
      assigns
      |> assign(:people, people)
      |> assign(:agents, agents)
      |> assign(:label, roster_label({people, agents}))

    ~H"""
    <span
      class="hidden flex-shrink-0 items-center whitespace-nowrap text-[11px] text-base-content/50 sm:flex"
      data-role="meeting-roster-count"
      data-people={@people}
      data-agents={@agents}
      title={@label}
    >
      {@label}
    </span>
    """
  end

  @doc """
  Display string for an agent participant's role chip. Reads
  `agent.metadata["role"]` when present; falls back to `"agent"`.
  """
  @spec agent_role_chip(Platform.Chat.Participant.t(), %{binary() => Agent.t()}) :: String.t()
  def agent_role_chip(%{participant_type: "agent", participant_id: agent_id}, agents_by_id) do
    case Map.get(agents_by_id, agent_id) do
      %Agent{metadata: %{"role" => role}} when is_binary(role) and role != "" -> role
      _ -> "agent"
    end
  end

  def agent_role_chip(_p, _agents_by_id), do: "agent"

  @doc """
  Status-dot tone class for an agent participant (task 01a04a98).

  Reads THIS MEETING's activity first. The `agents.status` column is a
  global, org-wide field — an agent seated in four meetings has one
  value of it — so it can never answer "is this agent working here",
  and until this task it was the only thing the dot read. It survives
  as the OFFLINE fallback and nothing more:

    * doing something in this meeting -> `bg-success`
    * idle here, but a live agent row -> `bg-warning`
    * no agent row, or `archived`     -> `bg-base-content/30`

  `bg-success` is now reachable ONLY through the first branch, which is
  what makes "globally active, idle in this meeting" render honestly.
  Note the guest surface passes `agents_by_id: %{}` — a computing agent
  still goes green there, because activity is decided before the map is
  consulted.
  """
  @spec agent_status_dot_class(
          Platform.Chat.Participant.t(),
          %{binary() => Agent.t()},
          AgentActivity.t() | %{binary() => atom()} | nil
        ) :: String.t()
  def agent_status_dot_class(participant, agents_by_id, activity \\ nil)

  def agent_status_dot_class(
        %{participant_type: "agent", participant_id: agent_id},
        agents_by_id,
        activity
      ) do
    cond do
      AgentActivity.for_agent(activity, agent_id) != :idle ->
        "bg-success"

      match?(
        %Agent{status: status} when status in ["active", "paused"],
        Map.get(agents_by_id, agent_id)
      ) ->
        "bg-warning"

      true ->
        "bg-base-content/30"
    end
  end

  def agent_status_dot_class(_p, _agents_by_id, _activity), do: "bg-base-content/30"

  @doc """
  True when this participant is the meeting's host. Safe with `nil`
  `host_participant_id`.
  """
  @spec host?(Platform.Chat.Participant.t(), Platform.Meetings.Meeting.t()) :: boolean()
  def host?(_participant, %{host_participant_id: nil}), do: false

  def host?(%{id: id}, %{host_participant_id: host_id}) when is_binary(host_id) do
    id == host_id
  end

  def host?(_participant, _meeting), do: false

  @doc """
  True when this participant joined via a guest invite link.

  `Platform.Meetings.guest_livekit_token/2` mints the LiveKit identity
  with a `" (guest)"` suffix on the display_name (see `meetings.ex:1269`)
  so downstream surfaces can distinguish invited guests from
  account-holding humans without needing a separate flag on the
  participant row. The rail's sub-line rendering reads this predicate.
  """
  @spec via_guest_link?(map()) :: boolean()
  def via_guest_link?(%{display_name: display_name}) when is_binary(display_name),
    do: String.ends_with?(display_name, " (guest)")

  def via_guest_link?(_participant), do: false

  @doc """
  The `activity_state` for an agent participant's bottom-strip tile.

  Replaces the `activity_state={:idle}` LITERAL that was this
  component's only non-test call site. `participant.participant_id` is
  the `agents.id` the intent queue targets and the typing bridge
  resolves to, so the key needs no translation here.

  Human participants resolve `:idle`: `<.agent_tile>` is only rendered
  for the agent subset, and this returning anything else for a human
  would mean the strip had been mis-partitioned.
  """
  @spec agent_activity_state(map(), AgentActivity.t() | %{binary() => atom()} | nil) ::
          AgentActivity.state()
  def agent_activity_state(%{participant_type: "agent", participant_id: agent_id}, activity),
    do: AgentActivity.for_agent(activity, agent_id)

  def agent_activity_state(_participant, _activity), do: :idle

  # ── Bottom-strip helpers (task 019e2475-0037) ────────────────────────────
  #
  # The bottom strip composes `<.video_tile>` for human participants on the
  # left and `<.agent_tile>` for agent participants on the right.

  @doc "Filter participants to the human (`user`) subset for the bottom strip."
  def strip_humans(participants) when is_list(participants) do
    Enum.filter(participants, fn
      %{participant_type: "user"} -> true
      _ -> false
    end)
  end

  def strip_humans(_), do: []

  @doc """
  Resolve the local viewer's participant row for the persistent self-view
  anchor (task 019e42f6).

  The self-view is an always-on picture-in-picture tile that lives OUTSIDE
  the mode-switched center-stage / bottom-strip subtrees and carries
  `phx-update="ignore"`, so LiveView never destroys/recreates it on a
  `set_stage_mode` patch. That stable DOM node — combined with the
  single-element `track.detach(element)` fix in `MeetingVideoTile` — is what
  guarantees the local camera survives mode switches instead of going black.

  Returns the matching human participant map, or `nil` when the viewer has
  no participant row yet (render nothing). Matching `@current_participant`
  by `participant_id` keeps the self-view identity aligned with the
  gallery/strip tiles via `gallery_identity/1`.
  """
  def local_self_view_participant(%{participant_id: pid} = participant)
      when is_binary(pid) and pid != "",
      do: participant

  def local_self_view_participant(_), do: nil

  @doc """
  Guest-aware self-view resolver (task 019f498d re-dispatch).

  Auth surface: identical to `local_self_view_participant/1` — falls back
  to the `@current_participant`-driven behavior.

  Guest surface (`@chrome_mode == :none and @state == :in_meeting`): the
  guest has no `Chat.Participant` row (they are not a Suite user), but
  they DO carry a LiveKit identity + display name from
  `mint_guest_join_bundle/2`. Return a synthetic participant map keyed
  on the LiveKit identity so the persistent `#meeting-local-self-view`
  parking slot renders and MeetingClient has somewhere to dock the local
  <video> element. Fields mirror the shape the participant-tile heex
  reads (see `gallery_identity/1` and `meeting_participant_view_model/1`).
  """
  def local_self_view_participant(current_participant, guest_mode?, display_name, identity)

  def local_self_view_participant(%{participant_id: pid} = participant, _, _, _)
      when is_binary(pid) and pid != "",
      do: participant

  def local_self_view_participant(_, true, display_name, identity)
      when is_binary(display_name) and is_binary(identity) and identity != "" do
    %{
      id: identity,
      participant_id: nil,
      participant_type: "user",
      display_name: display_name,
      avatar_url: nil,
      identity: identity,
      attention_config: %{}
    }
  end

  def local_self_view_participant(_, _, _, _), do: nil

  @doc """
  Return the LiveKit-shape identity string for the LOCAL viewer of a
  MeetingLive session — the identity `data-participant` on a rendered
  tile must match for the JS hooks to treat that tile as the local
  participant (task 019f498d re-dispatch).

  * Auth mount: `gallery_identity(@current_participant)` — same string
    the old inline expression in `meeting_live.html.heex` computed.
  * Guest mount (`@chrome_mode == :none and @state == :in_meeting`):
    `@identity` from the minted bundle (e.g. `"guest:<random>"`).
  * Everything else: sentinel `"user:unknown"` (matches the historic
    `gallery_identity(nil)` fallback so no per-iteration tile matches).
  """
  def viewer_gallery_identity(assigns) when is_map(assigns) do
    case assigns[:current_participant] do
      %{participant_id: pid} = p when is_binary(pid) and pid != "" ->
        gallery_identity(p)

      _ ->
        cond do
          assigns[:chrome_mode] == :none and assigns[:state] == :in_meeting and
              is_binary(assigns[:identity]) ->
            assigns[:identity]

          true ->
            "user:unknown"
        end
    end
  end

  @doc """
  The set of identities the ROSTER should draw as off, given the
  SFU-reported set plus the viewer's own local state.

  `room.remoteParticipants` excludes the local participant by
  construction, so `:muted_identities` and `:camera_off_identities` can
  never contain the viewer — but the roster lists the viewer like anyone
  else, and their own row is the one they look at most. Without this
  fold, a viewer who mutes themselves watches every other row tell the
  truth while their own says "unmuted". That is the same class of defect
  task 01a0740c exists to remove, so the rail folds the local booleans
  (`:mic_enabled` / `:camera_enabled`, driven by the viewer's own
  buttons) into the set it renders.

  `"user:unknown"` is `gallery_identity/1`'s fallback for a participant
  it cannot key and `viewer_gallery_identity/1`'s fallback for a viewer
  it cannot resolve, so folding on it could mark an unrelated row. It is
  treated as "no viewer identity" instead.
  """
  @spec roster_off_set(MapSet.t(), String.t() | nil, boolean()) :: MapSet.t()
  def roster_off_set(remote_set, viewer_identity, viewer_on?)

  def roster_off_set(remote_set, identity, _on?)
      when not is_binary(identity) or identity == "" or identity == "user:unknown",
      do: remote_set

  def roster_off_set(remote_set, identity, true), do: MapSet.delete(remote_set, identity)
  def roster_off_set(remote_set, identity, _off), do: MapSet.put(remote_set, identity)

  @doc "Filter participants to the agent subset for the bottom strip."
  def strip_agents(participants) when is_list(participants) do
    Enum.filter(participants, fn
      %{participant_type: "agent"} -> true
      _ -> false
    end)
  end

  def strip_agents(_), do: []

  @doc """
  Role label for an agent participant. Reads `attention_config["role"]`
  when present; returns `nil` otherwise (the tile renders `"agent"` as
  fallback).
  """
  def agent_role(%{attention_config: %{"role" => role}}) when is_binary(role) and role != "",
    do: role

  def agent_role(_participant), do: nil
end
