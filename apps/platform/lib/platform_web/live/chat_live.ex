defmodule PlatformWeb.ChatLive do
  @moduledoc """
  LiveView for the Chat surface — with threads, reactions, pins, attachments,
  and collaborative live canvases.

  ## Layout

  Three-column layout when a thread is open:

      [Space sidebar | Message list | Thread panel]

  Thread panel collapses when closed. Pins panel slides in below the space
  header.

  ## Routes
    GET /chat             → :index — redirects to first space (or empty state)
    GET /chat/:space_slug → :show  — renders the selected space
  """

  use PlatformWeb, :live_view

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]
  import PlatformWeb.ChatLive.Partials
  import PlatformWeb.Components.ChatHelpers
  import PlatformWeb.Components.ChatMessage, only: [chat_message: 1, local_time: 1]
  import PlatformWeb.Components.ScopePill, only: [scope_pill: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.PubSub, as: ChatPubSub

  alias PlatformWeb.ChatLive.ActiveAgentHooks
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.ChatLive.MeetingHooks
  alias PlatformWeb.ChatLive.MentionsHooks
  alias PlatformWeb.ChatLive.MessagesHooks
  alias PlatformWeb.ChatLive.NewChannelComponent
  alias PlatformWeb.ChatLive.NewConversationComponent
  alias PlatformWeb.ChatLive.PinHooks
  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.SearchHooks
  alias PlatformWeb.ChatLive.SettingsComponent
  alias PlatformWeb.ChatLive.UploadHooks

  @quick_emojis ["👍", "❤️", "😂", "🎉"]
  @max_upload_entries 5
  @max_upload_size 15_000_000
  @impl true
  def mount(_params, session, socket) do
    do_mount(session, socket, embedded?: false)
  end

  @doc """
  Mount entrypoint used by `PlatformWeb.ChatLive.Embedded` to nest this
  surface inside a parent LiveView (e.g. the meeting chat pane, ADR
  0042 + stage 5 of task 019e2d1a).

  We can't expose `ChatLive` itself as a child LV: Phoenix forbids any
  module defining `handle_params/3` from being mounted as a child (raised
  in `Phoenix.LiveView.Static.disconnected_nested_render/6`), and the
  standalone surface needs `handle_params/3` so channel-to-channel
  navigation is a patch and not a full remount (preserves drafts,
  scroll position, presence).

  The embedded mount reads `chat_space_slug` + `current_user_id` from
  session (URL params don't flow to a `live_render`d child), seeds the
  active space inline, and sets `:embedded` so the template's `:if={!@embedded}`
  gates strip the sidebars / mobile pills / mobile browser / desktop
  chat header / modals / duplicate JS-hook anchors / meeting mini-bar
  off the rendered output. The embed does NOT attach MeetingHooks —
  the parent surface owns the LiveKit lifecycle and a duplicate attach
  would double-subscribe to room presence.
  """
  @spec embedded_mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def embedded_mount(_params, session, socket) do
    do_mount(session, socket, embedded?: true)
  end

  # Shared mount body for both the URL-routed surface (`ChatLive.mount/3`)
  # and the embedded surface (`ChatLive.embedded_mount/3` →
  # `ChatLive.Embedded`). The two paths differ in three places:
  #
  #   * sidebar / DM list queries are skipped when embedded (no sidebar
  #     to populate);
  #   * cross-space PubSub subscriptions are skipped when embedded (only
  #     one space matters);
  #   * MeetingHooks is NOT attached when embedded — replaced with safe
  #     defaults for the assigns the template references in the gates.
  #
  # Active-space resolution is split per-path:
  #
  #   * standalone surface defers to `handle_params/3` (called after
  #     mount on the URL-routed surface) to read `params["space_slug"]`
  #     and seed the active space + redirect on missing slug;
  #   * embedded surface seeds inline from `session["chat_space_slug"]`
  #     because URL params don't flow to nested LVs and `handle_params/3`
  #     is forbidden on child LVs anyway.
  defp do_mount(session, socket, opts) do
    embedded? = Keyword.fetch!(opts, :embedded?)
    user_id = session["current_user_id"] || Ecto.UUID.generate()
    # Only consulted on the embedded path; standalone uses handle_params.
    embedded_space_slug = if embedded?, do: session["chat_space_slug"]

    channels =
      if embedded?, do: [], else: Chat.list_spaces(kind: "channel")

    dm_conversations =
      if embedded? do
        []
      else
        conversations = if user_id, do: Chat.list_user_conversations(user_id), else: []
        Enum.filter(conversations, fn s -> s.kind in ["dm", "group"] end)
      end

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:user_id, user_id)
      |> assign(:embedded, embedded?)
      |> assign(:spaces, channels ++ dm_conversations)
      |> assign(:channels, channels)
      |> assign(:dm_conversations, dm_conversations)
      |> assign(:channel_sections, channel_sections(channels, dm_conversations))
      |> assign(:expanded_sections, MapSet.new())
      # Per-user sub-org section order (chat plan v2 Stage 3). Hydrated from
      # `users.preferences["chat_section_order"]` if set, otherwise defaults
      # to alphabetical. Embedded/anonymous sessions (no real user row) get
      # the default and stay there — `update_user_preference/3` no-ops on
      # an unknown user_id, so DnD writes are simply ignored.
      |> assign(:section_order, load_section_order(user_id))
      # Sub-org scope filter (chat plan v2 Stage 4). nil = no filter, all
      # sub-org sections render. An atom (one of @scope atoms) narrows the
      # rail to the matching sub-org section only. Toggled by clicking a
      # scope-pill via the `scope_filter` handler below.
      |> assign(:scope_filter, nil)
      |> assign(:active_space, nil)
      |> assign(:current_participant, nil)
      |> assign(:mobile_browser_open, false)
      |> assign(:show_new_channel_modal, false)
      |> assign(:show_new_conversation_modal, false)
      # Per-message actions sheet (3-dot menu): nil when closed, msg.id when open.
      # The matching message struct is lifted into :open_message_actions_msg so
      # the sheet template can gate items (e.g. "Edit message") on per-message
      # attributes like author and content_type without needing access to the
      # stream row at template time.
      |> assign(:open_message_actions_id, nil)
      |> assign(:open_message_actions_msg, nil)
      # Inline edit state (task 019e0f29 Stage 5). `editing_message_id` is
      # the id of the message whose bubble is currently swapped for the
      # editor; nil means no edit in progress. `pending_save_edit` carries
      # %{message_id, body} when the user has clicked Save on an edit
      # that shortens the original — the removal-warning modal is open and
      # waiting on their confirmation.
      |> assign(:editing_message_id, nil)
      |> assign(:pending_save_edit, nil)
      # Version history popover (task 019e0f29 Stage 6). nil when closed;
      # %{message_id, versions} when open. Filled by show_version_history.
      |> assign(:version_history, nil)
      |> assign(:show_settings, false)
      |> assign(:quick_emojis, @quick_emojis)
      |> assign(:push_permission, "unknown")
      |> assign(:unread_counts, if(user_id, do: Chat.unread_counts_for_user(user_id), else: %{}))
      |> assign(:lightbox_url, nil)
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: @max_upload_entries,
        max_file_size: @max_upload_size,
        progress: &handle_upload_progress/3
      )
      |> allow_upload(:thread_attachments,
        accept: :any,
        max_entries: @max_upload_entries,
        max_file_size: @max_upload_size,
        progress: &handle_upload_progress/3
      )

    all_spaces = channels ++ dm_conversations

    # Subscribe to chat pubsub for unread counts in background conversations
    # (active space subscription happens in handle_params).
    # Also subscribe to the global space-lifecycle topic so newly created
    # channels appear in the sidebar without requiring a refresh.
    # In embedded mode we skip both: the embed only renders ONE space and
    # has no sidebar to keep in sync, so the cross-space subscriptions
    # would just be noise.
    if connected?(socket) and not embedded? do
      Enum.each(all_spaces, &ChatPubSub.subscribe(&1.id))
      ChatPubSub.subscribe_spaces()
    end

    space_ids = Enum.map(all_spaces, & &1.id)

    socket =
      socket
      |> PresenceHooks.attach()
      |> MessagesHooks.attach()
      |> PinHooks.attach()
      |> SearchHooks.attach()
      |> MentionsHooks.attach()
      |> UploadHooks.attach()
      |> CanvasHooks.attach()
      |> ActiveAgentHooks.attach()

    # Meeting hooks own join/leave for the LiveKit room. When embedded
    # inside `MeetingLive`, the parent already owns the meeting lifecycle
    # — attaching here would double-subscribe to presence and break the
    # "Meet" button into a no-op (the parent meeting is already live).
    # We still seed safe defaults so the template's `:if={!@embedded}`
    # gates over the meeting-button affordances don't choke on missing
    # assigns when something else references them at render time.
    socket =
      if embedded? do
        socket
        |> assign(:in_meeting, false)
        |> assign(:meetings_enabled, false)
        |> assign(:mic_enabled, false)
        |> assign(:camera_enabled, false)
        |> assign(:screen_share_enabled, false)
        |> assign(:meeting_counts, %{})
      else
        MeetingHooks.attach(socket, space_ids)
      end

    # Embedded surfaces bootstrap the active space inline (URL params
    # don't flow to nested LVs, and `handle_params/3` is forbidden on
    # them anyway). The standalone surface defers to `handle_params/3`
    # below.
    socket =
      if embedded? and is_binary(embedded_space_slug) do
        bootstrap_embedded_space(socket, embedded_space_slug)
      else
        socket
      end

    {:ok, socket}
  end

  # Active-space bootstrap for the embedded surface. Mirrors the
  # success branch of `handle_params/3` minus three standalone-only
  # behaviors:
  #
  #   * does NOT call `bootstrap_space/1` (the friendly-slug auto-create
  #     path) — the embed must never mint channels from a meeting's
  #     binding;
  #   * does NOT `push_navigate(/chat)` when the slug points at nothing
  #     — the embed degrades to an empty stream rather than navigating
  #     the parent;
  #   * does NOT call `ensure_participant/2` — the meeting bar / livekit
  #     hook owns explicit join in MeetingLive, and a side-effecting
  #     embed mount would step on that contract. We do a read-only
  #     `find_user_participant/2` instead; the composer renders disabled
  #     when nil and lights up after the user joins through the bar.
  #
  # Standalone surface still uses `ensure_participant/2` via
  # `handle_params/3` because entering a channel via the URL is the
  # canonical implicit-join trigger.
  defp bootstrap_embedded_space(socket, slug_or_id) do
    space =
      Chat.get_space_by_slug(slug_or_id) ||
        (valid_uuid?(slug_or_id) && Chat.get_space(slug_or_id))

    case space do
      nil ->
        socket

      space ->
        if connected?(socket) do
          ChatPubSub.subscribe(space.id)
          Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space.id}")
        end

        participant = find_user_participant(space.id, socket.assigns.user_id)
        participants = Chat.list_participants(space.id)
        page_title = space_page_title(space, participants, socket.assigns.user_id)

        socket
        |> assign(:page_title, page_title)
        |> assign(:active_space, space)
        |> assign(:current_participant, participant)
        |> PresenceHooks.enter_space(space, participant, participants)
        |> MessagesHooks.enter_space(space, participant)
        |> SearchHooks.reset_for_space()
        |> MentionsHooks.reset_for_space()
        |> PinHooks.load_for_space(space.id)
        |> CanvasHooks.load_for_space(space.id)
        |> ActiveAgentHooks.resolve_for_space(space.id, participants)
        |> clear_unread(space.id)
    end
  end

  @impl true
  def handle_params(%{"space_slug" => slug_or_id}, _url, socket) do
    # Save the outgoing channel's draft AND cancel any staged uploads —
    # the upload slots are LV-process-scoped, not per-space, so without
    # an explicit cancel, a file staged in space A remains visible and
    # send-eligible in space B's composer (BACKLOG #10).
    socket =
      if prev = socket.assigns.active_space do
        ChatPubSub.unsubscribe(prev.id)
        Phoenix.PubSub.unsubscribe(Platform.PubSub, "active_agent:#{prev.id}")

        {main_cancelled, socket} = UploadHooks.cancel_all(socket, :attachments)
        {thread_cancelled, socket} = UploadHooks.cancel_all(socket, :thread_attachments)

        socket =
          socket
          |> PresenceHooks.leave_space(prev.id)
          |> MessagesHooks.save_draft(prev.id)

        flash_cancelled_uploads(socket, main_cancelled + thread_cancelled)
      else
        socket
      end

    # Try slug first, then ID fallback (for DM/group spaces without slugs)
    space =
      Chat.get_space_by_slug(slug_or_id) ||
        (valid_uuid?(slug_or_id) && Chat.get_space(slug_or_id)) ||
        bootstrap_space(slug_or_id)

    if is_nil(space) do
      {:noreply, push_navigate(socket, to: ~p"/chat")}
    else
      if connected?(socket) do
        # Mount's subscribe loop (see `mount/3`) already subscribed this LV
        # to every space in the user's channel + DM list — which includes
        # whichever one is about to become active. Phoenix.PubSub does NOT
        # dedupe subscriptions per pid: a second subscribe adds a second
        # registry entry and a single broadcast fires handle_info twice.
        # Unsubscribe first to guarantee a single active subscription here.
        ChatPubSub.unsubscribe(space.id)
        ChatPubSub.subscribe(space.id)
        Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space.id}")
      end

      participant = ensure_participant(space.id, socket.assigns.user_id)
      participants = Chat.list_participants(space.id)
      page_title = space_page_title(space, participants, socket.assigns.user_id)

      # Refresh sidebar lists
      channels = Chat.list_spaces(kind: "channel")
      user_convos = Chat.list_user_conversations(socket.assigns.user_id)
      dm_convos = Enum.filter(user_convos, fn s -> s.kind in ["dm", "group"] end)

      {:noreply,
       socket
       |> assign(:page_title, page_title)
       |> assign(:active_space, space)
       |> assign(:current_participant, participant)
       # Reconnect-aware meeting restore (task 019e4b3e stage 2): after a
       # transient LV socket drop, if the user still has an active live
       # participant row here, re-assign :in_meeting + re-push join-meeting
       # so the LiveKit session (kept alive in stage 1) is rejoined. No-op
       # on a fresh first mount — that still needs the explicit Join button.
       |> MeetingHooks.maybe_restore_on_reconnect(space)
       |> PresenceHooks.enter_space(space, participant, participants)
       |> MessagesHooks.enter_space(space, participant)
       |> SearchHooks.reset_for_space()
       |> MentionsHooks.reset_for_space()
       |> PinHooks.load_for_space(space.id)
       |> CanvasHooks.load_for_space(space.id)
       |> ActiveAgentHooks.resolve_for_space(space.id, participants)
       |> assign(:mobile_browser_open, false)
       |> assign(:channels, channels)
       |> assign(:dm_conversations, dm_convos)
       |> assign(:spaces, channels ++ dm_convos)
       |> assign(:channel_sections, channel_sections(channels, dm_convos))
       |> clear_unread(space.id)}
    end
  end

  def handle_params(_params, _url, socket) do
    case socket.assigns.channels do
      [first | _] ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{first.slug}")}

      [] ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_mobile_browser", _params, socket) do
    {:noreply, assign(socket, :mobile_browser_open, !socket.assigns.mobile_browser_open)}
  end

  def handle_event("close_mobile_browser", _params, socket) do
    {:noreply, assign(socket, :mobile_browser_open, false)}
  end

  # Sectioned-rail show-more toggle (chat plan v2 Stage 2). The rail caps each
  # section at 8 visible rows by default; the `+ N more` button toggles the
  # section key in/out of `@expanded_sections` (a MapSet of section keys).
  # Section keys are stable strings: "pinned", "dms", "Paragon", "Soylent",
  # "Fabrikam", "Wayne-Tech", "SXI".
  def handle_event("toggle_section", %{"section" => key}, socket)
      when is_binary(key) do
    expanded = socket.assigns.expanded_sections || MapSet.new()

    next =
      if MapSet.member?(expanded, key) do
        MapSet.delete(expanded, key)
      else
        MapSet.put(expanded, key)
      end

    {:noreply, assign(socket, :expanded_sections, next)}
  end

  # Scope filter (chat plan v2 Stage 4). Clicking a scope-pill in the
  # sectioned rail (or the chat-header pill) narrows the visible sub-org
  # sections to just that scope. Clicking the same scope again clears the
  # filter (toggle semantics). Payload `scope` is the atom name as a
  # string (e.g. "fabrikam", "wayne_tech"). Unknown values clear the filter.
  #
  # Future hook: Stack B (MT/RBAC) will replace the in-template filter
  # with a `?scope=` query-string patch so the filter state is shareable.
  # Until then we keep the state in-memory on the LV — no schema change
  # required, and the per-tab volatility matches the rest of the rail's
  # ephemeral UI state (e.g. `@expanded_sections`).
  def handle_event("scope_filter", %{"scope" => raw}, socket) when is_binary(raw) do
    incoming = parse_scope(raw)
    current = socket.assigns.scope_filter

    next =
      cond do
        is_nil(incoming) -> nil
        current == incoming -> nil
        true -> incoming
      end

    {:noreply, assign(socket, :scope_filter, next)}
  end

  # Sectioned-rail drag-reorder (chat plan v2 Stage 3). The JS hook
  # (`section_reorder.js`) emits `{from: <slug>, to: <slug>}` after a drop
  # onto another sub-org section. Reordering moves `from` into `to`'s slot
  # in the list — the displaced section and everything after it shift one
  # position toward `from`'s former slot (standard reorder semantics).
  #
  # Pinned + DMs are NOT reorderable — the JS hook drops their drag handle
  # and the server-side guard rejects payloads whose slugs aren't sub-orgs,
  # so this handler can assume both sides are valid bucket keys.
  #
  # Persistence: writes `users.preferences["chat_section_order"]` through
  # `Platform.Accounts.update_user_preference/3`. Embedded/anonymous
  # sessions silently fail-soft (`{:error, :not_found}`) since their
  # generated user_id doesn't match a real users row — the in-memory
  # reorder still flips so the rail feels responsive, but the next mount
  # falls back to alphabetical (Marlowe's call: don't pollute the schema
  # with throwaway anon prefs).
  def handle_event("section_reordered", %{"from" => from_slug, "to" => to_slug}, socket)
      when is_binary(from_slug) and is_binary(to_slug) do
    current_order = socket.assigns.section_order || sub_org_order()
    from_bucket = bucket_from_slug(from_slug)
    to_bucket = bucket_from_slug(to_slug)

    cond do
      is_nil(from_bucket) or is_nil(to_bucket) ->
        # Unknown slug (Pinned/DMs slugs aren't reorderable, and any other
        # bogus payload is a client/version mismatch). Ignore silently.
        {:noreply, socket}

      true ->
        new_order = compute_reorder(current_order, from_bucket, to_bucket)

        if new_order == current_order do
          {:noreply, socket}
        else
          # Best-effort persistence — anonymous sessions return :not_found
          # but the in-memory assign still flips so the UI doesn't snap back.
          _ =
            Platform.Accounts.update_user_preference(
              socket.assigns.user_id,
              :chat_section_order,
              new_order
            )

          {:noreply, assign(socket, :section_order, new_order)}
        end
    end
  end

  # Per-message actions sheet (3-dot menu on chat messages — task 019e0f29
  # Stage 3). Replaces the inert DaisyUI dropdown placeholder added in
  # Stage 2 with a real bottom sheet on mobile / centered card on desktop.
  def handle_event("open_message_actions", %{"id" => msg_id}, socket) do
    # Lift the message struct alongside the id so the sheet template can
    # gate items (e.g. "Edit message") on per-message attributes (author,
    # content_type) — see chat_live.html.heex around the Edit affordance.
    msg = Platform.Chat.get_message(msg_id)

    {:noreply,
     socket
     |> assign(:open_message_actions_id, msg_id)
     |> assign(:open_message_actions_msg, msg)}
  end

  def handle_event("close_message_actions", _params, socket) do
    {:noreply,
     socket
     |> assign(:open_message_actions_id, nil)
     |> assign(:open_message_actions_msg, nil)}
  end

  # ── Infinite scroll (task 019e18fc Stage 3) ────────────────────────────────
  #
  # Top sentinel fires `load_older_messages` when it scrolls into view AND
  # `:has_more_older` is true. Bottom sentinel fires `load_newer_messages`
  # when visible AND `:newest_evicted?` is true (the bounded-DOM tail was
  # pruned by a prior prepend; the user is scrolling back toward the live
  # tail and needs it re-hydrated). Both delegate the actual fetch +
  # stream mutation to `PlatformWeb.ChatLive.MessagesHooks` — see Stages
  # 1 and 2 for the helper implementations.
  #
  # Authorization: both handlers gate on a present `:active_space`. A
  # missing active_space means the user is on the no-space landing
  # state, in which case there's nothing to paginate.

  def handle_event("load_older_messages", _params, socket) do
    case socket.assigns[:active_space] do
      %{id: space_id} when is_binary(space_id) ->
        socket =
          socket
          |> assign(:loading_older, true)
          |> PlatformWeb.ChatLive.MessagesHooks.load_older_messages(space_id)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("load_newer_messages", _params, socket) do
    case socket.assigns[:active_space] do
      %{id: space_id} when is_binary(space_id) ->
        socket =
          socket
          |> assign(:loading_newer, true)
          |> PlatformWeb.ChatLive.MessagesHooks.load_newer_messages(space_id)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Version history popover (task 019e0f29 Stage 6, contract Section D.2)
  # Clicking the `(edited)` affix opens this; the popover lists prior
  # versions newest-first.

  def handle_event("show_version_history", %{"message-id" => message_id}, socket) do
    versions = Platform.Chat.MessageVersions.list_versions(message_id)

    {:noreply, assign(socket, :version_history, %{message_id: message_id, versions: versions})}
  end

  def handle_event("close_version_history", _params, socket) do
    {:noreply, assign(socket, :version_history, nil)}
  end

  # Click target on the "Correction to earlier message" header (Section D.4).
  # Pushes a custom event to the client so a small JS handler can scroll the
  # message stream to the target and apply a brief pulse animation.
  def handle_event("scroll_to_message", %{"id" => target_id}, socket) do
    {:noreply, push_event(socket, "chat:scroll-to-message", %{id: target_id})}
  end

  # ── Inline edit flow (task 019e0f29 Stage 5) ────────────────────────────
  # Stage 4 left a placeholder; Stage 5 wires the full editor.
  # `edit_message_clicked` opens the editor by setting editing_message_id;
  # the chat_message component swaps the bubble for chat_message_editor
  # when @editing_message_id matches the row's msg id. `cancel_edit`
  # closes the editor. `save_edit` is the form-submit handler — it
  # branches on the `removes_content` flag the JS hook set:
  #   - "true"  → stash the pending edit, surface the removal-warning
  #               modal (Section F.4 Policy 4 of the contract).
  #   - "false" → fire the edit immediately.
  # `confirm_save_edit` / `cancel_save_edit` handle the modal buttons.

  def handle_event("edit_message_clicked", params, socket) do
    msg_id = params["message-id"] || params["message_id"]

    with %Platform.Chat.Message{} = msg <-
           Platform.Repo.get(Platform.Chat.Message, msg_id),
         :ok <- authorize_edit(msg, socket.assigns.current_participant) do
      {:noreply,
       socket
       |> assign(:editing_message_id, msg_id)
       |> MessagesHooks.reinsert_stream_message(msg_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    msg_id = socket.assigns.editing_message_id

    socket =
      socket
      |> assign(:editing_message_id, nil)
      |> assign(:pending_save_edit, nil)

    case msg_id do
      nil -> {:noreply, socket}
      id -> {:noreply, MessagesHooks.reinsert_stream_message(socket, id)}
    end
  end

  def handle_event(
        "save_edit",
        %{"message_id" => message_id, "body" => body, "removes_content" => flag},
        socket
      ) do
    if flag == "true" do
      # Stash the pending edit and let the removal-warning modal open
      # via the @pending_save_edit assign. Keep the editor open in the
      # background so a Cancel on the modal keeps the user's draft.
      {:noreply, assign(socket, :pending_save_edit, %{message_id: message_id, body: body})}
    else
      apply_save_edit(socket, message_id, body)
    end
  end

  def handle_event("confirm_save_edit", _params, socket) do
    case socket.assigns.pending_save_edit do
      %{message_id: message_id, body: body} ->
        socket = assign(socket, :pending_save_edit, nil)
        apply_save_edit(socket, message_id, body)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_save_edit", _params, socket) do
    # Modal dismissed; keep the editor open with the user's draft so
    # they can revise.
    {:noreply, assign(socket, :pending_save_edit, nil)}
  end

  defp apply_save_edit(socket, message_id, body) do
    participant = socket.assigns.current_participant

    with %Platform.Chat.Message{} = msg <- Platform.Repo.get(Platform.Chat.Message, message_id),
         {:ok, original} <- {:ok, msg},
         :ok <- authorize_edit(msg, participant) do
      case Platform.Chat.Messages.Edit.apply_edit(msg, participant, body) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:editing_message_id, nil)
           |> MessagesHooks.stream_insert_message(updated)}

        {:error, :frozen, freezing_action} ->
          # Revert the bubble (we didn't optimistically swap content, but
          # the editor is open — close it and toast). Per Section F.4 of
          # the contract, name the freezing participant when known.
          {:noreply,
           socket
           |> assign(:editing_message_id, nil)
           |> MessagesHooks.stream_insert_message(original)
           |> put_flash(:error, frozen_toast_message(freezing_action))}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> assign(:editing_message_id, nil)
           |> MessagesHooks.stream_insert_message(original)
           |> put_flash(:error, "Could not save your edit. Try again.")}
      end
    else
      nil ->
        # Message disappeared between edit-open and save.
        {:noreply,
         socket
         |> assign(:editing_message_id, nil)
         |> put_flash(:error, "Message no longer exists.")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:editing_message_id, nil)
         |> put_flash(:error, "You can only edit your own messages.")}
    end
  end

  defp authorize_edit(_msg, nil), do: {:error, :forbidden}

  defp authorize_edit(%Platform.Chat.Message{participant_id: pid}, %{id: pid}), do: :ok

  defp authorize_edit(_msg, _participant), do: {:error, :forbidden}

  defp frozen_toast_message(freezing_action) do
    case freezing_action do
      %{participant_display_name: name} when is_binary(name) and name != "" ->
        "#{name} began work on this message while you were editing — your edit was not saved."

      _ ->
        "An agent began work on this message while you were editing — your edit was not saved."
    end
  end

  # Coordinator: Search event that also writes MessagesHooks state
  # (thread expansion, stream reinsert, highlight).
  def handle_event("search_open_result", %{"message-id" => message_id}, socket) do
    case Chat.get_message(message_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Search result not found.")}

      %{thread_id: thread_id} = message when is_binary(thread_id) ->
        parent_msg_id =
          Enum.find_value(socket.assigns.thread_previews, fn {pmid, %{thread_id: tid}} ->
            if tid == thread_id, do: pmid
          end)

        thread_msgs = MessagesHooks.load_thread_messages(message.space_id, thread_id)

        socket =
          if parent_msg_id do
            socket
            |> MessagesHooks.open_thread_context(parent_msg_id, thread_msgs)
            |> SearchHooks.set_highlights(parent_msg_id)
          else
            SearchHooks.set_highlights(socket, message.id)
          end

        {:noreply, socket}

      message ->
        {:noreply,
         socket
         |> MessagesHooks.reset_thread_panel()
         |> SearchHooks.set_highlights(message.id)}
    end
  end

  def handle_event("push_subscribed", %{"endpoint" => endpoint, "keys" => keys}, socket) do
    if participant = socket.assigns[:current_participant] do
      Platform.Push.subscribe(participant.id, %{
        endpoint: endpoint,
        keys: %{p256dh: keys["p256dh"], auth: keys["auth"]}
      })
    end

    {:noreply, assign(socket, :push_permission, "granted")}
  end

  def handle_event("push_permission_state", %{"state" => state}, socket) do
    {:noreply, assign(socket, :push_permission, state)}
  end

  def handle_event("push_unsupported", _params, socket) do
    {:noreply, assign(socket, :push_permission, "unsupported")}
  end

  def handle_event("enable_notifications", _params, socket) do
    {:noreply, push_event(socket, "request_push_permission", %{})}
  end

  # ── Upload staging dialog events ──────────────────────────────────────

  defp handle_upload_progress(_upload_name, _entry, socket) do
    {:noreply, socket}
  end

  # Cross-feature: upload_send creates a message + attachments. Delegates
  # post+stream writes to MessagesHooks, resets UploadHooks on success.
  def handle_event("upload_send", _params, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      caption = String.trim(socket.assigns.upload_caption || "")
      tagged = socket.assigns.upload_tagged_agents

      mentions =
        tagged
        |> MapSet.to_list()
        |> Enum.reject(fn slug -> String.contains?(caption, "@#{String.capitalize(slug)}") end)
        |> Enum.map(fn slug -> "@#{String.capitalize(slug)}" end)

      content =
        case {caption, mentions} do
          {"", []} -> ""
          {"", _} -> Enum.join(mentions, " ")
          {c, []} -> c
          {c, _} -> c <> " " <> Enum.join(mentions, " ")
        end

      attrs = %{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      }

      case MessagesHooks.post_message_with_upload(socket, :attachments, attrs) do
        {:ok, socket, msg, attachments} ->
          {:noreply,
           socket
           |> MessagesHooks.stream_insert_message(msg, attachments)
           |> UploadHooks.reset()}

        {:noop, _socket} ->
          {:noreply, put_flash(socket, :info, "No files selected")}

        {:error, socket, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # ── End upload staging dialog events ──────────────────────────────────

  def handle_event("toggle_watch", _params, socket) do
    space = socket.assigns.active_space
    new_watch = !space.watch_enabled

    case Chat.update_space(space, %{watch_enabled: new_watch}) do
      {:ok, updated_space} ->
        socket = assign(socket, :active_space, updated_space)

        socket =
          if new_watch do
            # Watch turned ON — if no active agent and there's a primary agent, activate it
            if is_nil(ActiveAgentStore.get_active(space.id)) &&
                 is_binary(space.primary_agent_id) do
              primary_participant =
                space.id
                |> Chat.list_participants(participant_type: "agent")
                |> Enum.find(fn p -> p.participant_id == space.primary_agent_id end)

              if primary_participant do
                ActiveAgentStore.set_active(space.id, primary_participant.id)
              end

              socket
            else
              socket
            end
          else
            # Watch turned OFF — clear active agent immediately
            ActiveAgentStore.clear_active(space.id)
            socket
          end

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update watch setting.")}
    end
  end

  # Coordinator: open a canvas and close the thread panel.
  def handle_event("canvas_open", %{"canvas-id" => canvas_id}, socket) do
    case CanvasHooks.find(socket, canvas_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Canvas not found.")}

      canvas ->
        {:noreply,
         socket
         |> CanvasHooks.set_active(canvas)
         |> MessagesHooks.reset_thread_panel()}
    end
  end

  # Coordinator: create a canvas message, stream-insert it, open it.
  def handle_event("canvas_create", %{"canvas" => canvas_params}, socket) do
    with space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      attrs = Map.take(canvas_params, ["title"])

      case Chat.create_canvas_with_message(space.id, participant.id, attrs) do
        {:ok, canvas, message} ->
          {:noreply,
           socket
           |> CanvasHooks.put(canvas)
           |> MessagesHooks.stream_insert_message(message)
           |> CanvasHooks.set_active(canvas)
           |> MessagesHooks.reset_thread_panel()
           |> CanvasHooks.show_panel()
           |> CanvasHooks.reset_new_form()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, CanvasHooks.changeset_error_summary(changeset))
           |> CanvasHooks.reset_new_form(canvas_params)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create canvas: #{inspect(reason)}")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Channel / Conversation creation events ─────────────────────────────────

  def handle_event("new_channel_open", _params, socket) do
    {:noreply, assign(socket, :show_new_channel_modal, true)}
  end

  def handle_event("new_conversation_open", _params, socket) do
    {:noreply, assign(socket, :show_new_conversation_modal, true)}
  end

  def handle_event("promote_to_channel", %{"name" => name}, socket) do
    space = socket.assigns.active_space

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.trim("-")

    case Chat.promote_to_channel(space, %{name: name, slug: slug}) do
      {:ok, updated} ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{updated.slug}")}

      {:error, :not_promotable} ->
        {:noreply,
         put_flash(socket, :error, "This conversation cannot be promoted to a channel.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not promote to channel.")}
    end
  end

  # ── Settings modal (see SettingsComponent) ────────────────────────────────

  def handle_event("settings_open", _params, socket) do
    {:noreply, assign(socket, :show_settings, true)}
  end

  @impl true
  def handle_info({:settings_closed}, socket) do
    {:noreply, assign(socket, :show_settings, false)}
  end

  def handle_info({:settings_navigate, path}, socket) do
    {:noreply,
     socket
     |> assign(:show_settings, false)
     |> push_navigate(to: path)}
  end

  def handle_info({:settings_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info({:new_channel_closed}, socket) do
    {:noreply, assign(socket, :show_new_channel_modal, false)}
  end

  def handle_info({:new_channel_navigate, path}, socket) do
    {:noreply,
     socket
     |> assign(:show_new_channel_modal, false)
     |> push_navigate(to: path)}
  end

  def handle_info({:new_channel_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info({:space_created, %{kind: "channel"} = space}, socket) do
    # Re-fetch sidebar lists so the new channel appears immediately for every
    # connected session, not just the creator. Subscribe to the new space's
    # topic for unread counts.
    ChatPubSub.subscribe(space.id)

    channels = Chat.list_spaces(kind: "channel")
    dm_conversations = socket.assigns.dm_conversations

    {:noreply,
     socket
     |> assign(:channels, channels)
     |> assign(:spaces, channels ++ dm_conversations)
     |> assign(:channel_sections, channel_sections(channels, dm_conversations))}
  end

  def handle_info({:space_created, _space}, socket), do: {:noreply, socket}

  def handle_info({:new_conversation_closed}, socket) do
    {:noreply, assign(socket, :show_new_conversation_modal, false)}
  end

  def handle_info({:new_conversation_navigate, path}, socket) do
    {:noreply,
     socket
     |> assign(:show_new_conversation_modal, false)
     |> push_navigate(to: path)}
  end

  def handle_info({:new_conversation_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Valid slug pattern: lowercase alphanumerics separated by hyphens (1–64 chars).
  # This intentionally excludes anything with underscores, uppercase, special chars,
  # or tool-artifact strings like "__from_file__" that should never create real spaces.
  @slug_pattern ~r/^[a-z0-9][a-z0-9\-]{0,62}[a-z0-9]$/

  defp bootstrap_space(slug) when is_binary(slug) do
    cond do
      # Never bootstrap for UUIDs — those are fetched directly
      valid_uuid?(slug) ->
        nil

      # Only bootstrap slugs that look like real channel slugs
      not String.match?(slug, @slug_pattern) ->
        nil

      true ->
        name =
          slug
          |> String.replace("-", " ")
          |> String.split()
          |> Enum.map(&String.capitalize/1)
          |> Enum.join(" ")

        case Chat.create_space(%{name: name, slug: slug, kind: "channel"}) do
          {:ok, space} -> space
          {:error, _} -> Chat.get_space_by_slug(slug)
        end
    end
  end

  defp bootstrap_space(_), do: nil

  defp valid_uuid?(string) when is_binary(string) do
    case Ecto.UUID.cast(string) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  defp space_page_title(%{kind: "channel", name: name}, _participants, _user_id) do
    "# #{name}"
  end

  defp space_page_title(space, participants, user_id) do
    Chat.display_name_for_space(space, participants, user_id)
  end

  defp space_header_name(%{kind: "channel", name: name}, _participants, _user_id), do: name

  defp space_header_name(space, participants, user_id) do
    Chat.display_name_for_space(space, participants, user_id)
  end

  defp sidebar_display_name(space, current_user_id) do
    participants = Chat.list_participants(space.id)
    Chat.display_name_for_space(space, participants, current_user_id)
  end

  defp clear_unread(socket, space_id) do
    update(socket, :unread_counts, &Map.delete(&1, space_id))
  end

  defp unread_label(count) when count >= 9, do: "9+"
  defp unread_label(count) when count > 0, do: Integer.to_string(count)
  defp unread_label(_), do: nil

  # ADR 0027: default_attention_mode/1 and default_attention_label/1 removed
  # (agent_attention field no longer exists on Space)

  # ADR 0038: participant rows represent current membership only — no
  # soft-delete to reconcile. If the user is in the space they get their
  # existing row; otherwise a fresh row is inserted.
  defp ensure_participant(space_id, user_id) do
    existing =
      space_id
      |> Chat.list_participants()
      |> Enum.find(fn p -> p.participant_id == user_id end)

    case existing do
      %Chat.Participant{} = p ->
        p

      nil ->
        display_name = name_for_user(user_id)

        case Chat.add_participant(space_id, %{
               participant_type: "user",
               participant_id: user_id,
               display_name: display_name,
               joined_at: DateTime.utc_now()
             }) do
          {:ok, p} -> p
          {:error, _} -> nil
        end
    end
  end

  # Read-only counterpart to `ensure_participant/2`. Used by the embedded
  # (live_render) mount path so that opening the meeting chat pane does
  # NOT step on the meeting bar's explicit-join contract. Returns the
  # existing user participant row when present, else `nil` — the embed
  # renders in read-only mode (composer disabled) until the user joins
  # the meeting through the bar.
  defp find_user_participant(space_id, user_id) do
    space_id
    |> Chat.list_participants()
    |> Enum.find(fn p ->
      p.participant_type == "user" and p.participant_id == user_id
    end)
  end

  defp name_for_user(user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "User"
    end
  end

  defp flash_cancelled_uploads(socket, 0), do: socket

  defp flash_cancelled_uploads(socket, count) do
    noun = if count == 1, do: "upload", else: "uploads"

    put_flash(
      socket,
      :info,
      "Canceled #{count} pending #{noun} from the previous space. Re-select the file(s) to send here."
    )
  end

  defp search_headline(message) do
    headline =
      cond do
        present?(message.search_headline) -> message.search_headline
        present?(message.content) -> message.content
        true -> "No searchable text"
      end

    headline
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("&lt;mark&gt;", "<mark>")
    |> String.replace("&lt;/mark&gt;", "</mark>")
    |> Phoenix.HTML.raw()
  end

  defp format_message_date(nil), do: ""

  defp format_message_date(%DateTime{} = dt) do
    today = Date.utc_today()
    msg_date = DateTime.to_date(dt)

    cond do
      msg_date == today -> "Today"
      msg_date == Date.add(today, -1) -> "Yesterday"
      true -> Calendar.strftime(dt, "%a, %b %-d")
    end
  end

  defp format_message_date(_), do: ""

  # Composer empty-state check for the send button's disabled attribute.
  # The form value can be nil (initial render), a binary, or a Phoenix.HTML.Form.normalize_value-shaped
  # value. Treat whitespace-only as empty so a stray space doesn't enable Send.
  defp composer_empty?(form) do
    case form && form[:text] do
      %{value: value} -> blank?(value)
      _ -> true
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  # ── Section grouping (chat plan v2 Stage 1) ─────────────────────────────
  #
  # `channel_sections/2` derives the sidebar's sectioned rail shape from the
  # already-loaded channel + DM lists. It is data-shape only; the template
  # in Stage 2 will consume `@channel_sections` to render Pinned / DMs /
  # sub-org section headers in a fixed order.
  #
  # Return shape:
  #
  #     %{
  #       pinned:   [Space.t()],          # empty until channel-level pinning ships
  #       dms:      [Space.t()],          # kind in ["dm", "group"]
  #       sub_orgs: %{
  #         "Paragon" => [Space.t()],
  #         "Soylent" => [Space.t()],
  #         "Fabrikam"     => [Space.t()],    # catch-all for anything not matching another bucket
  #         "Wayne-Tech" => [Space.t()],
  #         "SXI"      => [Space.t()]
  #       }
  #     }
  #
  # Classification precedence (highest wins):
  #
  #   1. Pinned non-DM channel → :pinned ONLY (NOT duplicated in its sub-org
  #      bucket). The chat-rail v2 spec says "Pinned + DMs locked at top, then
  #      sub-org sections" — we read "locked at top" as "shown above the
  #      sub-orgs," not "appears twice." If product later wants duplication,
  #      flip the `Enum.reject(channels, ...)` line below to keep the channel
  #      in both buckets.
  #   2. DM (`kind in ["dm", "group"]`) → :dms.
  #   3. Channel slug matches a sub-org → that bucket.
  #   4. Anything else → "Fabrikam" (today's default tenant).
  #
  # Sub-org bucket keys are stable string keys; the map preserves all 5 keys
  # even when buckets are empty so Stage 2's template can render section
  # headers without conditionals. Alphabetical render order is the template's
  # responsibility (iterate over `@sub_org_order` or `Map.keys/1 |> Enum.sort/1`).
  #
  # Post-MT/RBAC seam: the `channel_scope/1` helper today does a name-match
  # against the hardcoded sub-org slug list. After multi-tenant + RBAC ship,
  # swap its body for `Platform.Orgs.slug(channel.org_id)` and the rest of
  # this module keeps working unchanged.
  #
  # The `pinned_channel_ids` parameter is a hook for future channel-level
  # pinning (no schema today). Callers pass an empty MapSet; once the
  # `chat_pinned_channels` table or `metadata["pinned_by"]` convention lands,
  # the caller can compute a MapSet of pinned ids and pass it here.
  @sub_org_buckets ["Paragon", "Soylent", "Fabrikam", "Wayne-Tech", "SXI"]

  @doc """
  Group the user's channel + DM list into the sectioned-rail shape consumed
  by the chat sidebar (Stage 1 of chat plan v2).

  See module-level comment for the return shape, classification precedence,
  and the post-MT/RBAC migration seam (`channel_scope/1`).
  """
  @spec channel_sections([Platform.Chat.Space.t()], [Platform.Chat.Space.t()]) :: %{
          pinned: [Platform.Chat.Space.t()],
          dms: [Platform.Chat.Space.t()],
          sub_orgs: %{String.t() => [Platform.Chat.Space.t()]}
        }
  def channel_sections(channels, dm_conversations, pinned_channel_ids \\ MapSet.new())
      when is_list(channels) and is_list(dm_conversations) do
    {pinned, unpinned_channels} =
      Enum.split_with(channels, fn ch -> MapSet.member?(pinned_channel_ids, ch.id) end)

    empty_buckets = Map.new(@sub_org_buckets, fn slug -> {slug, []} end)

    sub_orgs =
      unpinned_channels
      |> Enum.reduce(empty_buckets, fn channel, acc ->
        bucket = channel_scope(channel)
        Map.update(acc, bucket, [channel], fn existing -> existing ++ [channel] end)
      end)

    %{
      pinned: pinned,
      dms: dm_conversations,
      sub_orgs: sub_orgs
    }
  end

  # Today: exact (case-insensitive) match on channel slug against the
  # hardcoded sub-org list, falling back to "Fabrikam" (the default tenant).
  #
  # Post-MT/RBAC: replace body with `Platform.Orgs.slug(channel.org_id)`
  # (or whatever the new lookup is called). Until then this is the single
  # point of change for sub-org assignment.
  @sub_org_slug_to_bucket %{
    "paragon" => "Paragon",
    "soylent" => "Soylent",
    "fabrikam" => "Fabrikam",
    "wayne-tech" => "Wayne-Tech",
    "sxi" => "SXI"
  }

  defp channel_scope(%{slug: slug}) when is_binary(slug) do
    Map.get(@sub_org_slug_to_bucket, String.downcase(slug), "Fabrikam")
  end

  defp channel_scope(_channel), do: "Fabrikam"

  # ── Sectioned-rail render helpers (chat plan v2 Stage 2) ───────────────
  #
  # The sub-org rail renders in fixed alphabetical order regardless of the
  # `channel_sections/3` return-map iteration order. Exposed as a public
  # helper so the template can iterate it without re-sorting on every render.
  @doc """
  The ordered list of sub-org bucket keys, alphabetical by display name.

  Used by the sectioned-rail template to render sub-org sections in a
  stable, predictable order. Note that `pinned` and `dms` are NOT sub-org
  buckets — they're rendered separately above the sub-orgs.
  """
  @spec sub_org_order() :: [String.t()]
  def sub_org_order, do: Enum.sort(@sub_org_buckets)

  # ── Per-user section order (chat plan v2 Stage 3) ──────────────────────
  #
  # `load_section_order/1` reads `users.preferences["chat_section_order"]`
  # and returns the saved order if valid (must be a permutation of the
  # full @sub_org_buckets set). Anything malformed — missing key, wrong
  # arity, unknown slugs, duplicates — falls back to alphabetical so a
  # poisoned preference can't break the rail.
  @doc """
  Hydrate the user's saved sub-org section order from preferences.

  Returns the saved list when it's a complete permutation of
  `sub_org_order/0`; falls back to alphabetical otherwise (including for
  anonymous user_ids that don't match a real users row).
  """
  @spec load_section_order(binary() | nil) :: [String.t()]
  def load_section_order(nil), do: sub_org_order()

  def load_section_order(user_id) when is_binary(user_id) do
    prefs = Platform.Accounts.get_user_preferences(user_id)
    saved = Map.get(prefs, "chat_section_order")

    if valid_section_order?(saved) do
      saved
    else
      sub_org_order()
    end
  end

  # Defensive validation — a saved order is only honored when it's an
  # exact-permutation match of the current sub_org bucket list. This means
  # adding a new bucket in the future invalidates everyone's saved order
  # (they fall back to alphabetical until they reorder again). Acceptable
  # cost vs. quietly hiding a new bucket from existing users.
  defp valid_section_order?(saved) when is_list(saved) do
    canonical = sub_org_order()

    length(saved) == length(canonical) and
      Enum.all?(saved, &is_binary/1) and
      Enum.sort(saved) == canonical
  end

  defp valid_section_order?(_), do: false

  @doc """
  Move `from` to `to`'s slot in `order`. The displaced item and everything
  between shifts one position toward `from`'s former slot — standard
  drag-reorder semantics.

  Returns the input list unchanged when:
    * `from == to` (drop on self)
    * either slug is absent from `order` (defensive — JS shouldn't emit
      this, but a stale render could)
  """
  @spec compute_reorder([String.t()], String.t(), String.t()) :: [String.t()]
  def compute_reorder(order, from, to)
      when is_list(order) and is_binary(from) and is_binary(to) do
    cond do
      from == to ->
        order

      from not in order or to not in order ->
        order

      true ->
        without_from = Enum.reject(order, &(&1 == from))
        target_idx = Enum.find_index(without_from, &(&1 == to))
        List.insert_at(without_from, target_idx, from)
    end
  end

  # Mapping from `channel_sections/3` string bucket keys to the atom values
  # the `scope_pill` component takes. Called from the colocated heex
  # template, hence defp + same-module visibility.
  defp sub_org_scope_atom("Paragon"), do: :paragon
  defp sub_org_scope_atom("Soylent"), do: :soylent
  defp sub_org_scope_atom("Fabrikam"), do: :fabrikam
  defp sub_org_scope_atom("Wayne-Tech"), do: :wayne_tech
  defp sub_org_scope_atom("SXI"), do: :sxi

  # Map a Space (or anything with a binary `:slug`) to its scope atom for
  # the `scope_pill` component. Channels with no recognized slug fall back
  # to `:fabrikam` (the default tenant — same precedence as `channel_scope/1`).
  # DMs/groups (`kind in ["dm", "group"]`) return `nil` so the chat-header
  # / active-row caller can suppress the pill on conversations that have
  # no org-scope to label.
  @doc false
  @spec space_scope_atom(map() | nil) :: atom() | nil
  def space_scope_atom(%{kind: kind}) when kind in ["dm", "group"], do: nil

  def space_scope_atom(%{slug: slug}) when is_binary(slug) do
    slug
    |> String.downcase()
    |> case do
      "paragon" -> :paragon
      "soylent" -> :soylent
      "fabrikam" -> :fabrikam
      "wayne-tech" -> :wayne_tech
      "sxi" -> :sxi
      _ -> :fabrikam
    end
  end

  def space_scope_atom(_), do: nil

  # Parse the inbound `scope_filter` payload's string scope name back into
  # an atom. Returns nil for any value not in the canonical 5-scope set so
  # a stale/malformed client payload silently clears the filter rather than
  # crashing the LV. Whitelist (no String.to_existing_atom) keeps the surface
  # impervious to atom-table flooding.
  @doc false
  @spec parse_scope(String.t()) :: atom() | nil
  def parse_scope("paragon"), do: :paragon
  def parse_scope("soylent"), do: :soylent
  def parse_scope("fabrikam"), do: :fabrikam
  def parse_scope("wayne_tech"), do: :wayne_tech
  def parse_scope("sxi"), do: :sxi
  def parse_scope(_), do: nil

  # Inverse of `sub_org_scope_atom/1` — bucket-display-name from scope
  # atom. Used by the template to gate sub-org section rendering when
  # `@scope_filter` is set (Stage 4).
  @doc false
  @spec bucket_for_scope(atom()) :: String.t() | nil
  def bucket_for_scope(:paragon), do: "Paragon"
  def bucket_for_scope(:soylent), do: "Soylent"
  def bucket_for_scope(:fabrikam), do: "Fabrikam"
  def bucket_for_scope(:wayne_tech), do: "Wayne-Tech"
  def bucket_for_scope(:sxi), do: "SXI"
  def bucket_for_scope(_), do: nil

  # Bucket display name → slug (lowercased; "Wayne-Tech" → "wayne-tech"). Used
  # by the template to set `data-section-slug` on sub-org sections; the
  # SectionReorder hook reads that attribute and sends slugs in its
  # `section_reordered` payload. Slugs are the stable wire-format because
  # they round-trip cleanly through HTML attributes and JSON keys.
  defp section_slug("Wayne-Tech"), do: "wayne-tech"
  defp section_slug(bucket) when is_binary(bucket), do: String.downcase(bucket)

  # Inverse of `section_slug/1`. Used at the `section_reordered` event
  # boundary to translate the JS hook's slug payload back to the bucket
  # display name used everywhere else in this module. Reuses the existing
  # `@sub_org_slug_to_bucket` mapping that was already needed by
  # `channel_scope/1` for the classification pass.
  @doc false
  @spec bucket_from_slug(String.t()) :: String.t() | nil
  def bucket_from_slug(slug) when is_binary(slug) do
    Map.get(@sub_org_slug_to_bucket, String.downcase(slug))
  end

  def bucket_from_slug(_), do: nil

  # Default visible row cap per section. Sections with more rows than this
  # cap render the surplus behind a `+ N more` toggle.
  @section_visible_cap 8

  @doc """
  Default visible-row cap per sectioned-rail section (8). Sections with more
  rows than the cap collapse the surplus behind a `+ N more` toggle whose
  state lives in `@expanded_sections`.
  """
  @spec section_visible_cap() :: pos_integer()
  def section_visible_cap, do: @section_visible_cap

  @doc """
  Split a section's spaces into the always-visible prefix and the hidden
  surplus, given the current `expanded_sections` MapSet and the section key.

  Returns `{visible, hidden}` where:
    * if the section is expanded (key in MapSet) → `{all, []}`
    * if the section has ≤ cap rows → `{all, []}`
    * otherwise → `{first 8, rest}`
  """
  @spec split_section([Platform.Chat.Space.t()], MapSet.t(String.t()), String.t()) ::
          {[Platform.Chat.Space.t()], [Platform.Chat.Space.t()]}
  def split_section(spaces, expanded_sections, key)
      when is_list(spaces) and is_binary(key) do
    cond do
      MapSet.member?(expanded_sections, key) -> {spaces, []}
      length(spaces) <= @section_visible_cap -> {spaces, []}
      true -> Enum.split(spaces, @section_visible_cap)
    end
  end

  @impl true
  def terminate(_reason, socket) do
    MeetingHooks.on_terminate(socket)
    :ok
  end
end
