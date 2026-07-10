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
  """
  use PlatformWeb, :live_view

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]
  import PlatformWeb.Components.Meeting.VideoTile, only: [video_tile: 1]
  import PlatformWeb.Components.Meetings.ParticipantRail, only: [participant_rail: 1]

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformWeb.ChatLive.MeetingHooks

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

      {:error, :invalid} ->
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
    |> assign(:show_guest_invite_sheet, false)
    |> assign(:guest_invite_form, blank_guest_invite_form())
    |> assign(:guest_invite_url, nil)
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
     |> assign(:captions_visible, false)}
  end

  @impl true
  # Guest ingress (task 019f498d stage 3): the guest mount clause above
  # already resolved the invite + seeded every assign the guest states
  # need (`:state` in `[:expired, :invalid, :name_entry, :in_meeting]`).
  # handle_params is a no-op here to avoid the shell-path
  # `Meetings.get_meeting_by_slug/1` re-lookup and MeetingHooks.attach/2
  # (which requires a binary user_id and would double-subscribe the guest
  # to per-space PubSub). Guarded on `:state` presence rather than
  # `:chrome_mode == :none` alone so the stage-1 `/_probe/:slug` smoke
  # route (chrome_mode :none, no token, no `:state`) still falls through
  # to the shell path and its `:meeting` assign lands.
  def handle_params(_params, _url, %{assigns: %{state: state}} = socket)
      when state in [:expired, :invalid, :name_entry, :in_meeting] do
    {:noreply, socket}
  end

  def handle_params(%{"slug" => slug} = params, _url, socket) do
    case Meetings.get_meeting_by_slug(slug) do
      nil ->
        # Clean not-found path — no MatchError / Ecto.NoResultsError
        # bubbles. Also clear the client's saved `route_resume:meetings`
        # entry so the Meetings tile falls back to `/meetings` on the next
        # click rather than looping right back into this nil resolve.
        {:noreply,
         socket
         |> handle_route_stale("meetings")
         |> put_flash(:error, "Meeting not found.")
         |> push_navigate(to: ~p"/meetings")}

      meeting ->
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
          # ── Guest-invite sheet (stage 4 of task 019f2483) ─────────────
          # `:show_guest_invite_sheet` — bottom-sheet visibility flag.
          # `:guest_invite_form` — mirror of the sheet's fields so
          #   phx-change re-renders don't wipe user input.
          # `:guest_invite_url` — nil until the host clicks Generate,
          #   then holds the signed guest URL for the copy affordance.
          |> assign(:show_guest_invite_sheet, false)
          |> assign(:guest_invite_form, blank_guest_invite_form())
          |> assign(:guest_invite_url, nil)
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

  def handle_params(_params, _url, socket) do
    # `:index` action — grouped meetings list (live / upcoming / ended)
    # plus an empty-state when no meetings exist. Pre-project-routing
    # the index lists every meeting; per-project subscription keeps
    # `{:meeting_created, _}` / `{:meeting_ended, _}` / `{:meeting_started, _}`
    # broadcasts flowing in.
    projects = Tasks.list_projects()
    project_ids = Enum.map(projects, & &1.id)

    if connected?(socket) do
      Enum.each(project_ids, &Meetings.subscribe_to_project_meetings/1)
    end

    meetings = Meetings.list_all_meetings()
    grouped = group_meetings_by_status(meetings)

    {:noreply,
     socket
     |> assign(:page_title, "Meetings")
     |> assign(:meeting, nil)
     |> assign(:meetings, meetings)
     |> assign(:grouped_meetings, grouped)
     |> assign(:meeting_subscribed_project_ids, project_ids)
     |> assign_new(:projects, fn -> projects end)
     |> assign_new(:show_start_meeting_sheet, fn -> false end)
     |> assign_new(:start_meeting_form, fn -> blank_start_meeting_form(projects) end)
     |> assign_new(:start_meeting_error, fn -> nil end)}
  end

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

  # ── Guest-invite sheet (stage 4 of task 019f2483) ───────────────────────
  #
  # The host clicks "Copy guest link", the sheet slides up, they type a name
  # (optional) + pick an expiry, and the LV mints:
  #   1. a dedicated guest chat_space (`Meetings.create_guest_chat_space/2`)
  #      so guest-authored messages don't leak into the meeting's real
  #      space; the space id is threaded through the signed token so the
  #      guest-ingress path can bind writes.
  #   2. a signed HMAC token (`Platform.Meetings.GuestInvite.sign/4`)
  #      carrying `{meeting_slug, expires_at, display_name, guest_space_id}`.
  #   3. a URL of the form
  #      `https://<meeting_guest_host>/<meeting_slug>/<token>` that maps
  #      back into `MeetingLive` under the `meet.` host scope (with
  #      `chrome_mode: :none`; see `PlatformWeb.Router`).
  #
  # Sheet visibility is host-gated in the template on `host?/2`; the events
  # themselves stay safe if a non-host somehow triggers them (a `Meetings`
  # write-side check would be the real guard, out of scope here).

  def handle_event("open_guest_invite_sheet", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_guest_invite_sheet, true)
     |> assign(:guest_invite_url, nil)
     |> assign(:guest_invite_form, blank_guest_invite_form())}
  end

  def handle_event("close_guest_invite_sheet", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_guest_invite_sheet, false)
     |> assign(:guest_invite_url, nil)}
  end

  def handle_event("guest_invite_form_change", %{"guest_invite" => attrs}, socket) do
    {:noreply,
     assign(socket, :guest_invite_form, %{
       "display_name" => Map.get(attrs, "display_name", ""),
       "expires_in_hours" => Map.get(attrs, "expires_in_hours", "24")
     })}
  end

  def handle_event("generate_guest_invite", %{"guest_invite" => attrs}, socket) do
    %{meeting: meeting, user_id: user_id} = socket.assigns

    display_name = attrs |> Map.get("display_name", "") |> to_string() |> trim_or_nil()
    hours = attrs |> Map.get("expires_in_hours", "24") |> parse_expires_hours()

    # Persist the form values back into the assign so the sheet re-renders
    # with what the host typed (and the newly-generated URL underneath).
    form_state = %{
      "display_name" => attrs |> Map.get("display_name", "") |> to_string(),
      "expires_in_hours" => attrs |> Map.get("expires_in_hours", "24") |> to_string()
    }

    case Meetings.create_guest_chat_space(meeting, user_id) do
      {:ok, guest_space} ->
        expires_at = :os.system_time(:second) + hours * 3600

        token =
          Platform.Meetings.GuestInvite.sign(
            meeting.slug,
            expires_at,
            display_name,
            guest_space_id: guest_space.id
          )

        host = Application.get_env(:platform, :meeting_guest_host, "meet.example.com")
        url = "https://#{host}/#{meeting.slug}/#{token}"

        {:noreply,
         socket
         |> assign(:guest_invite_form, form_state)
         |> assign(:guest_invite_url, url)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:guest_invite_form, form_state)
         |> put_flash(:error, "Could not generate a guest link.")}
    end
  end

  def handle_event("copy_guest_invite", _params, socket) do
    # The visible Copy button is wrapped by the `CopyToClipboard` JS hook
    # (which reads `data-clipboard-text` and writes to the clipboard on
    # click), but we also emit a browser event so a top-level toast hook
    # can confirm the copy. Both paths coexist harmlessly.
    {:noreply, push_event(socket, "guest_invite_copied", %{})}
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
  def handle_info({tag, %Meetings.Meeting{}}, socket)
      when tag in [:meeting_created, :meeting_started, :meeting_ended] do
    if Map.has_key?(socket.assigns, :meetings) do
      meetings = Meetings.list_all_meetings()

      {:noreply,
       socket
       |> assign(:meetings, meetings)
       |> assign(:grouped_meetings, group_meetings_by_status(meetings))}
    else
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

  # Default values for the guest-invite sheet form (stage 4 of task
  # 019f2483). 24h expiry is the default because that matches the
  # `sign_with_default_expiry/2` window; hosts can dial down (1h) or up
  # (72h) via the select in the sheet.
  defp blank_guest_invite_form,
    do: %{"display_name" => "", "expires_in_hours" => "24"}

  # `""` → `nil` (self-entry flow), any non-empty string → trimmed value.
  # Keeps `GuestInvite.sign/4`'s payload contract clean (display_name is
  # either a non-empty binary or `nil`, never a whitespace string).
  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(_), do: nil

  # Clamp the sheet's expiry select to the three sanctioned windows
  # (1h/24h/72h). Anything else — including a hand-crafted phx-value —
  # falls back to 24h so a malicious client can't mint a 10-year token.
  defp parse_expires_hours(value) when is_binary(value) do
    case Integer.parse(value) do
      {hours, ""} when hours in [1, 24, 72] -> hours
      _ -> 24
    end
  end

  defp parse_expires_hours(value) when is_integer(value) and value in [1, 24, 72], do: value
  defp parse_expires_hours(_), do: 24

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
