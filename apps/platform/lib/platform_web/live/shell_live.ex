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
  alias Platform.Chat.SpaceAgentPresence
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Push
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias PlatformWeb.Components.IconRail
  alias PlatformWeb.SpaceTopics

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
      # Task 019fe4b1 stage 3: the shell's chat coverage is no longer scoped to
      # one arbitrary space. It is a LIST of space ids, so a `presence_diff` or
      # a `{:new_message, _}` on any of them can rebuild what the shell shows.
      #
      # Task 01a01a1b stage 2: this assign NAMES THE SET CURRENTLY HELD by
      # the `:presence` owner. The `{:presence_spaces_resolved, ids}` branch
      # below reconciles against the incoming set — holding the ids that
      # appeared, releasing the ids that dropped out — and then assigns
      # exactly that incoming set. It no longer accumulates the union of
      # every set resolved during the session.
      #
      # Task 01a01f4c: the set is now `Chat.list_member_space_ids/1`, which is
      # participation-only. It is named `:shell_chat_space_ids` and NOT
      # `:presence_space_ids`, because it is deliberately WIDER than what
      # `Chat.Presence.list_online_for_viewer/1` may read: that function
      # re-derives its own org-fenced set. Scoping a presence render off this
      # assign, exactly the use the old name invited, is a cross-org identity
      # leak. It is also NOT `:subscribed_space_ids`, which belongs to
      # `ChatLive` on this same socket.
      #
      # Both the hold and the release go through `PlatformWeb.SpaceTopics`,
      # which owns the single `chat:space:<id>` registration on this pid, so a
      # release here unsubscribes only when no other surface still holds the
      # space. Do not subscribe or unsubscribe `chat:space:<id>` directly from
      # this module.
      |> assign(:shell_chat_space_ids, [])

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

        # Task 01a01a1b stage 2: seed the holder map before ANY surface takes
        # out a `chat:space:<id>` subscription. This on_mount hook runs before
        # the view's own `mount/3`, so seeding here covers ChatLive and
        # TasksLive too; `ensure_holders/1` is idempotent and never discards
        # live holders.
        socket = SpaceTopics.ensure_holders(socket)

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
          fn -> async_load_roster(lv_pid, roster_visibility, raw_user_id) end
        )
        |> assign_async(:presence_list, fn -> async_load_presence(lv_pid, user_record) end)
        |> maybe_subscribe_meeting_state(raw_user_id)
      else
        socket
      end

    # Task 01a00066 stage 3. Self-heal stale inbox rows ONCE per mount, right
    # before the first `Inbox.unread_count/1` below, so the badge that renders
    # is computed from reconciled state. This on_mount runs on every surface
    # including the external `chat.` host's `:external_chat` live_session,
    # which is the whole point: `/inbox` is fenced off from external users by
    # `PlatformWeb.Plugs.ExternalUserScope`, so `InboxLive.load_items/1` — the
    # other reconcile entry point — is unreachable for exactly the users who
    # most need the healing. Mount-only is deliberate: the
    # `:inbox_count_refresh` hook fires on every inbox PubSub event and
    # reconciling there would turn one badge broadcast into a scan-and-write
    # storm that can re-enter itself via `{:inbox_changed, …}`.
    reconcile_inbox(raw_user_id)

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
      # Task 01a01b29 stage 1: one chat-unread total for the whole viewer, so
      # the rail can show it from /tasks without a second tab. Seeded here so
      # the number is right on first paint rather than only after the next
      # chat event. Stage 2 renders it; nothing reads this assign yet.
      |> assign(:chat_unread_count, compute_chat_unread(user_record))
      # Coalescing flag for the deferred recompute below. See
      # `queue_chat_unread_refresh/1`.
      |> assign(:chat_unread_refresh_queued, false)
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
      # Task 019ffe52 fix B: the browser granted permission and the device
      # still did not get registered. Deliberately a fact beside
      # `:push_permission` rather than a sixth value of it, exactly as
      # `:push_auto_denied` above: the five wire values are a fixed vocabulary
      # that several readers key on by string, and the honest state here needs
      # two facts anyway ("permission granted" AND "registration failed"),
      # which one string cannot carry.
      #
      # WHY a reason and not a boolean. It shipped as `true`/`false` and Marlowe
      # rejected the copy on review: "If we are going to tell the user
      # something is broken, we need to tell them how to fix (whether they need
      # to do something, or we need to do something)." That question cannot be
      # answered from a boolean, because the two failure routes have opposite
      # answers. `:no_participant` means the user is in no conversations and
      # there is nothing for them to do; `:subscribe_failed` means the browser
      # refused the subscribe and a reload can genuinely change it. One flag
      # covering both forced the copy vague, which is what she caught.
      #
      # nil | :no_participant | :subscribe_failed.
      |> assign(:push_registration_failed, nil)
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

        # Task 01a01b29 stage 1: navigating INTO a channel is what calls
        # `mark_read_at_channel_tip/2` (`chat/messages_hooks.ex`), which moves
        # the read watermark for that space. Queue the recompute rather than
        # running it inline: the same one-mailbox-turn deferral used for
        # `{:new_message, _}` puts it after that write, so the number reflects
        # the read instead of the state just before it.
        #
        # Gated on `chat_surface?/1` because `MessagesHooks.enter_space/3` and
        # `enter_space_anchored/4` are called from `chat_live.ex` and nowhere
        # else, so `/chat` and `/chat/:space_slug` are the complete set of
        # paths that can move a watermark. Queuing on every navigation of every
        # surface would schedule a recompute that provably cannot change the
        # answer, and the cost is not theoretical: the extra mailbox turn is
        # enough to lose an unrelated `send_update/2` race in the meeting-bar
        # tests. Measured, not guessed.
        socket =
          socket
          |> assign(:current_path, uri.path)
          |> assign(:on_meeting_page, on_meeting_page)

        if chat_surface?(uri.path) do
          {:cont, queue_chat_unread_refresh(socket)}
        else
          {:cont, socket}
        end
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
            socket = release_roster_subscriptions(socket)

            {:halt,
             socket
             |> SpaceTopics.hold(sid, :roster)
             # Task 01a0691d stage 3: through `SpaceTopics` too, for the same
             # reason `chat:space:<id>` is — `/meetings` and the quickmeet now
             # want this topic on the same pid. See the release below.
             |> SpaceTopics.hold_agents(sid, :roster)
             |> assign(:roster_space_id, sid)}
          else
            {:halt, socket}
          end

        {:roster_resolved, nil}, socket ->
          # Async load found no spaces; nothing to subscribe to.
          {:halt, socket}

        # Task 01a0691d stage 3. `MeetingLive` and `MeetingHooks` fold this
        # same message into the People tab's invite rows, and they run BEHIND
        # this hook, which used to halt it for every view — so the topic was
        # live, the broadcast was real, and nothing downstream could ever see
        # it.
        #
        # Forwarding it unconditionally is NOT the fix. The
        # `:authenticated`/`:admin` sessions mount views with no `handle_info`
        # catch-all (`ChangelogLive` has exactly one clause; also
        # `AdminFederationLive`, `RecoveryLive`), and a forwarded
        # `{:roster_changed, _}` would `FunctionClauseError` them. So a view
        # OPTS IN with `:roster_changed_downstream?` and everyone else keeps
        # the halt they have always had. The shell refreshes its own roster on
        # both branches; only the propagation differs. Precedent for `:cont`
        # from this hook: the `{:participant_left, _}` clause below.
        {:roster_changed, space_id}, socket ->
          socket = refresh_roster(socket, space_id)

          if socket.assigns[:roster_changed_downstream?] do
            {:cont, socket}
          else
            {:halt, socket}
          end

        # Task 01a01a1b stage 3. The shell releases ITS OWN holds when the
        # viewer loses access to a space, because nobody else may.
        #
        # Before this task ChatLive's `{:participant_left, _}` clause called a
        # bare `ChatPubSub.unsubscribe/1`, which is `Registry.unregister/2` and
        # therefore destroyed the shell's registration along with chat's. Now
        # that each surface releases only its own hold, chat letting go is no
        # longer enough: the shell's `:presence` hold kept the topic alive and a
        # revoked channel went on delivering `{:new_message, _}` — the exact
        # leak task 01a0181f closed. Correct ownership has to be paired with the
        # owner actually doing its half.
        #
        # `:shell_chat_space_ids` is `Chat.list_member_space_ids/1`, which is
        # precisely "the spaces this viewer has a participant row in". So this
        # is not a second predicate that could drift from that one — the row
        # this event announces the deletion of IS the row that query selects
        # on, and the space has left the set by construction.
        #
        # `:cont`, not `:halt`: ChatLive's own release clause is downstream of
        # this hook and has to see the same event.
        {:participant_left, %{participant_type: "user"} = participant}, socket ->
          if participant.participant_id == socket.assigns[:current_user_id] do
            sid = participant.space_id
            held = socket.assigns[:shell_chat_space_ids] || []

            socket =
              socket
              |> SpaceTopics.release(sid, :presence)
              |> assign(:shell_chat_space_ids, List.delete(held, sid))

            # The roster hold is a single space, so this is a no-op unless the
            # revoked space happens to be the one the roster resolved to.
            socket =
              if socket.assigns[:roster_space_id] == sid do
                socket
                |> release_roster_subscriptions()
                |> assign(:roster_space_id, nil)
              else
                socket
              end

            {:cont, socket}
          else
            {:cont, socket}
          end

        # Task 019fe4b1 stage 3: the presence loader runs in a Task, so — same
        # reason as `{:roster_resolved, sid}` above — it hands the resolved
        # space-id set back here and the LV process installs the subscriptions
        # itself. Subscribing from the Task would put the diffs in a mailbox
        # that dies with it.
        {:presence_spaces_resolved, space_ids}, socket when is_list(space_ids) ->
          # Task 01a01a1b stage 2, finding 2. This used to be append-only:
          # it subscribed `space_ids -- already` and assigned
          # `Enum.uniq(already ++ space_ids)`, so a space that dropped out of
          # the viewer's presence set kept both its live subscription and its
          # entry in the assign, forever. Now it is a genuine reconcile
          # against the incoming set, and the assign names what is held.
          current = socket.assigns[:shell_chat_space_ids] || []

          socket =
            Enum.reduce(space_ids -- current, socket, fn id, acc ->
              SpaceTopics.hold(acc, id, :presence)
            end)

          socket =
            Enum.reduce(current -- space_ids, socket, fn id, acc ->
              SpaceTopics.release(acc, id, :presence)
            end)

          socket = assign(socket, :shell_chat_space_ids, space_ids)

          # Task 01a01b29 stage 1: between the mount-time seed and this branch
          # resolving, this process hears nothing, so a message arriving in
          # that window would stay invisible until the next event. Recomputing
          # once the subscriptions are installed closes the window
          # deterministically.
          #
          # Skipped for an empty resolved set: `total_unread_for_viewer/1`
          # intersects the counts with a KIND-FILTERED SUBSET of this list, so
          # with no spaces at all the recompute can only reproduce the seed's
          # 0. Same reason as the `chat_surface?/1` gate above, and it keeps a
          # viewer with no channels from paying a mailbox turn on every mount.
          if space_ids == [] do
            {:halt, socket}
          else
            {:halt, queue_chat_unread_refresh(socket)}
          end

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
      # Chat PubSub (`chat:space:<id>`) -> keep the shell's chat-unread total
      # live on every surface, /tasks included (task 01a01b29 stage 1).
      #
      # THIS HOOK TAKES OUT NO SUBSCRIPTION, DELIBERATELY. The
      # `{:presence_spaces_resolved, _}` branch above already subscribed this
      # process to `chat:space:<id>` for every space the viewer participates
      # in. That set CONTAINS the set counted here: the count adds a kind
      # allow-list on top of the same participation predicate, so every counted
      # space is one this process hears from, and the extra subscriptions cost
      # a recompute that returns the same integer. `Phoenix.PubSub`'s registry
      # runs `keys: :duplicate`, so subscribing a topic this pid already holds
      # registers it twice and every broadcast then fires `handle_info` twice,
      # while a single `unsubscribe` (`Registry.unregister/2`) drops ALL of
      # this pid's registrations for it. That pair is how the unread badge died
      # in `cb429830`. This is a consumer of an existing subscription and must
      # stay one.
      |> attach_hook(:chat_count_refresh, :handle_info, fn
        {evt, _payload}, socket when evt in [:new_message, :message_deleted] ->
          # `:cont`, never `:halt`. On `/chat`, `ChatLive`'s `MessagesHooks`
          # consumes the same `{:new_message, _}`; halting here would kill the
          # message list.
          {:cont, queue_chat_unread_refresh(socket)}

        :chat_unread_refresh, socket ->
          # `:halt` because nothing else consumes this message and an
          # unhandled `handle_info` logs a warning.
          new_count = compute_chat_unread(socket.assigns[:current_user_record])
          socket = assign(socket, :chat_unread_refresh_queued, false)

          if new_count == socket.assigns[:chat_unread_count] do
            {:halt, socket}
          else
            {:halt, assign(socket, :chat_unread_count, new_count)}
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
          # ADR 0027: dismissed role removed — just remove the agent from roster.
          #
          # `space_id` is client-supplied and this hook runs on SIX
          # live_sessions, so the membership check lives in
          # `Chat.remove_space_agent/3` rather than here. ShellLive assigns
          # `:current_user_id` (NOT `:user_id`), it is nil on anonymous shells,
          # and bracket access is what keeps that a `{:user, nil}` actor —
          # which `SpaceAccess` DENIES rather than raising on.
          Platform.Chat.remove_space_agent(
            {:user, socket.assigns[:current_user_id]},
            space_id,
            agent_id
          )

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
          # is assigned by ChatLive and MeetingLive and by nothing else, so off
          # those surfaces this clause used to have nothing to key to and threw
          # the endpoint away.
          #
          # It no longer needs to. `Push.subscribe_for_user/2` files the device
          # against a user-typed participant row the user already has, and
          # `Push.distinct_endpoint_subscriptions/1` resolves a user's devices
          # across ALL of their user-typed rows, so one row is reachable from
          # every conversation. No re-keying of `push_subscriptions` required
          # (task 019ffe52).
          #
          # A user in no space at all still has nowhere to file to, so the
          # failure branch survives fix A and has to be reported honestly
          # (task 019ffe52 fix B). This clause used to assign "granted"
          # unconditionally, OUTSIDE the write, so a registration that wrote
          # nothing still told the user notifications were on.
          #
          # On success: the permission moves to "granted" and the failure reason
          # clears to nil, so a retry that works undoes an earlier failure. On
          # failure: `:push_permission` is left exactly as it was, because this
          # event is not evidence about the browser's permission either way,
          # and `:push_registration_failed` carries the REASON instead.
          #
          # `:no_participant` is the reason every failure on this path reduces
          # to for the user: their account is in no conversation, so there is
          # no row to key a subscription to. `:no_user` (no session on the
          # socket) and a changeset error are not distinct from the user's
          # point of view and there is nothing they could do about either, so
          # they take the same copy rather than inventing states nobody can
          # act on. The specific reason still reaches the log below.
          attrs = %{
            endpoint: endpoint,
            keys: %{p256dh: keys["p256dh"], auth: keys["auth"]}
          }

          result =
            case {socket.assigns[:current_participant], socket.assigns[:current_user_id]} do
              {%{id: participant_id}, _} -> Push.subscribe(participant_id, attrs)
              {nil, user_id} when is_binary(user_id) -> Push.subscribe_for_user(user_id, attrs)
              {nil, _} -> {:error, :no_user}
            end

          case result do
            {:ok, _subscription} ->
              {:halt,
               socket
               |> assign(:push_registration_failed, nil)
               |> assign(:push_permission, "granted")}

            {:error, reason} ->
              Logger.warning(
                "web push registration not stored: " <>
                  inspect(reason, printable_limit: 500)
              )

              {:halt, assign(socket, :push_registration_failed, :no_participant)}
          end

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
        #
        # This is the client-side twin of the `push_subscribed` failure branch
        # above (task 019ffe52 fix B): same assign, DIFFERENT reason. It first
        # shipped setting the same boolean as that branch, on the argument that
        # one user-visible outcome reached from two directions should be one
        # state. Marlowe's review killed that argument: the outcomes are not the
        # same, because who has to act differs. Here the browser refused the
        # subscribe, so a reload can genuinely change the result and the user
        # is the one who can try. There, the account is in no conversation and
        # the user can do nothing at all. Collapsing the two is what made the
        # copy unactionable.
        "push_subscribe_failed", params, socket ->
          Logger.warning(
            "web push subscribe failed: " <>
              inspect(Map.take(params, ["name", "message"]), printable_limit: 500)
          )

          {:halt, assign(socket, :push_registration_failed, :subscribe_failed)}

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

  # Release what the ROSTER branch took out for the space it is about to stop
  # tracking. Without this the old space's topics stay registered for the life
  # of the LV.
  #
  # The registry semantics are unchanged and are still the reason this is
  # delicate: `Phoenix.PubSub.unsubscribe/2` is `Registry.unregister/2`, which
  # removes EVERY registration this pid holds for the topic, not the one this
  # branch added. Subscribing twice and unsubscribing once leaves zero
  # subscriptions, not one — which is exactly how the unread badge died in
  # `cb429830`.
  #
  # What changed (task 01a01a1b stage 2) is who is allowed to make that call.
  # `chat:space:<id>` is SHARED — roster, presence, the chat rail and the
  # tasks execution pane all want it on this one pid — so this function used
  # to guard its unsubscribe behind `unless prev in :shell_chat_space_ids`. That
  # asymmetry is now WRONG, not merely redundant: `PlatformWeb.SpaceTopics` is
  # the single writer and refcounts the holders, so a conditional release
  # would leave `:roster` recorded as a holder forever and pin the
  # subscription open with no surface able to drop it. The release below is
  # therefore unconditional; SpaceTopics decides whether it unsubscribes.
  #
  #   * `space_agents:<id>` USED TO BE roster-EXCLUSIVE, and that premise —
  #     not the bare call itself — was what made a direct
  #     `Phoenix.PubSub.unsubscribe/2` sound here. Task 01a0691d stage 3
  #     retires it: `MeetingLive` (member and guest mounts) and
  #     `ChatLive.MeetingHooks` (on join) now hold the same topic for the
  #     People tab's invite rows, and they mount inside THIS pid. The bare
  #     unsubscribe would have destroyed their registration along with the
  #     roster's, on a call still in progress, with the only symptom a People
  #     tab that quietly stopped updating.
  #
  #     So it goes through `SpaceTopics` on exactly the same argument as
  #     `chat:space:<id>`: two writers on one pid make a guard held by only
  #     one of them unsound rather than merely incomplete. The release is
  #     unconditional and `SpaceTopics` decides whether it unsubscribes.
  defp release_roster_subscriptions(socket) do
    case socket.assigns[:roster_space_id] do
      prev when is_binary(prev) ->
        socket
        |> SpaceTopics.release(prev, :roster)
        |> SpaceTopics.release_agents(prev, :roster)

      _ ->
        socket
    end
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
      visible_roster(
        socket.assigns[:roster_visibility] || :none,
        viewer_id(socket.assigns[:current_user_record])
      )

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
  # Task 01a011e6 stage 3 — CONFIDENTIALITY FENCE. Read before editing this
  # query, and NARROW ONLY: every clause below removes rows, and any change
  # that admits rows the current query rejects widens a metadata leak.
  #
  # `visible_roster/2` feeds two things: the Agents meter, and — via
  # `space_id` → `{:roster_resolved, sid}` → `SpaceTopics.hold/3` — the
  # per-space PubSub subscription this LiveView installs. So a space that
  # reaches this result set is a space this session receives broadcasts for.
  # It used to be fenced by `Tenancy.scope/3` alone, which (its own docs say)
  # "answers which ORGS only" and expects the caller to add which specific
  # rows. The caller never did, so any org-mate's session subscribed to the
  # org's most-recently-active agent-bearing space whether or not they were a
  # member of it. Nothing leaked into assigns or the render — every content
  # write in `ChatLive.MessagesHooks` is gated on `msg.space_id ==
  # active_space.id` — but the space's existence and activity timing did.
  #
  # Two clauses do the fencing now:
  #
  #   1. membership — an `exists/1` subquery requiring the viewer to hold a
  #      `participant_type: "user"` row on the space. This is deliberately the
  #      same shape as `Chat.list_viewer_presence_space_ids/1`, which this
  #      same LiveView already uses on the presence path. It is NOT the shape
  #      of `ChatLive.presence_subscribe_space_ids/2`, which intersects only
  #      for external users and passes every id through for internal staff.
  #
  #      Since task 01a01f4c this roster query is also WIDER-FENCED than the
  #      shell's own chat subscribe set, which is participation-only. The
  #      asymmetry is deliberate and the roster is an explicit NON-GOAL of that
  #      change: the roster exposes which agents exist where, and the subscribe
  #      set exposes nothing on its own. Do not unfence this to match it.
  #
  #   2. kind — `@private_roster_kinds` is excluded outright, on top of
  #      membership, so a DM can never enter the subscribe set even via a
  #      membership row. `"execution"` is deliberately NOT in that list: it is
  #      private, but clause (1) already reduces it to execution spaces the
  #      viewer participates in, and excluding it outright would empty the
  #      meter for the spaces agents actually work in.
  #
  # A third fence is accidental and MUST NOT be relaxed: `p.participant_type
  # == "agent"` means a space with only human participants contributes no
  # rows at all. That is the only reason human-to-human DMs were never
  # exposed by the pre-fix query, and it is reinforced by `Chat.create_space/1`
  # skipping the default agent for DMs. Making this query "more complete" by
  # relaxing it would widen the leak rather than close it.
  #
  # Narrowing is visible in the UI, which is why it carries a human gate: a
  # viewer who is a member of no agent-bearing space now gets an empty meter
  # and a nil `principal_name`, and `shell.html.heex:107` gates the Agents
  # button on that. Expected, not a regression.
  @private_roster_kinds ["dm"]

  # No viewer id (anonymous / non-user mount) means no membership rows can
  # match, so short-circuit rather than running a query that can only be
  # empty. Fails closed by construction.
  defp visible_roster(_visibility, viewer_id) when not is_binary(viewer_id),
    do: empty_roster()

  defp visible_roster(visibility, viewer_id) do
    rows =
      from(p in Chat.Participant,
        join: s in Platform.Chat.Space,
        as: :space,
        on: s.id == p.space_id,
        where: p.participant_type == "agent" and is_nil(s.archived_at),
        where: s.kind not in @private_roster_kinds,
        where:
          exists(
            from(vp in Chat.Participant,
              where:
                vp.space_id == parent_as(:space).id and
                  vp.participant_type == "user" and
                  vp.participant_id == ^viewer_id,
              select: 1
            )
          ),
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

  defp empty_roster do
    %{
      roster_items: [],
      composite: SpaceAgentPresence.composite([]),
      principal_name: nil,
      space_id: nil
    }
  end

  defp viewer_id(%{id: id}) when is_binary(id), do: id
  defp viewer_id(_), do: nil

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
  defp async_load_roster(lv_pid, visibility, viewer_id) do
    %{
      roster_items: items,
      composite: composite,
      principal_name: principal_name,
      space_id: sid
    } = visible_roster(visibility, viewer_id)

    # `:roster_resolved` still carries a single space id — it drives the
    # per-space `chat:space:<id>` subscription, which remains per-space. The
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
  # the oldest space's, and the online union comes from
  # `Presence.list_online_for_viewer/1`.
  #
  # This one Task resolves TWO different sets, and they must not be conflated:
  #
  #   * the shell's CHAT SUBSCRIBE SET is `Chat.list_member_space_ids/1`,
  #     participation-only and every kind (task 01a01f4c). It decides which
  #     `chat:space:<id>` topics this pid holds, so it decides whether the rail
  #     badge can move on a live post from `/tasks`. It exposes nothing on its
  #     own, which is why it carries no org fence.
  #   * the PRESENCE LIST is `Presence.list_online_for_viewer/1`, which
  #     re-derives its own org-fenced set from
  #     `Chat.list_viewer_presence_space_ids/1`. It carries other people's
  #     names, so it stays fenced. Do not "optimise" it to reuse the subscribe
  #     set resolved above.
  #
  # `list_member_space_ids/2` is guarded `when is_binary(user_id)` and has no
  # total clause, unlike `list_viewer_presence_space_ids/1`, so the nil
  # `user_record` is matched explicitly below rather than left to raise. Nil is
  # reachable: `ShellLive` runs first in every `on_mount` chain, ahead of
  # `LiveAuth`, so `assign_async/3` has already spawned this Task before any
  # auth redirect can halt the mount (see `router.ex`, which states
  # nil-tolerance as a property of this hook).
  #
  # The `{:ok, list}` / `{:error, reason}` tuple is stored AS the assign value
  # rather than being unwrapped here, because "nobody else is online" and "the
  # read failed" are different facts and the template has to be able to render
  # them differently. Unwrapping to `[]` on error is exactly the bug this task
  # exists to remove.
  defp async_load_presence(lv_pid, %{id: user_id} = user_record) when is_binary(user_id) do
    send(lv_pid, {:presence_spaces_resolved, Chat.list_member_space_ids(user_id)})

    {:ok, %{presence_list: ChatPresence.list_online_for_viewer(user_record)}}
  end

  defp async_load_presence(lv_pid, user_record) do
    send(lv_pid, {:presence_spaces_resolved, []})

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

      PlatformWeb.AdminOrgsLive ->
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

  # Unread count for the desktop icon-rail Inbox badge. Fail-open like
  # compute_tasks_count — a count error renders 0 (badge hidden) rather than
  # blocking the shell mount. Anonymous/non-user mounts (nil id) are 0 too.
  #
  # Task 01a00066 stage 4: this is the reachability-aware count, not the raw
  # one — a count never includes something the viewer has no way to act on.
  # BOTH the mount assign and the `:inbox_count_refresh` recompute go through
  # here, so the first paint and the live badge can never disagree about what
  # is being counted. Internal users are unaffected (identical to
  # `Inbox.unread_count/1`).
  defp compute_inbox_count(user_id) when is_binary(user_id) do
    Inbox.reachable_unread_count(user_id)
  rescue
    e ->
      require Logger
      Logger.warning("[ShellLive] inbox_count compute failed: #{inspect(e)}")
      0
  end

  defp compute_inbox_count(_), do: 0

  # Task 01a01b29 stage 1. Chat-unread total for the icon-rail Chat tile.
  # Same fail-open posture as `compute_inbox_count/1`: a count error renders 0
  # rather than failing a shell mount. Takes the loaded user struct because
  # that is what `Chat.total_unread_for_viewer/1` accepts; since task 01a01f4c
  # the count itself needs only the id.
  #
  # Cost, stated so a reviewer does not have to go find it:
  # `Chat.unread_counts_for_user/1` is one `Repo.all` plus one `count` per
  # participant row (N+1). Acceptable at the coalesced rate this is called at
  # (see `queue_chat_unread_refresh/1`); collapsing it into one grouped
  # aggregate is a real follow-up and belongs inside that function, never in a
  # fork of it.
  defp compute_chat_unread(%{id: user_id} = user) when is_binary(user_id) do
    Chat.total_unread_for_viewer(user)
  rescue
    e ->
      Logger.warning("[ShellLive] chat_unread compute failed: #{inspect(e)}")
      0
  end

  defp compute_chat_unread(_), do: 0

  # `/chat` and `/chat/:space_slug` (both live_sessions declare exactly these)
  # are the only routes that mount `ChatLive`, which is the only caller of
  # `MessagesHooks.enter_space/3` and `enter_space_anchored/4`, which are the
  # only writers of the read watermark on entry.
  defp chat_surface?("/chat"), do: true
  defp chat_surface?("/chat/" <> _), do: true
  defp chat_surface?(_), do: false

  # Coalesce a burst of chat events into ONE recompute on the next mailbox
  # turn, and never increment in memory.
  #
  # THE DEFERRAL IS THE POINT. Do not "simplify" this into an inline
  # recompute. ShellLive's hooks attach at `on_mount`, so they run BEFORE
  # `ChatLive`'s `MessagesHooks` on the same `{:new_message, _}`, and
  # `MessagesHooks` calls `Chat.mark_space_read/2` for a message in the active
  # space. An inline recompute would read the watermark from before that write
  # and over-report by one for the whole time the viewer sits on `/chat`.
  # Sending ourselves a message guarantees the recompute runs after
  # `MessagesHooks` has finished, by process semantics rather than by luck.
  #
  # Recomputing (rather than a running +1) is also what makes this idempotent
  # under double delivery, which is a live possibility in this process:
  # `ChatLive` subscribes to overlapping topics in the same pid.
  #
  # Connected-only, same posture as `push_app_badge/1`. The `:track_path`
  # `handle_params` hook also runs on the DISCONNECTED (static) render, which
  # executes in the HTTP request process rather than a LiveView process, so
  # `send(self(), ...)` there would post to a mailbox that never runs
  # `handle_info` and then dies. The connected mount that follows queues it
  # properly.
  @doc """
  Queue one recompute of the icon rail's Chat-unread badge on the next mailbox
  turn. Public because a sibling hook in the SAME LiveView process
  (`PlatformWeb.ChatLive`'s "Mark all as read") moves read cursors outside the
  `{:new_message, _}` path this module already listens to, and the badge has to
  follow that write without waiting for a navigation.

  A no-op on a disconnected socket and while a refresh is already queued, so
  callers may call it freely.
  """
  @spec queue_chat_unread_refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def queue_chat_unread_refresh(socket) do
    cond do
      not connected?(socket) -> socket
      socket.assigns[:chat_unread_refresh_queued] -> socket
      true -> queue_chat_unread_refresh!(socket)
    end
  end

  defp queue_chat_unread_refresh!(socket) do
    send(self(), :chat_unread_refresh)
    assign(socket, :chat_unread_refresh_queued, true)
  end

  # Task 01a00066 stage 3. One idempotent reconcile pass per mount. Same
  # rescue-and-log posture as compute_inbox_count/1: a reconcile failure must
  # never fail a mount — the badge simply renders the un-healed count.
  defp reconcile_inbox(user_id) when is_binary(user_id) do
    Inbox.reconcile_for_user(user_id)
    :ok
  rescue
    e ->
      require Logger
      Logger.warning("[ShellLive] inbox reconcile failed: #{inspect(e)}")
      :ok
  end

  defp reconcile_inbox(_), do: :ok

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
