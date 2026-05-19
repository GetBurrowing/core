defmodule PlatformWeb.ShellLive do
  @moduledoc "Mount hook that injects shell assigns for all authenticated surfaces."

  import Ecto.Query
  import Phoenix.Component
  import Phoenix.LiveView

  alias Phoenix.LiveView.AsyncResult
  alias Platform.Accounts
  alias Platform.Agents.{Agent, AgentServer, WorkspaceBootstrap}
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.SpaceAgentPresence
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Repo
  alias Platform.Tasks

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

        socket
        |> assign_async(
          [:roster_items, :composite_status, :principal_name],
          fn -> async_load_roster(lv_pid) end
        )
        |> assign_async(:presence_list, fn -> async_load_presence(lv_pid) end)
        |> maybe_subscribe_meeting_state(raw_user_id)
      else
        socket
      end

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_record, user_record)
      |> assign(:current_user_id, raw_user_id)
      |> assign(:current_path, "/")
      |> assign(:agent_status, default_agent_status())
      |> assign(:more_sheet_open, false)
      |> assign(:sidebar_collapsed, false)
      |> assign(:active_module, active_module)
      |> assign(:is_fabrikam_user, is_fabrikam_user)
      |> assign(:tasks_count, compute_tasks_count(raw_user_id))
      |> assign(:roster_open, false)
      |> assign(:show_presence_panel, false)
      |> assign(:captions_enabled, false)
      |> assign(:meeting_active, false)
      |> assign(:meeting_space_id, nil)
      |> assign(:meeting_space_name, nil)
      |> assign(:meeting_space_slug, nil)
      |> assign(:meeting_started_at, nil)
      |> assign(:on_meeting_page, false)
      |> attach_hook(:track_path, :handle_params, fn _params, url, socket ->
        uri = URI.parse(url)

        on_meeting_page =
          case socket.assigns[:meeting_space_slug] do
            nil -> false
            slug -> uri.path == "/chat/#{slug}"
          end

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

        %Phoenix.Socket.Broadcast{event: "presence_diff"}, socket ->
          list =
            try do
              if sid = socket.assigns[:roster_space_id] do
                build_presence_list(sid)
              else
                []
              end
            rescue
              _ ->
                case socket.assigns[:presence_list] do
                  %AsyncResult{result: prev} when is_list(prev) -> prev
                  prev when is_list(prev) -> prev
                  _ -> []
                end
            end

          {:halt, assign(socket, :presence_list, async_ok(socket.assigns[:presence_list], list))}

        {:meeting_joined, %{space_id: space_id, space_name: space_name}}, socket ->
          path = socket.assigns[:current_path] || "/"
          space = Chat.get_space(space_id)
          slug = if space, do: space.slug || space_id, else: space_id

          socket =
            socket
            |> assign(:meeting_active, true)
            |> assign(:meeting_space_id, space_id)
            |> assign(:meeting_space_name, space_name)
            |> assign(:meeting_space_slug, slug)
            |> assign(:meeting_started_at, DateTime.utc_now())
            |> assign(:on_meeting_page, path == "/chat/#{slug}")

          {:halt, socket}

        {:meeting_left, _payload}, socket ->
          socket =
            socket
            |> assign(:meeting_active, false)
            |> assign(:meeting_space_id, nil)
            |> assign(:meeting_space_name, nil)
            |> assign(:meeting_space_slug, nil)
            |> assign(:meeting_started_at, nil)
            |> assign(:on_meeting_page, false)

          {:halt, socket}

        :meeting_bar_leave, socket ->
          # The mini-bar "Leave" button sends this — broadcast the leave event
          if uid = socket.assigns[:current_user_id] do
            MeetingState.broadcast_left(uid)
          end

          socket =
            socket
            |> assign(:meeting_active, false)
            |> assign(:meeting_space_id, nil)
            |> assign(:meeting_space_name, nil)
            |> assign(:meeting_space_slug, nil)
            |> assign(:meeting_started_at, nil)
            |> assign(:on_meeting_page, false)

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
      |> attach_hook(:drawer_events, :handle_event, fn
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

        "toggle_captions", _params, socket ->
          {:halt, assign(socket, :captions_enabled, !socket.assigns.captions_enabled)}

        "dismiss_agent", %{"agent-id" => agent_id, "space-id" => space_id}, socket ->
          # ADR 0027: dismissed role removed — just remove the agent from roster
          Platform.Chat.remove_space_agent(space_id, agent_id)
          {:halt, refresh_roster(socket, space_id)}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
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
  # Synchronous refresh path used by PubSub (`{:roster_changed, sid}`) and the
  # `dismiss_agent` event. Wraps each updated assign in `AsyncResult.ok/2` so
  # the template's `<.async_result>` component continues to see an
  # `%AsyncResult{ok?: true}` shape after the initial async load resolves.
  def refresh_roster(socket, space_id) when is_binary(space_id) do
    roster_items = SpaceAgentPresence.roster_with_status(space_id)

    principal =
      Enum.find(roster_items, fn {sa, _status} -> sa.role == "principal" end)

    principal_name =
      case principal do
        {sa, _} -> sa.agent.name
        nil -> nil
      end

    active_statuses =
      roster_items
      |> Enum.reject(fn {sa, _} -> sa.role == "dismissed" end)
      |> Enum.map(fn {_sa, status} -> status end)

    composite = SpaceAgentPresence.composite_status(active_statuses)

    socket
    |> assign(:roster_items, async_ok(socket.assigns[:roster_items], roster_items))
    |> assign(:principal_name, async_ok(socket.assigns[:principal_name], principal_name))
    |> assign(:composite_status, async_ok(socket.assigns[:composite_status], composite))
  end

  def refresh_roster(socket, _), do: socket

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
  defp async_load_roster(lv_pid) do
    case first_space() do
      nil ->
        send(lv_pid, {:roster_resolved, nil})

        {:ok,
         %{
           roster_items: [],
           composite_status: :none,
           principal_name: nil
         }}

      %{id: sid} ->
        items = SpaceAgentPresence.roster_with_status(sid)

        principal_name =
          case Enum.find(items, fn {sa, _} -> sa.role == "principal" end) do
            {sa, _} -> sa.agent.name
            nil -> nil
          end

        active_statuses =
          items
          |> Enum.reject(fn {sa, _} -> sa.role == "dismissed" end)
          |> Enum.map(fn {_sa, status} -> status end)

        composite = SpaceAgentPresence.composite_status(active_statuses)

        send(lv_pid, {:roster_resolved, sid})

        {:ok,
         %{
           roster_items: items,
           composite_status: composite,
           principal_name: principal_name
         }}
    end
  end

  defp async_load_presence(_lv_pid) do
    case first_space() do
      nil -> {:ok, %{presence_list: []}}
      %{id: sid} -> {:ok, %{presence_list: build_presence_list(sid)}}
    end
  end

  defp maybe_subscribe_meeting_state(socket, raw_user_id) when is_binary(raw_user_id) do
    MeetingState.subscribe(raw_user_id)
    socket
  end

  defp maybe_subscribe_meeting_state(socket, _), do: socket

  defp build_presence_list(space_id) do
    online_ids =
      space_id
      |> ChatPresence.list_space()
      |> Map.keys()
      |> MapSet.new()

    space_id
    |> Chat.list_participants()
    |> Enum.filter(&(&1.participant_type == "user"))
    |> Enum.map(fn p ->
      %{name: p.display_name || "User", online: MapSet.member?(online_ids, p.participant_id)}
    end)
    |> Enum.sort_by(& &1.name)
  rescue
    _ -> []
  end

  defp first_space do
    from(s in Platform.Chat.Space,
      where: is_nil(s.archived_at),
      order_by: [asc: s.inserted_at],
      limit: 1
    )
    |> Repo.one()
  rescue
    _ -> nil
  end

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
end
