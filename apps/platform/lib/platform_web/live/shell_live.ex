defmodule PlatformWeb.ShellLive do
  @moduledoc "Mount hook that injects shell assigns for all authenticated surfaces."

  import Ecto.Query
  import Phoenix.Component
  import Phoenix.LiveView

  require Logger

  alias Phoenix.LiveView.AsyncResult
  alias Platform.Accounts
  alias Platform.Agents.{Agent, AgentServer, WorkspaceBootstrap}
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.SpaceAgentPresence
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Push
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias PlatformWeb.Components.IconRail

  def on_mount(:default, _params, session, socket) do
    raw_user_id = session["current_user_id"]

    user_record =
      case raw_user_id do
        user_id when is_binary(user_id) -> Accounts.get_user(user_id)
        _ -> nil
      end

    current_user =
      case user_record do
        %{name: name} when is_binary(name) and name != "" -> name
        %{email: email} when is_binary(email) -> email
        _ -> session["user_email"] || session["user_id"] || raw_user_id || "user"
      end

    # MT/RBAC stack 2 (task 019e3c4a): admin nav is now gated on real
    # Fabrikam-root admin membership, not the legacy `Accounts.is_fabrikam_user?/1`
    # stub which returned `true` for every user. We use the *pure*
    # `fabrikam_admin_preloaded?/1` variant so this lookup costs zero extra
    # Repo queries — `Accounts.get_user/1` (called a few lines above)
    # preloaded `:org_memberships` with the nested `:org`.
    # Both assigns are kept so existing components (icon_rail, bottom_rail,
    # more_sheet) that read `is_fabrikam_user` continue to render correctly
    # while new code adopts `fabrikam_admin?` via the LiveAuth hook.
    is_fabrikam_user = Platform.Tenancy.fabrikam_admin_preloaded?(user_record)

    # Resolve org visibility ONCE and thread it (Tenancy moduledoc). The
    # preloaded clause costs zero queries because `Accounts.get_user/1`
    # already preloaded `:org_memberships` with the nested `:org`.
    roster_visibility = Tenancy.visibility(user_record)

    active_module = derive_active_module(socket.view)

    # Synchronous placeholders so the page paints immediately. Heavy DB work
    # (roster lookup + presence list build) is deferred via `assign_async/3`
    # below so the WS-connected mount returns to the client without blocking
    # on Postgres round-trips. The four async-managed assigns are seeded as
    # `AsyncResult.loading/0` so the template's `<.async_result>` component
    # has a valid struct to dispatch on for both the disconnected (static)
    # render and the WS-connected pre-resolution render.
    socket =
      socket
      |> assign(:roster_items, AsyncResult.loading())
      |> assign(:composite_status, AsyncResult.loading())
      |> assign(:principal_name, AsyncResult.loading())
      |> assign(:presence_list, AsyncResult.loading())
      |> assign(:roster_space_id, nil)
      # Task 019fe4b1 stage 3: the presence badge is no longer scoped to one
      # arbitrary space. The viewer's observable set is a LIST of space ids
      # (resolved by `Chat.list_viewer_presence_space_ids/1`), and this assign
      # holds the exact set this LV process holds PubSub subscriptions for, so
      # a `presence_diff` on any of them can rebuild the union.
      |> assign(:presence_space_ids, [])

    # Schedule async load + PubSub subscribes only on the WS-connected mount.
    # Static/disconnected render skips this entirely (placeholders ship to the
    # browser, then the connected mount runs and resolves them).
    #
    # NOTE: assign_async runs the function in a separate Task process, so we
    # capture the LV pid up front and send :roster_resolved back to ourselves
    # once the space_id is known. The existing :roster_updates handle_info
    # hook reacts to that message to install PubSub subscribes on the LV
    # process (the Task can't subscribe on our behalf — the messages would
    # land in the wrong mailbox).
    socket =
      if connected?(socket) do
        lv_pid = self()

        # Subscribe once per LV to the tasks board topic so the bottom-nav
        # Tasks badge stays live (task 019e1322 Stage 3). We don't need a
        # per-user topic — the board topic broadcasts every {:task_*}
        # event; we filter by assignee in handle_info before recomputing
        # the count.
        Platform.Tasks.subscribe_board()

        # Only authenticated user sessions subscribe to their inbox topic —
        # anonymous/non-user mounts skip it (the is_binary guard IS the
        # `type: :user` gate). External users are real user records, so they
        # subscribe and get their own scoped count.
        if is_binary(raw_user_id), do: Inbox.subscribe(raw_user_id)

        # One global roster topic for the viewer-scoped union (see
        # `Chat.global_roster_topic/0`). The per-space subscription installed
        # by `:roster_resolved` stays as-is for the current space.
        Phoenix.PubSub.subscribe(Platform.PubSub, Chat.global_roster_topic())

        socket
        |> assign_async(
          [:roster_items, :composite_status, :principal_name],
          fn -> async_load_roster(lv_pid, roster_visibility) end
        )
        |> assign_async(:presence_list, fn -> async_load_presence(lv_pid, user_record) end)
        |> maybe_subscribe_meeting_state(raw_user_id)
      else
        socket
      end

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_record, user_record)
      |> assign(:roster_visibility, roster_visibility)
      |> assign(:current_user_id, raw_user_id)
      |> assign(:current_path, "/")
      |> assign(:agent_status, default_agent_status())
      |> assign(:more_sheet_open, false)
      |> assign(:sidebar_collapsed, false)
      |> assign(:active_module, active_module)
      |> assign(:is_fabrikam_user, is_fabrikam_user)
      |> assign(:tasks_count, compute_tasks_count(raw_user_id))
      |> assign(:inbox_unread_count, compute_inbox_count(raw_user_id))
      |> assign(:roster_open, false)
      |> assign(:show_presence_panel, false)
      |> assign(:meeting_active, false)
      |> assign(:meeting_space_id, nil)
      |> assign(:meeting_space_name, nil)
      |> assign(:meeting_space_slug, nil)
      |> assign(:meeting_slug, nil)
      |> assign(:meeting_started_at, nil)
      |> assign(:on_meeting_page, false)
      # Stage 4 (task 019ee06b): the no-ChatLive bar-toggle fallback caches
      # the post-toggle mic/camera state here so it can flip them on each
      # click without round-tripping. Defaults mirror MeetingBarLive's
      # `mount/1` assigns. Also updated when `:meeting_media_state` is
      # received (from ANY source — MeetingHooks on another tab, or this
      # shell's own broadcast) so the cache stays the authority.
      |> assign(:shell_bar_mic_on, true)
      |> assign(:shell_bar_camera_on, false)
      # Task 019ffb7b stage 3: the browser's notification-permission state,
      # reported by the `PushSubscribe` hook mounted at
      # `shell.html.heex`. Seeded here rather than in ChatLive so every
      # surface running this on_mount has it. The five wire values are
      # "unknown", "prompt", "granted", "denied" and "unsupported";
      # "unknown" means the client has not reported yet, and nothing that
      # keys on this assign may render until it has.
      |> assign(:push_permission, "unknown")
      # Task 019ffb7b stage 4 rework: the browser refused the request without
      # ever asking the user (private window, or notifications off for all
      # sites). Deliberately a flag beside `:push_permission` and not a value
      # of it. See the `push_permission_state` clause below.
      |> assign(:push_auto_denied, false)
      # Same rework: the blocked row names the browser and gives the real
      # clicks, so it needs the user agent. Read once at mount from the
      # connect info; it cannot change for the life of the socket.
      |> assign(:user_agent, connect_user_agent(socket))
      # Task 019ffb7b stage 6: seed the AppBadge hook with the count it must
      # paint before any inbox event fires. Without this the OS badge and the
      # title prefix stay blank on a fresh load until the next inbox change,
      # which for an already-behind user is exactly the moment the marker
      # matters most. Connected-only: a dead render has no client to receive
      # the event.
      |> push_app_badge()
      |> maybe_seed_meeting_state(raw_user_id)
      |> attach_hook(:track_path, :handle_params, fn _params, url, socket ->
        uri = URI.parse(url)

        # Hide the bar on any surface that represents the active meeting:
        # legacy chat surface (`/chat/<slug>` or `/chat/<space_id>` — the
        # link emitter uses `space.id` for org-scoped channels per ADR 0042
        # and `slug || id` otherwise) OR the canonical MeetingLive surface
        # (`/meetings/<meeting_slug>`).
        space_slug = socket.assigns[:meeting_space_slug]
        space_id = socket.assigns[:meeting_space_id]
        meeting_slug = socket.assigns[:meeting_slug]

        on_meeting_page =
          (space_slug && uri.path == "/chat/#{space_slug}") ||
            (space_id && uri.path == "/chat/#{space_id}") ||
            (meeting_slug && uri.path == "/meetings/#{meeting_slug}") || false

        {:cont,
         socket
         |> assign(:current_path, uri.path)
         |> assign(:on_meeting_page, on_meeting_page)}
      end)
      |> attach_hook(:roster_updates, :handle_info, fn
        # The async roster loader sends this once it knows the space_id.
        # Subscribe in the LV process so future PubSub messages land here,
        # and assign the bare space_id (so non-template readers like the
        # presence_diff handler below get a binary, not %AsyncResult{}).
        {:roster_resolved, sid}, socket when is_binary(sid) ->
          # Idempotent guard — assign_async could re-run on reset; only
          # subscribe once per space_id per LV.
          if socket.assigns[:roster_space_id] != sid do
            Phoenix.PubSub.subscribe(Platform.PubSub, "space_agents:#{sid}")
            ChatPubSub.subscribe(sid)
            {:halt, assign(socket, :roster_space_id, sid)}
          else
            {:halt, socket}
          end

        {:roster_resolved, nil}, socket ->
          # Async load found no spaces; nothing to subscribe to.
          {:halt, socket}

        {:roster_changed, space_id}, socket ->
          {:halt, refresh_roster(socket, space_id)}

        # Task 019fe4b1 stage 3: the presence loader runs in a Task, so — same
        # reason as `{:roster_resolved, sid}` above — it hands the resolved
        # space-id set back here and the LV process installs the subscriptions
        # itself. Subscribing from the Task would put the diffs in a mailbox
        # that dies with it.
        {:presence_spaces_resolved, space_ids}, socket when is_list(space_ids) ->
          already = socket.assigns[:presence_space_ids] || []

          Enum.each(space_ids -- already, &ChatPubSub.subscribe/1)

          {:halt, assign(socket, :presence_space_ids, Enum.uniq(already ++ space_ids))}

        # Global fan-out for the viewer-scoped union: any roster mutation
        # anywhere pings us, and `refresh_roster/2` re-scopes from the
        # viewer's visibility rather than trusting the space id.
        {:roster_changed_any, space_id}, socket ->
          {:halt, refresh_roster(socket, space_id)}

        %Phoenix.Socket.Broadcast{event: "presence_diff"}, socket ->
          # Any diff on ANY subscribed space invalidates the union, so rebuild
          # the whole thing rather than patching one space's slice — the badge
          # dedupes a person who is online in two spaces, and a per-space patch
          # cannot know whether their other space still holds them.
          result =
            ChatPresence.list_online_for_viewer(socket.assigns[:current_user_record])

          next =
            case {result, socket.assigns[:presence_list]} do
              # A transient failure must not blank a list we already had: keep
              # the last good answer rather than flashing the error state.
              # Deliberately only for a NON-EMPTY prior — an empty prior is not
              # an answer worth preserving, and letting it win would turn the
              # fallback into the very failure-renders-as-zero bug this task
              # exists to remove.
              {{:error, _}, %AsyncResult{result: {:ok, [_ | _]} = prev}} -> prev
              {other, _} -> other
            end

          {:halt, assign(socket, :presence_list, async_ok(socket.assigns[:presence_list], next))}

        {:meeting_joined, payload}, socket ->
          path = socket.assigns[:current_path] || "/"
          space_id = payload[:space_id]
          space_name = payload[:space_name]
          space_slug = payload[:space_slug] || space_id
          meeting_slug = payload[:meeting_slug]
          started_at = payload[:started_at] || DateTime.utc_now()

          # See the `:track_path` hook above for the three-shapes rationale.
          # The link the user came from could be `/chat/<slug>`,
          # `/chat/<space_id>` (post-ADR-0042 org-scoped channels), or the
          # canonical MeetingLive surface (`/meetings/<meeting_slug>`).
          on_meeting_page =
            (space_slug && path == "/chat/#{space_slug}") ||
              (space_id && path == "/chat/#{space_id}") ||
              (meeting_slug && path == "/meetings/#{meeting_slug}") || false

          socket =
            socket
            |> assign(:meeting_active, true)
            |> assign(:meeting_space_id, space_id)
            |> assign(:meeting_space_name, space_name)
            |> assign(:meeting_space_slug, space_slug)
            |> assign(:meeting_slug, meeting_slug)
            |> assign(:meeting_started_at, started_at)
            |> assign(:on_meeting_page, on_meeting_page)

          {:halt, socket}

        {:meeting_media_state, %{mic_enabled: mic, camera_enabled: camera}}, socket ->
          # Stage 3 (task 019ee06b): MeetingHooks broadcasts the authoritative
          # post-toggle mic/camera state on `MeetingState.topic(user_id)`.
          # The bar is a LiveComponent so it can't subscribe to PubSub itself —
          # forward the new values via `send_update/2`, the canonical Phoenix
          # pattern for pushing fresh assigns into a LiveComponent from its
          # host LV's `handle_info`. `Map.has_key?/2`-style override on the
          # component side keeps a `false` from the server from being lost.
          #
          # Stage 4 (task 019ee06b): also mirror into the shell's cached
          # `:shell_bar_*` assigns so the no-ChatLive bar-toggle fallback
          # (`shell_meeting_toggle/2`) always flips off the current truth.
          send_update(PlatformWeb.MeetingBarLive,
            id: "meeting-bar",
            mic_on: mic,
            camera_on: camera
          )

          {:halt,
           socket
           |> assign(:shell_bar_mic_on, mic)
           |> assign(:shell_bar_camera_on, camera)}

        {:meeting_left, _payload}, socket ->
          socket =
            socket
            |> assign(:meeting_active, false)
            |> assign(:meeting_space_id, nil)
            |> assign(:meeting_space_name, nil)
            |> assign(:meeting_space_slug, nil)
            |> assign(:meeting_slug, nil)
            |> assign(:meeting_started_at, nil)
            |> assign(:on_meeting_page, false)
            # Stage 4 (task 019ee06b): reset cached bar state on leave so a
            # fresh join starts from MeetingBarLive's mount defaults again.
            |> assign(:shell_bar_mic_on, true)
            |> assign(:shell_bar_camera_on, false)

          {:halt, socket}

        :meeting_bar_leave, socket ->
          # The mini-bar "Leave" button sends this. Two cleanup steps in
          # order: (1) stamp the durable participant row server-side via
          # `Meetings.leave_for_user/2` so a presence-driven roster refetch
          # after the COUNT decrement does NOT still see this user as
          # active, then (2) broadcast the leave event so the shell + any
          # other LV tabs for this user flip out of meeting mode. The bar
          # path used to skip (1) entirely — MeetingHooks' `stamp_local_left/1`
          # was the only leave-stamp writer and it only fires when the
          # in-chat LV (where MeetingHooks is attached) is still mounted.
          # If the user clicked Leave from /tasks, the chat LV was already
          # gone and the participant row stayed orphaned (task 019ee06b).
          space_id = socket.assigns[:meeting_space_id]
          uid = socket.assigns[:current_user_id]

          if space_id && uid do
            Meetings.leave_for_user(space_id, uid)
          end

          if uid do
            MeetingState.broadcast_left(uid)
          end

          socket =
            socket
            |> assign(:meeting_active, false)
            |> assign(:meeting_space_id, nil)
            |> assign(:meeting_space_name, nil)
            |> assign(:meeting_space_slug, nil)
            |> assign(:meeting_slug, nil)
            |> assign(:meeting_started_at, nil)
            |> assign(:on_meeting_page, false)
            |> assign(:shell_bar_mic_on, true)
            |> assign(:shell_bar_camera_on, false)

          {:halt, socket}

        _msg, socket ->
          {:cont, socket}
      end)
      # Tasks-board PubSub → recompute the badge count for the current user
      # (task 019e1322 Stage 3). Single Repo.aggregate, runs in the LV
      # process, idempotent. Filtering by assignee inside the query is
      # cheaper than filtering messages here.
      |> attach_hook(:tasks_count_refresh, :handle_info, fn
        {evt, _payload}, socket
        when evt in [:task_created, :task_updated, :task_deleted] ->
          new_count = compute_tasks_count(socket.assigns[:current_user_id])

          if new_count == socket.assigns[:tasks_count] do
            {:cont, socket}
          else
            {:cont, assign(socket, :tasks_count, new_count)}
          end

        _msg, socket ->
          {:cont, socket}
      end)
      # Inbox PubSub (inbox:<user_id>) → keep the icon-rail unread badge live.
      # On ANY inbox event, RECOMPUTE the count from the DB via
      # `Inbox.unread_count/1` (one indexed COUNT) and re-assign — exactly like
      # the Tasks badge (`compute_tasks_count`). The old running +1 / -1 counter
      # drifted: it only reacted to add/dismiss, so a `mark_read` or a
      # `dismiss_by_source` rollup dismissal (now broadcast as `:inbox_changed`)
      # silently desynced the badge from the list. Recomputing from the shared
      # `unread_scope/1` is the single source of truth, so badge and list agree.
      # We stay `:cont` so InboxLive's own `handle_info` still runs on `/inbox`.
      |> attach_hook(:inbox_count_refresh, :handle_info, fn
        {evt, _payload}, socket
        when evt in [:inbox_item_added, :inbox_item_dismissed, :inbox_item_read, :inbox_changed] ->
          new_count = compute_inbox_count(socket.assigns[:current_user_id])

          if new_count == socket.assigns.inbox_unread_count do
            {:cont, socket}
          else
            # Same recomputed number feeds both consumers: the rail badge
            # (assign) and the OS/app-icon + title-prefix markers (pushed to
            # the `AppBadge` hook). Pushing from here is why that hook needs
            # no PubSub subscription and no polling of its own — task
            # 019ffb7b stage 6.
            {:cont, socket |> assign(:inbox_unread_count, new_count) |> push_app_badge()}
          end

        _msg, socket ->
          {:cont, socket}
      end)
      |> attach_hook(:drawer_events, :handle_event, fn
        # Stage 4 (task 019ee06b): meeting-bar JS hook pushes these to the
        # active LiveView. On /chat the ChatLive's MeetingHooks owns the
        # toggle (assigns :mic_enabled / :camera_enabled, drives the local
        # LiveKit room, broadcasts via MeetingState) and `:halt`s the event
        # — we yield to it by returning `:cont` here. On any other route
        # (e.g. /tasks) MeetingHooks is NOT attached, so :mic_enabled is
        # absent and ShellLive becomes the single producer: flip the cached
        # bar-state, push the LiveKit toggle for the MeetingClient JS hook
        # listening on the global socket (meeting_client.js:37-38), and
        # broadcast the authoritative post-toggle pair via
        # `MeetingState.broadcast_media_state/2`. The broadcast loops back
        # into ShellLive's `:meeting_media_state` handler which `send_update`s
        # the bar — same path MeetingHooks uses, so the surfaces converge.
        "meeting_toggle_mic", _params, socket ->
          if Map.has_key?(socket.assigns, :mic_enabled) do
            {:cont, socket}
          else
            {:halt, shell_meeting_toggle(socket, :mic)}
          end

        "meeting_toggle_camera", _params, socket ->
          if Map.has_key?(socket.assigns, :camera_enabled) do
            {:cont, socket}
          else
            {:halt, shell_meeting_toggle(socket, :camera)}
          end

        # Mobile bottom-nav More tab → opens the long-tail sheet (task 019e1322 Stage 2)
        "open_more_sheet", _params, socket ->
          {:halt, assign(socket, :more_sheet_open, true)}

        "close_more_sheet", _params, socket ->
          {:halt, assign(socket, :more_sheet_open, false)}

        "toggle_sidebar", _params, socket ->
          next = !socket.assigns.sidebar_collapsed

          socket =
            socket
            |> assign(:sidebar_collapsed, next)
            |> push_event("sidebar_collapsed_changed", %{collapsed: next})

          {:halt, socket}

        "sidebar_hydrate", %{"collapsed" => collapsed}, socket
        when is_boolean(collapsed) ->
          # Idempotent: only re-assign if the hook's localStorage value differs
          # from the current default, to avoid an unnecessary re-render.
          if collapsed == socket.assigns.sidebar_collapsed do
            {:halt, socket}
          else
            {:halt, assign(socket, :sidebar_collapsed, collapsed)}
          end

        "toggle_presence_panel", _params, socket ->
          {:halt, assign(socket, :show_presence_panel, !socket.assigns.show_presence_panel)}

        "toggle_roster", _params, socket ->
          {:halt, assign(socket, :roster_open, !socket.assigns.roster_open)}

        "close_roster", _params, socket ->
          {:halt, assign(socket, :roster_open, false)}

        "dismiss_agent", %{"agent-id" => agent_id, "space-id" => space_id}, socket ->
          # ADR 0027: dismissed role removed — just remove the agent from roster
          Platform.Chat.remove_space_agent(space_id, agent_id)
          {:halt, refresh_roster(socket, space_id)}

        _event, _params, socket ->
          {:cont, socket}
      end)
      # Web-push wiring (task 019ffb7b stage 3). These four events come from
      # the `PushSubscribe` hook anchored in `shell.html.heex`, plus the
      # `enable_notifications` click that the chat banner and the `/inbox`
      # notification-state row (stage 4) emit. They lived on
      # `PlatformWeb.ChatLive` until this stage, which bound the whole feature
      # to `/chat`.
      #
      # The attach is the right home rather than the template alone: the
      # `:external_chat` and `:meet_member` live_sessions run this same
      # on_mount chain while rendering the chrome-less `:external` / `:guest`
      # layouts, so a template-only move would drop them.
      |> attach_hook(:push_events, :handle_event, fn
        "push_subscribed", %{"endpoint" => endpoint, "keys" => keys}, socket ->
          # `Platform.Push.subscribe/2` keys a subscription to a
          # `Chat.Participant` id, which is per-space. `:current_participant`
          # is assigned by ChatLive and MeetingLive and by nothing else, so
          # off those surfaces there is no participant row to key to and the
          # endpoint is dropped. See the stage-3 handoff: making registration
          # durable on every route needs the subscription re-keyed on the
          # user, or fanned out across the user's participant rows, and that
          # is a schema decision this stage does not take.
          if participant = socket.assigns[:current_participant] do
            Push.subscribe(participant.id, %{
              endpoint: endpoint,
              keys: %{p256dh: keys["p256dh"], auth: keys["auth"]}
            })
          end

          {:halt, assign(socket, :push_permission, "granted")}

        # `auto_denied` (stage 4 rework) is a SEPARATE fact, carried beside the
        # permission rather than folded into it: the five wire values above are
        # a fixed vocabulary that several readers key on by string, so a sixth
        # would break them silently. The hook sets it when the browser refused
        # without ever showing a dialog. See
        # `assets/js/hooks/push_subscribe.js`. Absent from older payloads and
        # from every non-denied state, hence the `== true`.
        "push_permission_state", %{"state" => state} = params, socket ->
          {:halt,
           socket
           |> assign(:push_permission, state)
           |> assign(:push_auto_denied, params["auto_denied"] == true)}

        "push_unsupported", _params, socket ->
          {:halt, assign(socket, :push_permission, "unsupported")}

        # pushManager.subscribe/1 rejected after the browser already granted
        # permission. Deliberately leaves :push_permission alone: a failed
        # subscribe is not a denial, and downgrading the assign would hide
        # the banner from a user who still has no working subscription.
        "push_subscribe_failed", params, socket ->
          Logger.warning(
            "web push subscribe failed: " <>
              inspect(Map.take(params, ["name", "message"]), printable_limit: 500)
          )

          {:halt, socket}

        # Fired by the chat banner and, from stage 4, by the `/inbox`
        # notification-state row (`PlatformWeb.Components.NotificationState`).
        # Handled here rather than per-LiveView so both call sites reach the
        # same handler on every surface that runs this on_mount chain.
        "enable_notifications", _params, socket ->
          {:halt, push_event(socket, "request_push_permission", %{})}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  # Raw user-agent header for the surfaces that vary copy by browser (today:
  # the `/inbox` blocked-notifications row). Requires `:user_agent` in the
  # LiveSocket's `connect_info` (see `PlatformWeb.Endpoint`), or the connected
  # mount would report nil and silently undo what the dead render worked out.
  #
  # `get_connect_info/2` raises anywhere but a root LiveView's mount, and
  # ChatLive also mounts nested under MeetingLive through `embedded_mount/3`.
  # Guarding on the same key LiveView checks means such a mount degrades to
  # the generic instruction instead of crashing the surface.
  defp connect_user_agent(socket) do
    if socket.private[:connect_info], do: get_connect_info(socket, :user_agent)
  end

  def default_agent_status do
    # Use non-blocking status() to avoid blocking mount
    status = WorkspaceBootstrap.status()

    result =
      case status do
        %{reachable?: true} -> :online
        %{configured?: true} -> :offline
        _ -> fallback_default_agent_status()
      end

    # Boot the runtime asynchronously if not already running
    unless status.reachable? do
      Task.start(fn -> WorkspaceBootstrap.boot() end)
    end

    result
  end

  defp fallback_default_agent_status do
    case default_persisted_agent() do
      %Agent{} = agent ->
        case AgentServer.start_agent(agent) do
          {:ok, pid} when is_pid(pid) ->
            :online

          {:error, _reason} ->
            if agent.status == "paused", do: :paused, else: :offline
        end

      nil ->
        :unknown
    end
  end

  defp default_persisted_agent do
    from(a in Agent,
      where: a.slug == "main" and a.status != "archived",
      limit: 1
    )
    |> Repo.one()
  rescue
    _ -> nil
  end

  @doc false
  # Synchronous refresh path used by PubSub (`{:roster_changed, sid}`,
  # `{:roster_changed_any, sid}`) and the `dismiss_agent` event. Wraps each
  # updated assign in `AsyncResult.ok/2` so the template's `<.async_result>`
  # component continues to see an `%AsyncResult{ok?: true}` shape after the
  # initial async load resolves.
  #
  # The incoming space_id is only a *ping*: the meter is the viewer-scoped
  # union over every visible space, so recomputing from that one space would
  # overwrite the union with a subset. We always recompute the full set.
  def refresh_roster(socket, _space_id) do
    %{roster_items: items, composite: composite, principal_name: principal_name} =
      visible_roster(socket.assigns[:roster_visibility] || :none)

    socket
    |> assign(:roster_items, async_ok(socket.assigns[:roster_items], items))
    |> assign(:principal_name, async_ok(socket.assigns[:principal_name], principal_name))
    |> assign(:composite_status, async_ok(socket.assigns[:composite_status], composite))
  end

  # ── Viewer-scoped agent roster ────────────────────────────────────────────
  #
  # The meter lives in the global shell chrome and renders on `/tasks`,
  # `/admin`, `/canvases` and every other surface where there is no current
  # space, so "the current space's roster" is undefined for most of the pages
  # it appears on. The scope is therefore org-wide but viewer-scoped: the
  # distinct set of agents on the rosters of spaces the viewer can see. The
  # previous behaviour (oldest non-archived space in the whole install) leaked
  # agents from orgs the viewer has no membership in.
  #
  # Returns `%{roster_items: [{roster_entry, status}], composite: composite,
  # principal_name: binary | nil, space_id: binary | nil}`.
  defp visible_roster(visibility) do
    rows =
      from(p in Chat.Participant,
        join: s in Platform.Chat.Space,
        as: :space,
        on: s.id == p.space_id,
        where: p.participant_type == "agent" and is_nil(s.archived_at),
        select: %{
          space_id: p.space_id,
          agent_id: p.participant_id,
          role: p.role,
          inserted_at: p.joined_at,
          space_updated_at: s.updated_at
        }
      )
      |> Tenancy.scope(visibility, binding: :space, field: :org_id)
      |> Repo.all()

    agents_by_id =
      case Enum.map(rows, & &1.agent_id) |> Enum.uniq() do
        [] -> %{}
        ids -> Repo.all(from(a in Agent, where: a.id in ^ids)) |> Map.new(&{&1.id, &1})
      end

    # Distinct on AGENT, not on participant row: an agent sitting on five
    # visible spaces must count once or the ratio's denominator inflates.
    # Principal rows sort first so the surviving row is the most meaningful
    # one for that agent.
    entries =
      rows
      |> Enum.sort_by(fn r -> {r.role != "principal", r.agent_id} end)
      |> Enum.uniq_by(& &1.agent_id)
      |> Enum.map(fn r ->
        %{
          space_id: r.space_id,
          agent_id: r.agent_id,
          role: r.role,
          agent: Map.get(agents_by_id, r.agent_id),
          inserted_at: r.inserted_at
        }
      end)

    roster_items = Enum.map(entries, fn e -> {e, SpaceAgentPresence.agent_status(e.agent)} end)
    composite = SpaceAgentPresence.composite(Enum.map(roster_items, fn {_e, s} -> s end))

    # `principal_name`'s MEANING CHANGED with this scope: with a viewer-scoped
    # union there is no single principal, so this is now the principal of the
    # viewer's most-recently-active visible space (nil when there is none).
    # The assign is kept because `shell.html.heex:107` gates the whole Agents
    # button on it, and its `:186-195` legacy-dot branch still covers nil.
    newest = rows |> Enum.sort_by(& &1.space_updated_at, {:desc, DateTime}) |> List.first()

    principal_row =
      case newest do
        nil ->
          nil

        %{space_id: sid} ->
          Enum.find(rows, fn r -> r.space_id == sid and r.role == "principal" end) ||
            Enum.find(rows, fn r -> r.role == "principal" end)
      end

    principal_name =
      case principal_row && Map.get(agents_by_id, principal_row.agent_id) do
        %Agent{name: name} -> name
        _ -> nil
      end

    %{
      roster_items: roster_items,
      composite: composite,
      principal_name: principal_name,
      space_id: newest && newest.space_id
    }
  end

  @doc """
  Canonical wrap-or-rewrap helper for the AsyncResult-bound shell assigns
  (`:roster_items`, `:composite_status`, `:principal_name`, `:presence_list`).

  Reuses the existing `%AsyncResult{}` when present so LV diffing keeps the
  assign identity stable; falls back to wrapping a fresh `AsyncResult.loading/0`
  for synchronous callers (e.g. `refresh_roster/2` on a non-async-bootstrapped
  socket, or cross-LV writers like `PlatformWeb.ChatLive.PresenceHooks` that
  update `:composite_status` from `apply_agent_typing/3`).

  Public so cross-LV writers can keep the assign in the shape the
  `<.async_result>` template component requires; assigning a bare atom would
  crash the render with `FunctionClauseError`.
  """
  def async_ok(%AsyncResult{} = existing, value), do: AsyncResult.ok(existing, value)
  def async_ok(_other, value), do: AsyncResult.ok(AsyncResult.loading(), value)

  # Async loader: runs in a Task, returns {:ok, %{...assigns}} for the four
  # roster keys. Sends {:roster_resolved, sid} back to the LV so it can install
  # PubSub subscribes on its own process (Tasks can't subscribe on the LV's
  # behalf — messages would land in the wrong mailbox).
  defp async_load_roster(lv_pid, visibility) do
    %{
      roster_items: items,
      composite: composite,
      principal_name: principal_name,
      space_id: sid
    } = visible_roster(visibility)

    # `:roster_resolved` still carries a single space id — it drives the
    # per-space ChatPubSub subscription, which remains per-space. The
    # viewer-scoped union is kept fresh by the global topic instead.
    send(lv_pid, {:roster_resolved, sid})

    {:ok,
     %{
       roster_items: items,
       composite_status: composite,
       principal_name: principal_name
     }}
  end

  # Task 019fe4b1 stage 3: the shell presence badge is the VIEWER's answer, not
  # the oldest space's. The observable set comes from
  # `Chat.list_viewer_presence_space_ids/1` (membership is the grant, resolved
  # org visibility is the fence) and the online union from
  # `Presence.list_online_for_viewer/1`.
  #
  # The `{:ok, list}` / `{:error, reason}` tuple is stored AS the assign value
  # rather than being unwrapped here, because "nobody else is online" and "the
  # read failed" are different facts and the template has to be able to render
  # them differently. Unwrapping to `[]` on error is exactly the bug this task
  # exists to remove.
  defp async_load_presence(lv_pid, user_record) do
    space_ids = Chat.list_viewer_presence_space_ids(user_record)
    send(lv_pid, {:presence_spaces_resolved, space_ids})

    {:ok, %{presence_list: ChatPresence.list_online_for_viewer(user_record)}}
  end

  defp maybe_subscribe_meeting_state(socket, raw_user_id) when is_binary(raw_user_id) do
    MeetingState.subscribe(raw_user_id)
    socket
  end

  defp maybe_subscribe_meeting_state(socket, _), do: socket

  # On a fresh shell mount (e.g. after a `live_navigate`), the one-shot
  # `:meeting_joined` PubSub event from the original join is long gone — so
  # the mini-bar would render hidden even though the user is still in a
  # meeting. Synchronously hydrate from the ETS-backed `Platform.Meetings.State`
  # cache (stage 1) so the bar paints correctly on first render.
  #
  # Only runs on the WS-connected mount (skipping the static/disconnected
  # render) — matches the existing async-load pattern. ETS lookup is
  # lock-free so it's cheap even at peak.
  defp maybe_seed_meeting_state(socket, raw_user_id) when is_binary(raw_user_id) do
    if connected?(socket) do
      seed_meeting_state_from_storage(socket, raw_user_id)
    else
      socket
    end
  end

  defp maybe_seed_meeting_state(socket, _), do: socket

  defp seed_meeting_state_from_storage(socket, raw_user_id) when is_binary(raw_user_id) do
    case MeetingState.get_for_user(raw_user_id) do
      %{
        space_id: space_id,
        space_name: space_name,
        space_slug: space_slug,
        meeting_slug: meeting_slug,
        started_at: started_at
      } ->
        socket
        |> assign(:meeting_active, true)
        |> assign(:meeting_space_id, space_id)
        |> assign(:meeting_space_name, space_name)
        |> assign(:meeting_space_slug, space_slug)
        |> assign(:meeting_slug, meeting_slug)
        |> assign(:meeting_started_at, started_at)

      _ ->
        socket
    end
  end

  defp seed_meeting_state_from_storage(socket, _), do: socket

  # Derive a human-readable module name from the LiveView module atom.
  defp derive_active_module(view) do
    case view do
      PlatformWeb.ChatLive ->
        "Chat"

      PlatformWeb.ActivityLive ->
        "Activity"

      PlatformWeb.ControlCenterLive ->
        "Agent Resources"

      PlatformWeb.TasksLive ->
        "Tasks"

      PlatformWeb.MeetingLive ->
        "Meetings"

      PlatformWeb.SkillsLive ->
        "Skills"

      PlatformWeb.ChangelogLive ->
        "Changelog"

      PlatformWeb.UsageLive ->
        "Usage"

      PlatformWeb.AdminPromptsLive ->
        "Admin"

      PlatformWeb.AdminFederationLive ->
        "Admin"

      _ ->
        view
        |> Module.split()
        |> List.last()
        |> String.replace("Live", "")
        |> String.replace("_", " ")
    end
  end

  # Stage 4 (task 019ee06b): no-ChatLive fallback for bar-initiated
  # `meeting_toggle_mic` / `meeting_toggle_camera` events from the
  # MeetingBar JS hook. Three side effects, in order:
  #
  #   1. Flip the corresponding cached `:shell_bar_*` assign so a rapid
  #      double-click reads the post-toggle truth, not the stale default.
  #   2. `push_event(socket, "toggle-mic"|"toggle-camera", %{})` — the
  #      MeetingClient JS hook listens on the global LiveView socket
  #      (`meeting_client.js:37-38`), so a push from ANY mounted LV
  #      reaches LiveKit. This is what actually mutes/unmutes the local
  #      track when MeetingHooks isn't mounted.
  #   3. Broadcast the authoritative pair via
  #      `MeetingState.broadcast_media_state/2`. The broadcast loops back
  #      into this same shell's `:meeting_media_state` handler, which
  #      `send_update`s the bar — same convergence path as MeetingHooks
  #      so every consumer (other tabs on /chat, other shells) ends in
  #      lockstep.
  #
  # Anonymous shells (no `current_user_id`) skip the broadcast — there's
  # no per-user topic to fan out on. We still flip the local cache so a
  # logged-in-soon-to-be flow doesn't drift.
  defp shell_meeting_toggle(socket, :mic) do
    new_mic = !socket.assigns.shell_bar_mic_on
    camera = socket.assigns.shell_bar_camera_on

    socket = assign(socket, :shell_bar_mic_on, new_mic)

    if uid = socket.assigns[:current_user_id] do
      MeetingState.broadcast_media_state(uid, %{
        mic_enabled: new_mic,
        camera_enabled: camera
      })
    end

    push_event(socket, "toggle-mic", %{})
  end

  defp shell_meeting_toggle(socket, :camera) do
    new_camera = !socket.assigns.shell_bar_camera_on
    mic = socket.assigns.shell_bar_mic_on

    socket = assign(socket, :shell_bar_camera_on, new_camera)

    if uid = socket.assigns[:current_user_id] do
      MeetingState.broadcast_media_state(uid, %{
        mic_enabled: mic,
        camera_enabled: new_camera
      })
    end

    push_event(socket, "toggle-camera", %{})
  end

  # Initial badge count for the bottom-nav Tasks tab. Wraps Platform.Tasks
  # so the call site stays compact + we can swap in clear-on-visit logic
  # later without touching mount.
  defp compute_tasks_count(user_id) do
    Tasks.count_in_progress_for_user(user_id)
  rescue
    # Fail-open: a count error shouldn't block the shell from mounting.
    # Bottom-nav just renders 0 → badge hidden. Logged for observability.
    e ->
      require Logger
      Logger.warning("[ShellLive] tasks_count compute failed: #{inspect(e)}")
      0
  end

  # Initial unread count for the desktop icon-rail Inbox badge. Fail-open like
  # compute_tasks_count — a count error renders 0 (badge hidden) rather than
  # blocking the shell mount. Anonymous/non-user mounts (nil id) are 0 too.
  defp compute_inbox_count(user_id) when is_binary(user_id) do
    Inbox.unread_count(user_id)
  rescue
    e ->
      require Logger
      Logger.warning("[ShellLive] inbox_count compute failed: #{inspect(e)}")
      0
  end

  defp compute_inbox_count(_), do: 0

  # Task 019ffb7b stage 6. Mirror the already-computed `:inbox_unread_count`
  # onto the `AppBadge` JS hook (`assets/js/hooks/app_badge.js`), which paints
  # `navigator.setAppBadge` on the app icon of an installed window and a
  # `(3) ` document-title prefix in a plain tab.
  #
  # Server-pushed rather than client-polled: this module already recomputes
  # the count on every inbox event, so the hook needs neither a timer nor a
  # second PubSub subscription. There is exactly one counter in the system.
  #
  # `count` is the raw integer because `setAppBadge` takes a Number and the
  # platform formats large values itself. `label` is `IconRail.badge_text/1`
  # — the same "99+" cap the rail pill renders, reused rather than
  # reimplemented, so the two markers can never show different numbers.
  # Both are sent in one event so the client never has to derive one from
  # the other.
  #
  # Connected-only: `push_event/3` on a disconnected mount has no client to
  # deliver to, and the connected mount that follows pushes the same value.
  defp push_app_badge(socket) do
    if connected?(socket) do
      count = socket.assigns[:inbox_unread_count] || 0
      push_event(socket, "app_badge", %{count: count, label: IconRail.badge_text(count)})
    else
      socket
    end
  end
end
