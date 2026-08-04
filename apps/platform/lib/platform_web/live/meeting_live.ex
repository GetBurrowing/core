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

  ## Mobile drawer (sibling 019e2475-87a8 stage 3)

  The right pane has two presentations:

    * `>=lg` (desktop): always-visible right column. The desktop column
      is rendered with `hidden lg:flex` and **does not consult the
      `:chat_panel_open` assign**, so the panel is never collapsed on
      desktop regardless of assign state.
    * `<lg` (mobile/tablet): a slide-in drawer from the right with a
      backdrop. The drawer reads `:chat_panel_open` and is hidden by
      default (assign defaults to `false`).

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
    * `:meeting_canvas` — the most-recently-created canvas in the
      meeting's chat space, or `nil`. Canvas mode renders this.
    * `:user_id` — authenticated user_id off the session (same pattern
      as ChatLive); used as the canvas-creator participant when the
      Canvas-mode "Create canvas" CTA fires.
    * `:chat_panel_open` — mobile drawer open-state for the sibling's
      embedded chat panel.
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
      `:name_entry`, `:in_meeting`. Absent in the shell path; the heex
      cond in stage 4 branches on `chrome_mode == :none and state == …`
      to render the guest sub-surfaces.

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
  import PlatformWeb.Components.Meeting.VideoTile, only: [video_tile: 1]

  import PlatformWeb.Components.Meetings.IntentsCollapse,
    only: [intents_collapse: 1, intents_overlays: 1]

  import PlatformWeb.Components.Meetings.ParticipantRail, only: [participant_rail: 1]

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings
  alias Platform.Meetings.Archive
  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks
  alias PlatformWeb.ChatLive.MeetingHooks
  alias PlatformWeb.Components.Meetings.IntentsCollapse
  alias PlatformWeb.MeetingLive.CalendarWindow

  # The role that may see and drive the intents-collapse bar. Passed to
  # `Platform.Roles.agent_id_for_role/1` as a STRING — that function is
  # guarded `when is_binary(role_key)` and an atom raises
  # FunctionClauseError.
  @intent_producer_role "meeting_producer"

  # The eight per-meeting intent-queue events. Every one carries the FULL
  # row map, so a subscriber can render without a second lookup.
  @intent_events [
    :intent_classified,
    :intent_dispatched,
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

  @doc "The eight per-meeting intent-queue event names the LV handles."
  def intent_events, do: @intent_events

  # Stage modes per ADR 0042's "Stage modes" table. Canvas is the default
  # (meetings are often artifact-driven).
  @stage_modes [:canvas, :screen, :gallery, :whiteboard]

  @doc "Stage modes the segmented control exposes (ADR 0042)."
  def stage_modes, do: @stage_modes

  @impl true
  # Guest ingress mount (task 019f498d stage 3, wired to the real route
  # in stage 5). The `:guest_meeting` live_session on the `meet.` host
  # scope injects `chrome_mode: "none"` into the session; the guest URL
  # carries `slug` + `token` in the path. This clause resolves the invite
  # through `Meetings.resolve_guest_invite/2` (extracted in stage 2) and
  # lands one of four states: `:expired`, `:invalid`, `:name_entry`, or
  # `:in_meeting`.
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
      |> assign(:user_id, nil)
      |> assign(:chrome_mode, :none)
      |> assign(:shell?, false)
      |> assign(:stage_modes, @stage_modes)
      |> assign(:chat_panel_open, false)
      |> assign(:participant_rail_collapsed, false)
      |> assign(:chat_panel_collapsed, false)
      |> assign(:captions_visible, false)
      |> seed_intent_assigns()
      |> assign_calendar_time_zone()
      |> assign(:meeting_slug, slug)
      |> assign(:token, token)

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

  # Seed the index-mode defaults so the current heex (which falls through
  # to the `:else` index branch when `@meeting == nil`) doesn't crash
  # on a bare guest failure state. Stage 4 will add a `:state`-branch cond
  # so `:expired` / `:invalid` render their own cards and this fallback
  # becomes dead code — but keeping it lets stage 3 land as a compilable,
  # renderable-without-crash unit even before stage 4 lands. Values are
  # empty defaults; no data leaks into the guest surface's DOM.
  defp seed_guest_index_fallback_assigns(socket) do
    socket
    |> assign(:meetings, [])
    |> assign(:grouped_meetings, %{live: [], upcoming: [], ended: []})
    |> assign(:projects, [])
    |> assign(:meeting_subscribed_project_ids, [])
    |> assign(:show_start_meeting_sheet, false)
    |> assign(:start_meeting_form, blank_start_meeting_form([]))
    |> assign(:start_meeting_error, nil)
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
    |> assign(:participants, participants)
    |> assign(:agents_by_id, %{})
    |> assign(:speaking_participant_ids, MapSet.new())
    |> assign(:meeting_canvas, latest_canvas(meeting.chat_space_id))
    |> assign(:current_stage_mode, :gallery)
    |> assign(:active_space, meeting.chat_space)
    |> assign(:current_participant, nil)
    |> MeetingHooks.attach_guest()
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
     |> assign(:display_name, nil)
     # Mobile drawer state — defaults CLOSED. Desktop ignores this
     # assign (column is `hidden lg:flex`). See @moduledoc for the
     # reconciliation against the stack-spec's "defaults to true" line.
     |> assign(:chat_panel_open, false)
     # Desktop collapse state for the participant rail + chat pane
     # (task 019e40f2). These are ORTHOGONAL to `:chat_panel_open`:
     # `:chat_panel_open` is mobile-drawer (<lg), the new
     # `:chat_panel_collapsed` flips the desktop chat aside between
     # the wide (~320px) pane and a slim 48px collapsed rail. Same
     # default-expanded posture as `:sidebar_collapsed` in
     # `shell_live.ex` — first-time users see the full layout. The
     # `SidebarCollapse` JS hook (parameterized via `data-*` attrs in
     # stage 3) hydrates from localStorage so the preference survives
     # navigation + reload.
     |> assign(:participant_rail_collapsed, false)
     |> assign(:chat_panel_collapsed, false)
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
     # Intents-collapse bar defaults (task 019f70b8 stage 7). Seeded in
     # BOTH mount clauses so the `:index` action and the guest surface
     # render without a KeyError even though neither shows the bar.
     # `handle_params/3` resolves the real values for the `:show` action.
     |> seed_intent_assigns()
     |> assign_calendar_time_zone()}
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
  defp assign_calendar_time_zone(socket) do
    time_zone =
      socket
      |> get_connect_params()
      |> case do
        %{"timezone" => time_zone} -> time_zone
        _ -> nil
      end
      |> CalendarWindow.resolve_time_zone()

    assign(socket, :calendar_time_zone, time_zone)
  end

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
  end

  @impl true
  # Guest ingress (task 019f498d stage 3): the guest mount clause above
  # already resolved the invite + seeded every assign the guest states
  # need (`:state` in `[:expired, :invalid, :name_entry, :in_meeting]`).
  # handle_params is a no-op here to avoid the shell-path
  # `Meetings.fetch_meeting_for_user/2` re-lookup and MeetingHooks.attach/2
  # (which requires a binary user_id and would double-subscribe the guest
  # to per-space PubSub). Guarded on `:state` presence rather than
  # `:chrome_mode == :none` alone so the stage-1 `/_probe/:slug` smoke
  # route (chrome_mode :none, no token, no `:state`) still falls through
  # to the shell path and its `:meeting` assign lands.
  def handle_params(_params, _url, %{assigns: %{state: state}} = socket)
      when state in [:expired, :invalid, :name_entry, :in_meeting] do
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
    case Meetings.fetch_meeting_for_user(socket.assigns[:current_user_record], slug) do
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
        if connected?(socket) do
          if meeting.chat_space_id do
            ChatPubSub.subscribe(meeting.chat_space_id)
            # Live meeting presence: `broadcast_presence_change` publishes
            # `{:meeting_presence_update, …}` on this per-space topic for
            # every LiveKit join/leave, so the rail/count stay live without
            # depending on a room row existing at mount time. The granular
            # `{:participant_joined,_}`/`{:participant_left,_}` events fire on
            # the room topic (subscribed below when a room is active).
            MeetingsPubSub.subscribe_presence(meeting.chat_space_id)

            case Meetings.get_active_room(meeting.chat_space_id) do
              %{id: room_id} -> MeetingsPubSub.subscribe_room(room_id)
              _ -> :ok
            end
          end

          Phoenix.PubSub.subscribe(Platform.PubSub, meeting_topic(meeting.id))

          # Intents-collapse bar (task 019f70b8 stage 7). Subscribed
          # unconditionally rather than behind the role gate: the gate can
          # flip mid-meeting, and a subscription taken only at gate-open
          # would miss every transition between the appointment and the
          # next event. The handlers no-op when the bar is hidden.
          MeetingsPubSub.subscribe_intents(meeting.id)
          Roles.subscribe_assignments()
        end

        participants =
          if meeting.chat_space_id,
            do: build_meeting_participants(meeting.chat_space_id),
            else: []

        meeting_canvas = latest_canvas(meeting.chat_space_id)
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
          |> assign(:agents_by_id, agents_by_id)
          |> assign(:speaking_participant_ids, MapSet.new())
          |> assign(:meeting_canvas, meeting_canvas)
          |> assign(:current_stage_mode, :gallery)
          |> assign(:active_space, meeting.chat_space)
          |> assign(:current_participant, current_participant)
          # ── Intents-collapse bar (task 019f70b8 stage 7) ──────────────
          # Seeded from the LIVE queue keyed by this meeting's id — the
          # same id the classifier enqueues under. `IntentQueue.list/1`
          # returns `[]` when no owner is running, which is the correct
          # rendering for a meeting that has produced no intents yet.
          |> seed_intent_assigns()
          |> assign_intents_gate()
          |> assign(:intents, IntentQueue.list(meeting.id))
          |> MeetingHooks.attach(List.wrap(meeting.chat_space_id))

        # Auto-join on connected mount unless ?no_autojoin=true is set
        # (the e2e tests in stage 7 use that escape hatch so they can
        # assert the manual "Join" CTA path). `send(self(), :auto_join)`
        # defers the join one tick so the LV is fully mounted before
        # MeetingHooks reads `:active_space`.
        if connected?(socket) and Map.get(params, "no_autojoin") != "true" do
          send(self(), :auto_join)
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
    # TODO(scope): `list_projects/0` + `list_all_meetings/0` are unscoped —
    # this index renders every meeting in every org to every authenticated
    # user, a separate name/existence leak from the `:show` one fixed above.
    # Left out of task 019f9b14 deliberately (fixing it changes rendered
    # output); filed as its own task.
    projects = Tasks.list_projects()
    project_ids = Enum.map(projects, & &1.id)

    if connected?(socket) do
      Enum.each(project_ids, &Meetings.subscribe_to_project_meetings/1)
    end

    meetings = Meetings.list_all_meetings()
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
     # `:meetings` and `:grouped_meetings` keep their exact prior meaning:
     # `data-role="meetings-count"` and the archive sibling both read them,
     # and the calendar is an additional projection, not a replacement.
     |> assign(:meetings, meetings)
     |> assign(:grouped_meetings, grouped)
     |> assign(:meeting_subscribed_project_ids, project_ids)
     |> assign_new(:projects, fn -> projects end)
     |> assign_new(:show_start_meeting_sheet, fn -> false end)
     |> assign_new(:start_meeting_form, fn -> blank_start_meeting_form(projects) end)
     |> assign_new(:start_meeting_error, fn -> nil end)
     |> assign_new(:selected_meeting_id, fn -> nil end)
     |> assign_calendar_week(calendar_today(socket))
     |> assign_archive(params)}
  end

  # ── Calendar window (task 019fb954-8ead) ─────────────────────────────────

  # Recompute every calendar assign from one anchor date. The SINGLE path
  # by which the week's meetings are loaded: `handle_params/3` and all four
  # navigation events funnel through here, so there is exactly one range
  # query in the module and no way for a handler to drift from it.
  #
  # One query per WEEK, not seven per day: `list_meetings_in_range/3` is
  # already half-open over the same bounds `week_bounds/2` produces, and
  # the day columns are a partition of that result in memory.
  defp assign_calendar_week(socket, %Date{} = anchor, selected \\ nil) do
    time_zone = socket.assigns.calendar_time_zone
    selected = selected || anchor
    meetings = list_calendar_week_meetings(anchor, time_zone)

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
  defp list_calendar_week_meetings(_anchor, nil), do: []

  defp list_calendar_week_meetings(%Date{} = anchor, time_zone) do
    {from, to} = CalendarWindow.week_bounds(anchor, time_zone)
    Meetings.list_meetings_in_range(from, to)
  end

  defp calendar_hour_window(_meetings, nil), do: CalendarWindow.hour_window([], "Etc/UTC")

  defp calendar_hour_window(meetings, time_zone),
    do: CalendarWindow.hour_window(meetings, time_zone)

  defp schedule_calendar_tick, do: Process.send_after(self(), :calendar_tick, 60_000)

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
  def calendar_today_date(nil), do: Date.utc_today()

  def calendar_today_date(time_zone) when is_binary(time_zone),
    do: DateTime.utc_now() |> DateTime.shift_zone!(time_zone) |> DateTime.to_date()

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
  """
  @spec calendar_day_events([Meeting.t()], Date.t(), String.t() | nil, {integer(), integer()}) ::
          [{Meeting.t(), %{top: float(), height: float()}}]
  def calendar_day_events(_meetings, %Date{}, nil, _window), do: []

  def calendar_day_events(meetings, %Date{} = date, time_zone, window)
      when is_list(meetings) and is_binary(time_zone) do
    Enum.flat_map(meetings, fn meeting ->
      case CalendarWindow.place(meeting, date, time_zone, window) do
        {:ok, placement} -> [{meeting, placement}]
        :skip -> []
      end
    end)
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
  How far down the rendered hour window "now" sits, as a percentage, or
  `nil` when there is no honest answer.

  `nil` for an unresolved zone — the caller draws no line rather than a
  line in server time, which is the same call `resolve_time_zone/1`
  makes. `nil` too when the current hour falls OUTSIDE the drawn window:
  a now-line pinned to the top edge at 3 AM is not a smaller error than
  no line, it is a confident wrong one.
  """
  @spec calendar_now_offset(String.t() | nil, {integer(), integer()}) :: float() | nil
  def calendar_now_offset(nil, _window), do: nil

  def calendar_now_offset(time_zone, {first_hour, last_hour})
      when is_binary(time_zone) and last_hour > first_hour do
    now = DateTime.utc_now() |> DateTime.shift_zone!(time_zone)
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
  the same `:for` it renders everything else with, reading the clock
  exactly once per column and never on a path where the guard said no.

  Two independent reasons to draw nothing, and they are different
  reasons: this is not today's column (the line is a fact about ONE day
  — drawn across all seven it claims it is also 2:14 PM on Sunday), or
  there is no honest offset at all (see `calendar_now_offset/2`).
  """
  @spec calendar_now_line(boolean(), String.t() | nil, {integer(), integer()}) :: [float()]
  def calendar_now_line(false, _time_zone, _window), do: []

  def calendar_now_line(true, time_zone, window) do
    case calendar_now_offset(time_zone, window) do
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

  defp month_abbrev(%Date{} = date), do: Calendar.strftime(date, "%b")

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
  # `Meetings.list_all_meetings/0` is deliberately NOT the source here. It is
  # unscoped (it carries its own `TODO(scope)`), and the archive is a
  # viewer-facing search — `Archive.search/2` does the org narrowing.
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
  defp archive_chip_class(:transcript), do: "border-base-300 bg-base-200 text-base-content/60"

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
  def handle_event("toggle_chat_panel", _params, socket) do
    {:noreply, update(socket, :chat_panel_open, &(!&1))}
  end

  # Desktop participant-rail collapse (task 019e40f2). Mirrors the
  # `toggle_sidebar` shape in `shell_live.ex:236-244`: flip the assign,
  # push a `*_collapsed_changed` browser event so the SidebarCollapse JS
  # hook can mirror the value into localStorage. The matching
  # `*_hydrate` handler below adopts a stored value on mount.
  def handle_event("toggle_participant_rail", _params, socket) do
    next = !socket.assigns.participant_rail_collapsed

    {:noreply,
     socket
     |> assign(:participant_rail_collapsed, next)
     |> push_event("meeting_participant_rail_collapsed_changed", %{collapsed: next})}
  end

  def handle_event("meeting_participant_rail_hydrate", %{"collapsed" => collapsed}, socket)
      when is_boolean(collapsed) do
    # Idempotent: skip the re-render when the hook's localStorage value
    # matches the current assign.
    if collapsed == socket.assigns.participant_rail_collapsed do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :participant_rail_collapsed, collapsed)}
    end
  end

  # Desktop chat-pane collapse (task 019e40f2). Strictly DESKTOP — the
  # mobile drawer continues to use `:chat_panel_open`. Same shape as
  # `toggle_participant_rail` above.
  def handle_event("toggle_meeting_chat_pane", _params, socket) do
    next = !socket.assigns.chat_panel_collapsed

    {:noreply,
     socket
     |> assign(:chat_panel_collapsed, next)
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
        {:noreply,
         socket
         |> assign(:current_stage_mode, stage_mode)
         |> push_event("meeting_stage_mode_changed", %{mode: Atom.to_string(stage_mode)})}

      :error ->
        # Unknown mode — keep `:current_stage_mode` unchanged. No
        # FunctionClauseError, no flash; the click is simply a no-op.
        {:noreply, socket}
    end
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
                {:noreply, assign(socket, :meeting_canvas, canvas)}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, "Failed to create canvas.")}
            end
        end
    end
  end

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
        socket
        |> assign(:current_stage_mode, :screen)
        |> push_event("meeting_stage_mode_changed", %{mode: "screen"})
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

        case Meetings.mint_guest_join_bundle(meeting, trimmed) do
          {:ok, _bundle} ->
            {:noreply,
             socket
             |> assign(:name_error, nil)
             |> enter_meeting_as_guest(meeting, trimmed)}

          {:error, :livekit_not_configured} ->
            {:noreply,
             assign(
               socket,
               :name_error,
               "Meetings are not available right now. Please try again later."
             )}

          {:error, _other} ->
            {:noreply, assign(socket, :name_error, "Something went wrong. Please try again.")}
        end
    end
  end

  def handle_event("submit_name", _params, socket) do
    {:noreply, assign(socket, :name_error, "Please enter your name.")}
  end

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

  def handle_event("calendar_today", _params, socket) do
    today = calendar_today(socket)
    {:noreply, assign_calendar_week(socket, today, today)}
  end

  # A `phx-click` payload is a message from a client, so an unparseable
  # date is IGNORED rather than raised on: the only thing that can send
  # one is a stale or hand-edited DOM, and neither deserves a 500.
  def handle_event("select_calendar_day", %{"date" => iso8601}, socket) do
    case Date.from_iso8601(iso8601) do
      {:ok, date} ->
        {:noreply, assign(socket, :calendar_selected_date, date)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("select_meeting", %{"id" => meeting_id}, socket) do
    {:noreply, assign(socket, :selected_meeting_id, meeting_id)}
  end

  def handle_event("close_meeting_detail", _params, socket) do
    {:noreply, assign(socket, :selected_meeting_id, nil)}
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

  # Paging keeps the selected day's OFFSET within the week (a Wednesday
  # stays a Wednesday) rather than snapping back to Monday, so stepping
  # through weeks does not silently move which day is highlighted.
  defp shift_calendar_week(socket, days) do
    anchor = Date.add(socket.assigns.calendar_anchor_date, days)
    selected = Date.add(socket.assigns.calendar_selected_date, days)
    assign_calendar_week(socket, anchor, selected)
  end

  # ── Start-meeting FAB + bottom-sheet (`:index` action only) ──────────────
  #
  # The FAB lives only on the meetings index. Clicking it flips
  # `:show_start_meeting_sheet` so the bottom-sheet wrapper renders. The
  # sheet collects { name, project_id, description } and submits to
  # `Platform.Meetings.create_meeting/1`. On success, we close the sheet,
  # flash, and `push_navigate` to `/meetings/<slug>` so the user lands
  # straight inside the new meeting.

  def handle_event("open_start_meeting_sheet", _params, socket) do
    projects = socket.assigns[:projects] || []

    {:noreply,
     socket
     |> assign(:show_start_meeting_sheet, true)
     |> assign(:start_meeting_form, blank_start_meeting_form(projects))
     |> assign(:start_meeting_error, nil)}
  end

  def handle_event("close_start_meeting_sheet", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_start_meeting_sheet, false)
     |> assign(:start_meeting_error, nil)}
  end

  # Live-update form state on input change so re-render keeps the user's
  # input in the sheet (otherwise an inline-validation render wipes it).
  def handle_event("start_meeting_form_change", %{"start_meeting" => attrs}, socket) do
    {:noreply,
     assign(socket, :start_meeting_form, %{
       "name" => Map.get(attrs, "name", ""),
       "project_id" => Map.get(attrs, "project_id", ""),
       "description" => Map.get(attrs, "description", "")
     })}
  end

  def handle_event("start_meeting", %{"start_meeting" => attrs}, socket) do
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()
    project_id = attrs |> Map.get("project_id", "") |> to_string() |> String.trim()
    description = attrs |> Map.get("description", "") |> to_string()

    cond do
      name == "" ->
        {:noreply,
         socket
         |> assign(:start_meeting_form, %{
           "name" => name,
           "project_id" => project_id,
           "description" => description
         })
         |> assign(:start_meeting_error, "Name is required.")}

      project_id == "" ->
        {:noreply,
         socket
         |> assign(:start_meeting_form, %{
           "name" => name,
           "project_id" => project_id,
           "description" => description
         })
         |> assign(:start_meeting_error, "Project is required.")}

      true ->
        case Meetings.create_meeting(%{
               project_id: project_id,
               name: name
             }) do
          {:ok, meeting} ->
            {:noreply,
             socket
             |> assign(:show_start_meeting_sheet, false)
             |> assign(:start_meeting_error, nil)
             |> assign(
               :start_meeting_form,
               blank_start_meeting_form(socket.assigns[:projects] || [])
             )
             |> put_flash(:info, "Meeting started.")
             |> push_navigate(to: ~p"/meetings/#{meeting.slug}")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:start_meeting_form, %{
               "name" => name,
               "project_id" => project_id,
               "description" => description
             })
             |> assign(:start_meeting_error, "Could not start meeting.")}
        end
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

      socket.assigns[:chrome_mode] == :none ->
        # Guest ingress (task 019f498d stage 3): mount already minted the
        # bundle and pushed `join-meeting`. MeetingHooks.join/1 assumes a
        # binary `:user_id` (see `do_join/1`), which the guest surface
        # doesn't have — so auto-join is a no-op on the guest path.
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

  def handle_info({:participant_joined, _participant}, socket) do
    {:noreply, refresh_participants(socket)}
  end

  def handle_info({:participant_left, _participant}, socket) do
    {:noreply, refresh_participants(socket)}
  end

  def handle_info({:participant_updated, _participant}, socket) do
    {:noreply, refresh_participants(socket)}
  end

  # Live presence delta on the per-space topic. `broadcast_presence_change`
  # fires this on every LiveKit join/leave (even before/after a room row
  # exists), so it's the resilient signal that keeps the rail + count live
  # without a manual refresh. We also (re)subscribe to the now-active room
  # topic so the granular `{:participant_joined,_}`/`{:participant_left,_}`
  # events flow if the room was activated after mount.
  def handle_info({:meeting_presence_update, _payload}, socket) do
    case socket.assigns[:meeting] do
      %{chat_space_id: space_id} when is_binary(space_id) ->
        case Meetings.get_active_room(space_id) do
          %{id: room_id} -> MeetingsPubSub.subscribe_room(room_id)
          _ -> :ok
        end

      _ ->
        :ok
    end

    {:noreply, refresh_participants(socket)}
  end

  # Live canvas-creation broadcasts on the meeting's chat-space topic.
  # If the meeting doesn't yet have a tracked canvas, latch on to this
  # one so a peer's "Create canvas" click flips this LV's center stage
  # without a refresh. If we already have one, prefer the newer (the
  # most-recently-created canvas wins, matching `latest_canvas/1`).
  def handle_info({:canvas_created, canvas}, socket) do
    %{assigns: %{meeting: meeting, meeting_canvas: current}} = socket

    cond do
      is_nil(meeting) -> {:noreply, socket}
      canvas.space_id != meeting.chat_space_id -> {:noreply, socket}
      is_nil(current) -> {:noreply, assign(socket, :meeting_canvas, canvas)}
      newer?(canvas, current) -> {:noreply, assign(socket, :meeting_canvas, canvas)}
      true -> {:noreply, socket}
    end
  end

  # Live canvas-update broadcasts: refresh the cached struct so the
  # rendered document reflects the latest server state when the active
  # meeting canvas is the one that changed.
  def handle_info({:canvas_updated, canvas}, socket) do
    case socket.assigns[:meeting_canvas] do
      %{id: id} when id == canvas.id -> {:noreply, assign(socket, :meeting_canvas, canvas)}
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
      meetings = Meetings.list_all_meetings()

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
  # cadence survives as long as the index is mounted. Re-assigns nothing:
  # the render reads the clock, this only forces the beat.
  def handle_info(:calendar_tick, socket) do
    schedule_calendar_tick()
    {:noreply, socket}
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

  # ── Intents-collapse live updates (task 019f70b8 stage 7) ────────────────
  #
  # MUST stay ABOVE the catch-all below — the catch-all swallows anything
  # declared after it, silently, and a silently-swallowed queue event is
  # exactly the invisibility this task exists to remove.
  #
  # All eight events carry the full row map, so the strip updates from
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

  # Catch-all: chat-space topic carries many event shapes (messages,
  # reactions, pins, …). The shell only cares about roster + canvas
  # events; ignore the rest so a broadcast can't crash the LV.
  def handle_info(_event, socket), do: {:noreply, socket}

  # Mirror ChatLive's terminate hook so a tab-close mid-meeting
  # broadcasts the "left" event and the mini-bar doesn't ghost.
  @impl true
  def terminate(_reason, socket) do
    MeetingHooks.on_terminate(socket)
    maybe_broadcast_guest_leave(socket)
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
  # consumes. On mint failure land on `:state = :invalid` — same failure
  # surface as an unverifiable token, since a downstream mint issue is
  # indistinguishable from an invalid invite from the guest's POV.
  #
  # Called from both the mount clause (invite payload carried a
  # display_name) and the `"submit_name"` event handler (guest typed
  # their own name). Keeping the code in ONE helper means the two
  # entry points cannot drift.
  defp enter_meeting_as_guest(socket, meeting, display_name)
       when is_binary(display_name) do
    case Meetings.mint_guest_join_bundle(meeting, display_name) do
      {:ok, bundle} ->
        if connected?(socket) and is_binary(meeting.chat_space_id) do
          MeetingsPubSub.subscribe_presence(meeting.chat_space_id)

          case Meetings.get_active_room(meeting.chat_space_id) do
            %{id: room_id} -> MeetingsPubSub.subscribe_room(room_id)
            _ -> :ok
          end
        end

        # 019f498d re-dispatch: land the guest in the shared live-presence
        # table so the auth-side MeetingLive session (subscribed to the
        # same presence + room topics) refreshes `@participants` and
        # renders a `.video_tile` with `data-participant="guest:<random>"`
        # matching the identity the guest publishes on LiveKit. Without
        # this the LiveKit RTP flow arrives on the auth surface but has
        # no DOM element to mount onto — the failing V1/V5 e2e symptom.
        maybe_upsert_guest_presence(socket, meeting, bundle, display_name)

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
        |> push_event("join-meeting", Meetings.guest_join_event_payload(bundle, meeting))

      {:error, _reason} ->
        socket
        |> assign(:state, :invalid)
        |> assign(:page_title, "Invite link is not valid")
        |> assign(:meeting, nil)
        |> seed_guest_index_fallback_assigns()
    end
  end

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
    |> assign(:agents_by_id, load_agents_by_id(participants))
  end

  defp refresh_participants(socket), do: socket

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
  defp meeting_participant_view_model(%Meetings.Participant{} = p) do
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
      # Live presence rows don't carry mic state yet; keep the key so the
      # rail's `mic_on?/1` and the strip's `attention_config` reads stay
      # total without special-casing nil.
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

    {name, nil}
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

  # Build a `%{agent_id => %Agent{}}` map for any agent-typed participants.
  # Empty when no agents are seated. Drives the rail's role chip + status dot.
  defp load_agents_by_id(participants) when is_list(participants) do
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

  defp load_agents_by_id(_), do: %{}

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

  # ── Index helpers (`:index` action) ──────────────────────────────────────
  #
  # The meetings index groups meetings by status so the live ones float to
  # the top, the upcoming (`scheduled`) sit in the middle, and ended sink
  # to the bottom. Section order is intentional — a viewer scanning the
  # page wants "what's happening right now" first.

  @meeting_status_sections [:live, :upcoming, :ended]

  @doc """
  Sections rendered by the meetings index, in display order.

  Public so tests + the heex template can iterate without hard-coding
  the order in two places.
  """
  def meeting_status_sections, do: @meeting_status_sections

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

  # Default start-meeting form values. When exactly one project exists we
  # pre-fill it so a single-project workspace doesn't show a useless
  # one-option select.
  defp blank_start_meeting_form(projects) when is_list(projects) do
    project_id =
      case projects do
        [%{id: id}] -> id
        _ -> ""
      end

    %{"name" => "", "project_id" => project_id, "description" => ""}
  end

  defp blank_start_meeting_form(_), do: %{"name" => "", "project_id" => "", "description" => ""}

  # `blank_guest_invite_form/0`, `trim_or_nil/1` and `parse_expires_hours/1`
  # lived here until task 019fb955-1d7b stage 1. They existed only to feed the
  # meeting-wide guest-invite sheet, which minted an unattributable forwardable
  # link; with that sheet gone they had no other caller. Guest tokens are now
  # produced solely by `Meetings.invite_guest/2`, which does its own trimming
  # and expiry defaulting against a persisted `meeting_invites` row.

  @doc "Human label for a meeting status section."
  def meeting_section_label(:live), do: "Live now"
  def meeting_section_label(:upcoming), do: "Upcoming"
  def meeting_section_label(:ended), do: "Ended"

  @doc "Hero-icon class for a meeting status section."
  def meeting_section_icon(:live), do: "hero-signal"
  def meeting_section_icon(:upcoming), do: "hero-calendar"
  def meeting_section_icon(:ended), do: "hero-archive-box"

  @doc "Status-pill tone class for a meeting status."
  def meeting_status_pill(:live), do: "badge badge-error gap-1"
  def meeting_status_pill(:upcoming), do: "badge badge-info gap-1"
  def meeting_status_pill(:ended), do: "badge badge-ghost gap-1"

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
  # Canvas mode uses the most-recently-created canvas in the meeting's
  # bound chat space (per ADR 0036 + ADR 0042). When none exists, the
  # heex renders the "No canvas yet" empty-state CTA which routes back
  # to `handle_event("create_meeting_canvas", …)` above.

  # Most-recently-created non-deleted canvas in the meeting's chat
  # space. `Chat.list_canvases/1` returns oldest-first; we take the last
  # element so a meeting's freshly-minted canvas wins over older ones.
  defp latest_canvas(space_id) when is_binary(space_id) do
    space_id
    |> Chat.list_canvases()
    |> List.last()
  end

  defp latest_canvas(_), do: nil

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
  def gallery_participants(participants) when is_list(participants) do
    Enum.filter(participants, fn
      %{participant_type: "user"} -> true
      _ -> false
    end)
  end

  def gallery_participants(_), do: []

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
  Pick the grid shape (Tailwind class string) that maximizes per-tile area
  for `count` 16:9 tiles in a roughly-portrait container (typical desktop
  gallery interior is taller than wide once the bottom strip is hidden).
  Returns the full `grid-cols-N` class plus a matching `grid-rows-M` class
  so `auto-rows-fr` partitions the height evenly.

  Mobile (< sm = <640px) defaults to a vertical stack so each tile keeps
  legible width — at 390px viewport a horizontal split into 3 columns
  yields ~111×63 tiles which fall below the 80px legibility floor. The
  `sm:` prefix restores the desktop-optimized shape from `sm` upward.

  Shapes (mobile / sm+ cols x rows):
    1 -> 1x1 / 1x1
    2 -> 1x2 / 1x2 (already vertical on both)
    3 -> 1x3 / 1x3 (already vertical on both)
    4 -> 1x4 / 2x2
    5..6 -> 1xN / 3x2
    7..9 -> 1xN / 3x3
    10..12 -> 2xceil(N/2) / 4x3
    13..16 -> 2xceil(N/2) / 4x4
    17+ -> 2xceil(N/2) / 5x4 with overflow.

  Why vertical stacking for 2 and 3 participants on desktop? In a roughly-
  portrait gallery container (e.g. 624×780 desktop interior), splitting
  horizontally into 2..3 columns yields tall, narrow cells (~312×780 or
  200×780). A 16:9 tile centered in those cells is width-bounded and
  tiny (312×175 or 200×113) with massive top/bottom letterboxing —
  that's the "thumbnail floating in cell" look Rowan rejected.
  Stacking vertically (1 col × 2..3 rows) gives wide-but-short cells
  (624×390 or 624×260) where the 16:9 tile fits at 624×351 or 462×260
  — roughly 4× the per-tile area for 2p.

  Both axes are explicit-class so Tailwind's content scanner picks them up
  as literal strings in the helper body (which is itself in a `.heex`-
  reachable module). Don't switch to interpolation like
  `"grid-cols-\#{n}"` — that goes invisible to the JIT.
  """
  @spec gallery_grid_class(non_neg_integer()) :: String.t()
  def gallery_grid_class(count)
  def gallery_grid_class(0), do: "grid-cols-1 grid-rows-1"
  def gallery_grid_class(1), do: "grid-cols-1 grid-rows-1"
  def gallery_grid_class(2), do: "grid-cols-1 grid-rows-2"
  def gallery_grid_class(3), do: "grid-cols-1 grid-rows-3"
  def gallery_grid_class(4), do: "grid-cols-1 grid-rows-4 sm:grid-cols-2 sm:grid-rows-2"
  def gallery_grid_class(5), do: "grid-cols-1 grid-rows-5 sm:grid-cols-3 sm:grid-rows-2"
  def gallery_grid_class(6), do: "grid-cols-1 grid-rows-6 sm:grid-cols-3 sm:grid-rows-2"
  def gallery_grid_class(7), do: "grid-cols-1 grid-rows-7 sm:grid-cols-3 sm:grid-rows-3"
  def gallery_grid_class(8), do: "grid-cols-1 grid-rows-8 sm:grid-cols-3 sm:grid-rows-3"
  def gallery_grid_class(9), do: "grid-cols-1 grid-rows-9 sm:grid-cols-3 sm:grid-rows-3"
  def gallery_grid_class(10), do: "grid-cols-2 grid-rows-5 sm:grid-cols-4 sm:grid-rows-3"
  def gallery_grid_class(11), do: "grid-cols-2 grid-rows-6 sm:grid-cols-4 sm:grid-rows-3"
  def gallery_grid_class(12), do: "grid-cols-2 grid-rows-6 sm:grid-cols-4 sm:grid-rows-3"
  def gallery_grid_class(13), do: "grid-cols-2 grid-rows-7 sm:grid-cols-4 sm:grid-rows-4"
  def gallery_grid_class(14), do: "grid-cols-2 grid-rows-7 sm:grid-cols-4 sm:grid-rows-4"
  def gallery_grid_class(15), do: "grid-cols-2 grid-rows-8 sm:grid-cols-4 sm:grid-rows-4"
  def gallery_grid_class(16), do: "grid-cols-2 grid-rows-8 sm:grid-cols-4 sm:grid-rows-4"
  def gallery_grid_class(_n), do: "grid-cols-2 grid-rows-8 sm:grid-cols-5 sm:grid-rows-4"

  @doc """
  Chrome-aware variant of `gallery_grid_class/1`. The default (shell)
  path routes to `gallery_grid_class/1` unchanged, so the auth surface's
  vertical-stack layout Rowan explicitly chose (see the 1x2 / 1x3
  comments above) is preserved.

  When `chrome_mode == :none` the guest surface has no chat panel, no
  icon rail — the meeting stage owns the full viewport width. In that
  world stacking 2 or 3 tiles vertically leaves huge horizontal
  letterbox: each 16:9 tile becomes height-bound at ~½ or ⅓ of the
  vertical space and cannot expand horizontally. Side-by-side on `sm+`
  reclaims that width — each tile fills ~½ or ⅓ of the viewport
  horizontally, which is bigger than the auth-surface stacked variant
  because the guest viewport is bigger to begin with.

  Below `sm` (mobile portrait) both surfaces stack vertically. The
  responsive `sm:` prefixes only kick in once viewport width is >= 640px
  so mobile guests keep the readable stacked layout.
  """
  @spec gallery_grid_class(non_neg_integer(), :shell | :none) :: String.t()
  def gallery_grid_class(2, :none), do: "grid-cols-1 grid-rows-2 sm:grid-cols-2 sm:grid-rows-1"
  def gallery_grid_class(3, :none), do: "grid-cols-1 grid-rows-3 sm:grid-cols-3 sm:grid-rows-1"
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
  Status-dot tone class for an agent participant. Maps the agent's `status`
  enum onto a daisyUI tone (success/warning/neutral).
  """
  @spec agent_status_dot_class(Platform.Chat.Participant.t(), %{binary() => Agent.t()}) ::
          String.t()
  def agent_status_dot_class(
        %{participant_type: "agent", participant_id: agent_id},
        agents_by_id
      ) do
    case Map.get(agents_by_id, agent_id) do
      %Agent{status: "active"} -> "bg-success"
      %Agent{status: status} when status in ["idle", "paused"] -> "bg-warning"
      _ -> "bg-base-content/30"
    end
  end

  def agent_status_dot_class(_p, _agents_by_id), do: "bg-base-content/30"

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
  True when the participant's mic is on. Reads
  `participant.attention_config["mic_on"]`; defaults to `false`.
  """
  @spec mic_on?(Platform.Chat.Participant.t()) :: boolean()
  def mic_on?(%{attention_config: %{"mic_on" => true}}), do: true
  def mic_on?(_participant), do: false

  @doc """
  True when this participant is currently speaking. Driven by LiveKit
  speaking-event hooks in later stages; defaults to `false` here.
  """
  @spec speaking?(Platform.Chat.Participant.t(), MapSet.t()) :: boolean()
  def speaking?(%{id: id}, %MapSet{} = ids), do: MapSet.member?(ids, id)
  def speaking?(_participant, _ids), do: false

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
