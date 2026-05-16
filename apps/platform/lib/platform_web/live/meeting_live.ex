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
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformWeb.ChatLive.MeetingHooks

  # Stage modes per ADR 0042's "Stage modes" table. Canvas is the default
  # (meetings are often artifact-driven).
  @stage_modes [:canvas, :screen, :gallery, :whiteboard]

  @doc "Stage modes the segmented control exposes (ADR 0042)."
  def stage_modes, do: @stage_modes

  @impl true
  def mount(_params, session, socket) do
    # Pull the authenticated user_id off the session (same pattern as
    # ChatLive). Used to resolve a `current_participant` in the meeting's
    # bound chat space when an interaction (e.g. "Create canvas") needs an
    # author. Falls back to a generated UUID for anonymous test paths so
    # the LV stays mountable even without a session — tests that exercise
    # canvas creation set `current_user_id` explicitly.
    user_id = session["current_user_id"] || Ecto.UUID.generate()

    {:ok,
     socket
     |> assign(:user_id, user_id)
     |> assign(:stage_modes, @stage_modes)
     # Mobile drawer state — defaults CLOSED. Desktop ignores this
     # assign (column is `hidden lg:flex`). See @moduledoc for the
     # reconciliation against the stack-spec's "defaults to true" line.
     |> assign(:chat_panel_open, false)}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _url, socket) do
    case Meetings.get_meeting_by_slug(slug) do
      nil ->
        # Clean not-found path — no MatchError / Ecto.NoResultsError
        # bubbles.
        {:noreply,
         socket
         |> put_flash(:error, "Meeting not found.")
         |> push_navigate(to: ~p"/meetings")}

      meeting ->
        if connected?(socket) do
          if meeting.chat_space_id do
            ChatPubSub.subscribe(meeting.chat_space_id)
          end

          Phoenix.PubSub.subscribe(Platform.PubSub, meeting_topic(meeting.id))
        end

        participants =
          if meeting.chat_space_id, do: Chat.list_participants(meeting.chat_space_id), else: []

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
        {:noreply, assign(socket, :current_stage_mode, stage_mode)}

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
    if socket.assigns[:in_meeting] do
      {:noreply, socket}
    else
      {:noreply, MeetingHooks.join(socket)}
    end
  end

  def handle_info({:participant_joined, _participant}, socket) do
    {:noreply, refresh_participants(socket)}
  end

  def handle_info({:participant_left, _participant}, socket) do
    {:noreply, refresh_participants(socket)}
  end

  def handle_info({:participant_updated, _participant}, socket) do
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
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp refresh_participants(%{assigns: %{meeting: %{chat_space_id: space_id}}} = socket)
       when is_binary(space_id) do
    participants = Chat.list_participants(space_id)

    socket
    |> assign(:participants, participants)
    |> assign(:agents_by_id, load_agents_by_id(participants))
  end

  defp refresh_participants(socket), do: socket

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
  def gallery_identity(%{participant_id: pid}) when is_binary(pid) and pid != "",
    do: "user:" <> pid

  def gallery_identity(%{id: id}) when is_binary(id) and id != "", do: "user:" <> id
  def gallery_identity(_), do: "user:unknown"

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
