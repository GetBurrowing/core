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

  require Logger

  import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]
  import PlatformWeb.ChatLive.Partials
  import PlatformWeb.Components.ChatHelpers
  import PlatformWeb.Components.ChatMessage, only: [chat_message: 1, local_time: 1]
  import PlatformWeb.Components.ScopePill, only: [scope_pill: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.HiddenChannels
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Sidebar

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
  alias PlatformWeb.LifecycleActions

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
  @doc """
  The PubSub subscribe set for presence/typing, scoped for external users
  (rbac-external-users M10).

  Internal users (and the anonymous/generated session id) are unrestricted —
  they subscribe to every space in `all_spaces`. External users are intersected
  against their `chat_participants` membership (`Chat.Presence.external_scope_space_ids/1`)
  so internal-only channel topics — which `Chat.list_spaces(kind: "channel")` returns
  workspace-wide with no membership filter — never reach their session.

  Public only so the subscribe-scope decision is unit-testable without a
  LiveView; not part of the ChatLive public API.
  """
  @spec presence_subscribe_space_ids([%{id: binary()}], binary()) :: [binary()]
  def presence_subscribe_space_ids(all_spaces, user_id) do
    ids = Enum.map(all_spaces, & &1.id)

    if Platform.Tenancy.external_user?(%{id: user_id}) do
      scope = Platform.Chat.Presence.external_scope_space_ids(user_id)
      Enum.filter(ids, &MapSet.member?(scope, &1))
    else
      ids
    end
  end

  defp do_mount(session, socket, opts) do
    embedded? = Keyword.fetch!(opts, :embedded?)
    user_id = session["current_user_id"] || Ecto.UUID.generate()
    # Only consulted on the embedded path; standalone uses handle_params.
    embedded_space_slug = if embedded?, do: session["chat_space_slug"]

    # rbac-external-users M5: the chrome-less external chat surface. M4's
    # `:external_chat` live_session (served on the `chat.` host) merges
    # `chat_mode => "external"` into the connect session; we read it here and,
    # when set, build M7's read-scope ONCE (`ExternalScope.for_user/1` — a
    # single `external?` EXISTS) and thread it into every rail read so the
    # external user's rail lists ONLY the spaces they are a `chat_participants`
    # member of. `@external?` defaults false on every internal / embedded /
    # app-host path, so the internal surface is byte-for-byte untouched.
    #
    # BOUNDARY: M5 owns the RENDER branch only. The scope threaded here filters
    # what the rail SHOWS; the guarantee that an external user cannot REACH an
    # off-limits space is M6's plug + M7's query filter, not this render. A nil
    # `external_scope` is pass-through everywhere (`ExternalScope.scope_spaces/2`),
    # so passing it on the internal path is a zero-behavior-change no-op.
    external? = session["chat_mode"] == "external"
    external_scope = if external?, do: Platform.Chat.ExternalScope.for_user(user_id)

    channels =
      if embedded?, do: [], else: Chat.list_spaces(kind: "channel", scope: external_scope)

    # Archived channels (task 019e95ea stage 2) feed ONLY the sidebar's
    # collapsed "Archived" group — they are deliberately kept out of
    # `channels` / `channel_sections/4` so no active bucket renders them.
    # External users get NONE: the archived group is an internal discovery
    # surface (design canvas §1 non-goals).
    archived_channels =
      if embedded? or external?,
        do: [],
        else: Chat.list_spaces(kind: "channel", archived: true)

    dm_conversations =
      if embedded? do
        []
      else
        conversations =
          if user_id, do: Chat.list_user_conversations(user_id, scope: external_scope), else: []

        Enum.filter(conversations, fn s -> s.kind in ["dm", "group"] end)
      end

    # Pin-to-Chat stage 4 (task 019f62a1): a dedicated "Pinned" rail section
    # for task execution spaces the current user has pinned. Loaded via
    # email (user pins are keyed by email — see `ChatPins.pin/3` and the
    # stage-3 mention-propagation pass in `Platform.Chat`) and kept fresh
    # by the `:task_pin_added` / `:task_pin_removed` handlers below. Empty
    # in embedded mode: the meeting-embed only paints ONE space and has
    # no sidebar to populate.
    # External users get no pinned task-exec section either (design canvas §1
    # non-goal — task execution spaces are an internal discovery surface), so
    # short-circuit the email lookup that feeds it to `nil` → `[]`.
    current_user_email =
      if embedded? or external?, do: nil, else: fetch_user_email_for_pins(user_id)

    pinned_task_spaces =
      case current_user_email do
        nil -> []
        email -> Platform.Tasks.ChatPins.list_pinned_task_spaces_for(%{kind: "user", id: email})
      end

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:user_id, user_id)
      # rbac-external-users M5: the render-branch flag + the read-scope it is
      # keyed on. `@external?` gates the discovery chrome off in the template
      # (sub-org headers, admin entry, new-channel, scope-pills, archived /
      # pinned-task sections) and `@external_scope` is re-threaded through the
      # rail reloads in `handle_params/3` + the channel-list broadcasts so a
      # later nav / space_created can never re-broaden the rail past the
      # allowlist. `@external_user` backs the top-bar identity chip (M4's
      # `:external` layout is chrome-less, so the branding / identity / logout
      # bar is rendered inside ChatLive here).
      |> assign(:external?, external?)
      |> assign(:external_scope, external_scope)
      |> assign(:external_user, if(external?, do: Accounts.get_user(user_id)))
      # Pin-to-Chat stage 4: stash the acting user's email so the pin
      # broadcast filter (`participant_id == current_user_email`) doesn't
      # need to re-hit `Accounts.get_user/1` on every arriving event.
      |> assign(:current_user_email, current_user_email)
      |> assign(:embedded, embedded?)
      |> assign(:spaces, channels ++ pinned_task_spaces ++ dm_conversations)
      |> assign(:channels, channels)
      |> assign(:pinned_task_spaces, pinned_task_spaces)
      |> assign(:archived_channels, archived_channels)
      # Collapse state for the sidebar's "Archived" group (task 019e95ea
      # stage 2) — collapsed by default, toggled by `toggle_archived_section`.
      |> assign(:archived_open, false)
      # Whether the CURRENT user may unarchive the active space (Fabrikam admin
      # or creator). UI affordance only — `Chat.unarchive_space/2` is the
      # gate. Recomputed wherever :active_space is (re)assigned.
      |> assign(:can_unarchive?, false)
      # Whether the CURRENT user may cancel a scheduled deletion on the
      # active space (task 019e95ea stage 4). Fabrikam admin ONLY — creators
      # don't qualify, mirroring `Chat.cancel_space_deletion/2`. Affordance
      # only; recomputed wherever :active_space is (re)assigned.
      |> assign(:can_cancel_deletion?, false)
      |> assign(:dm_conversations, dm_conversations)
      |> assign(:hidden_channel_ids, Accounts.get_hidden_channel_ids(user_id))
      |> assign(
        :channel_sections,
        channel_sections(
          channels,
          dm_conversations,
          MapSet.new(),
          Accounts.get_hidden_channel_ids(user_id)
        )
      )
      # Stage 3 v3 (chat sidebar Option B): the global "N hidden channels"
      # drawer at the sidebar bottom is collapsed by default. Toggled by
      # `toggle_hidden_drawer` handler. (Replaces the v2 per-section
      # `:hidden_visible_sections` MapSet — there's only one drawer now,
      # not one expand-state per sub-org bucket.)
      |> assign(:hidden_drawer_open, false)
      # Stage 3 (chat sidebar v3): ephemeral undo affordance shown for 4s
      # after a hide. `%{space_id: <uuid>, name: <channel name>}` while
      # active, `nil` otherwise. Cleared by `{:clear_undo_toast, space_id}`
      # handle_info scheduled via `Process.send_after/3` when the toast
      # is set. The space_id-match guard in the clear handler means a
      # second hide arriving inside the 4s window replaces the toast
      # cleanly — the older timer's clear becomes a no-op.
      |> assign(:undo_toast, nil)
      # Per-user sub-org section order (chat plan v2 Stage 3) is stored in
      # `users.preferences["chat_section_order"]` as a list of section IDS and
      # read fresh by `Sidebar.resolve_for_user/2` whenever the rail is
      # recomputed — there's no separate cached `@section_order` assign. The
      # reorder math derives its baseline from the rendered `@sidebar_sections`
      # ids, so a renamed/recolored section keeps its slot. Embedded/anonymous
      # sessions (no real user row) get the position-driven default and stay
      # there — `put_section_order/2` no-ops on an unknown user_id.
      #
      # Resolver-driven sub-org sections (chat sidebar v3 Stage 4). The rail
      # renders from this list of `%{section, channels}` entries — org-default
      # sections merged with the user's personal arrangement, channels placed
      # by `chat_spaces.org_id`. Recomputed in the same handlers that refresh
      # `@channel_sections` (channel switch, hide/unhide, space_created) plus
      # on a `:sidebar_changed` invalidation broadcast.
      |> assign(
        :sidebar_sections,
        resolve_sidebar_sections(
          user_id,
          channels,
          Accounts.get_hidden_channel_ids(user_id)
        )
      )
      # Sub-org scope filter (chat plan v2 Stage 4). nil = no filter, all
      # sub-org sections render. An atom (one of @scope atoms) narrows the
      # rail to the matching sub-org section only. Toggled by clicking a
      # scope-pill via the `scope_filter` handler below.
      |> assign(:scope_filter, nil)
      # Desktop "Edit layout" mode (chat sidebar Stage 5). When true the
      # sub-org rail shows per-channel grab handles, per-section Hide/Show
      # controls, and a "Reset to default layout" button; channel rows
      # become draggable (ChannelMembershipDrag hook) and gain keyboard
      # move-up/move-down controls. Default off — the rail navigates as
      # normal until the user opts into editing. Desktop only (the whole
      # rail is `hidden lg:flex`); mobile is out of scope for this stack.
      |> assign(:sidebar_edit, false)
      # Fabrikam-admin "Edit default" mode (chat sidebar Stage 6). A SEPARATE mode
      # from the personal "Edit layout" (@sidebar_edit): admin-edit routes the
      # same gestures to the GLOBAL org default (Sidebar Stage 2 API) instead
      # of the acting user's prefs, so a Fabrikam admin curates what every user
      # sees by default. Visible ONLY to Fabrikam admins (@fabrikam_admin? gate) and
      # mutually exclusive with @sidebar_edit — entering one exits the other.
      #
      # We compute @fabrikam_admin? here from the resolved user_id (rather than
      # relying solely on the LiveAuth `:default` on_mount that also assigns it
      # on the /chat route) so the assign is guaranteed present on BOTH mount
      # paths — the standalone surface AND the embedded child LV (which mounts
      # via `embedded_mount/3` and does not run the LiveAuth on_mount chain).
      # The actor we pass to every Sidebar.* admin write is `%{id: user_id}`,
      # the same shape fabrikam_admin?/1 authorizes, so the client-side toggle and
      # the server-side gate agree. Desktop only — the whole rail is
      # `hidden lg:flex`; the admin toggle lives inside that aside.
      |> assign(:fabrikam_admin?, Platform.Tenancy.fabrikam_admin?(%{id: user_id}))
      # Container-lifecycle affordances on the org section headers (task
      # 019f4eaa stage 6). `:tenant_org_ids` is the set of NON-root org ids —
      # the root (Fabrikam) section never gets archive controls (the lifecycle
      # refuses it). `:lifecycle_menu_key` is the single open kebab menu;
      # `:delete_modal` is `nil` or the `%{type:, id:, name:}` the confirm
      # dialog targets.
      |> assign(:tenant_org_ids, MapSet.new(Platform.Tenancy.list_tenants(), & &1.id))
      |> assign(:lifecycle_menu_key, nil)
      |> assign(:delete_modal, nil)
      # `:undo_archive` is nil (no toast) or the %{type:, id:, name:, hidden:}
      # the archive undo toast targets.
      |> assign(:undo_archive, nil)
      |> assign(:sidebar_admin_edit, false)
      # Sidebar layout overflow menu (chat sidebar header). The "CHANNELS"
      # header is a ~260px rail that can't fit two text toggles (personal
      # "Edit layout" + admin "Edit default"), so both entry points collapse
      # into ONE kebab/"More" button that opens this popover. `false` = closed.
      # Entering either edit mode (toggle_sidebar_edit / _admin_edit) closes it
      # so the header never shows both the menu and an active edit mode at once.
      |> assign(:sidebar_menu_open, false)
      |> assign(:active_space, nil)
      |> assign(:current_participant, nil)
      # M5b (task 019f6e2c) Stage 4 — junk-batch confirmation modal state.
      # Opened by `PlatformWeb.ChatLive.CanvasHooks` when a `junk_batch:*`
      # canvas action_row is clicked; carries the source canvas id + a
      # cheap preview of how many tasks would soft-delete. `nil` target +
      # `false` open flag are the resting values. See `confirm_junk_batch`
      # / `close_junk_batch_modal` below.
      |> assign(:show_junk_batch_modal, false)
      |> assign(:junk_batch_target, nil)
      |> assign(:mobile_browser_open, false)
      # Drawer search query (mobile channel search Stage 1). Filters the
      # drawer's rendered sections/DMs in-memory at RENDER time via the
      # drawer_filter_* helpers — the underlying assigns stay unfiltered
      # because the desktop rail renders from the same data and must never
      # be filtered by the mobile drawer's search.
      |> assign(:drawer_query, "")
      # Stage 2: whether the CURRENT drawer open was declared as a search
      # (magnifying-glass entry) — drives client-side focus via the
      # DrawerSearchFocus hook. Recomputed on every toggle.
      |> assign(:drawer_search_intent, false)
      # Channel-row reorder Stage 3 (a11y): text for the drawer's polite
      # aria-live region, set after every row move so screen-reader users
      # get confirmation the reorder happened. nil renders an empty region.
      |> assign(:drawer_reorder_announcement, nil)
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

    # Pin-to-Chat stage 4: pinned task-exec spaces ride the same PubSub
    # subscribe loop as channels + DMs so unread counts + `:new_message`
    # broadcasts stay live on the pinned rail rows. `ChatPubSub.subscribe/1`
    # is idempotent by topic so a pinned space that also happens to be an
    # active channel (unlikely — exec spaces have their own kind) is a
    # no-op double-subscribe.
    all_spaces = channels ++ pinned_task_spaces ++ dm_conversations

    # Subscribe to chat pubsub for unread counts in background conversations
    # (active space subscription happens in handle_params).
    # Also subscribe to the global space-lifecycle topic so newly created
    # channels appear in the sidebar without requiring a refresh.
    # In embedded mode we skip both: the embed only renders ONE space and
    # has no sidebar to keep in sync, so the cross-space subscriptions
    # would just be noise.
    if connected?(socket) and not embedded? do
      # M10 (presence/typing scope, rbac-external-users): external users must
      # receive presence + typing ONLY within spaces they are a chat_participant
      # of. We INTERSECT the subscribe set with their allowlisted scope
      # (`presence_subscribe_space_ids/2`) rather than swapping in the membership
      # list — an intersect can only ever REMOVE non-allowlisted topics, so it is
      # correct and order-independent regardless of whether M5/M7 have already
      # narrowed `channels` on the merge branch. Internal users are unrestricted.
      #
      # BOUNDARY: we scope ONLY the SUBSCRIBE set here. The rendered sidebar
      # assigns (`:channels` / `:spaces` / `channel_sections`) belong to M5 and
      # are deliberately left workspace-wide on this branch — the data FEED
      # (presence/typing) is already scoped even where the render is not, and the
      # two agree once M5's filtered render merges.
      all_spaces
      |> presence_subscribe_space_ids(user_id)
      |> Enum.each(&ChatPubSub.subscribe/1)

      ChatPubSub.subscribe_spaces()
      # Per-user sidebar-invalidation topic (Stage 4): a `:sidebar_changed`
      # broadcast (Stage 5 personal arrangement writes) triggers a resolver
      # recompute for this user's OTHER tabs.
      ChatPubSub.subscribe_sidebar(user_id)
      # Shared org-default topic (Stage 6): a `:sidebar_defaults_changed`
      # broadcast from a Fabrikam-admin curation write (rename / recolor / reorder
      # / reassign) triggers a resolver recompute in EVERY connected session,
      # so an admin's default change is visible to all users live.
      ChatPubSub.subscribe_sidebar_defaults()
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
      Chat.get_space_by_slug(slug_or_id, org_id: resolve_active_org_id(socket)) ||
        (valid_uuid?(slug_or_id) && Chat.get_space(slug_or_id)) ||
        system_prefix_fallback(slug_or_id)

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
        |> assign(:can_unarchive?, can_unarchive?(space, socket.assigns.user_id))
        |> assign(:can_cancel_deletion?, socket.assigns.fabrikam_admin?)
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

    # Try slug first, then ID fallback (for DM/group spaces without slugs).
    # The `:org_id` opt scopes ambiguous slugs (e.g. "general", which now
    # exists per-tenant after ADR 0042) to *this user's* org. When the user
    # has no resolvable org (anonymous / pre-membership), `resolve_active_org_id/1`
    # returns nil and the lookup falls back to its legacy oldest-row behavior.
    active_org_id = resolve_active_org_id(socket)

    space =
      Chat.get_space_by_slug(slug_or_id, org_id: active_org_id) ||
        (valid_uuid?(slug_or_id) && Chat.get_space(slug_or_id)) ||
        system_prefix_fallback(slug_or_id) ||
        bootstrap_space(slug_or_id, active_org_id)

    if is_nil(space) do
      # The URL saved by the RouteResume hook (`route_resume:chat` in
      # localStorage) points at a space this user can no longer resolve
      # (deleted, unauthorized). Signal the client to clear the entry so the
      # next Chat-tile click falls back to `/chat` rather than looping right
      # back into this dead resolve. See PlatformWeb.RouteResume.
      {:noreply,
       socket
       |> handle_route_stale("chat")
       |> push_navigate(to: ~p"/chat")}
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

      # Refresh sidebar lists. rbac-external-users M5: re-thread the same
      # `@external_scope` the mount used so a channel-to-channel nav re-derives
      # the SAME filtered rail rather than re-broadening it workspace-wide.
      # Internal / nil scope is pass-through, so the internal path is unchanged.
      scope = socket.assigns.external_scope
      channels = Chat.list_spaces(kind: "channel", scope: scope)

      archived_channels =
        if socket.assigns.external?,
          do: [],
          else: Chat.list_spaces(kind: "channel", archived: true)

      user_convos = Chat.list_user_conversations(socket.assigns.user_id, scope: scope)
      dm_convos = Enum.filter(user_convos, fn s -> s.kind in ["dm", "group"] end)

      {:noreply,
       socket
       |> assign(:page_title, page_title)
       |> assign(:active_space, space)
       |> assign(:can_unarchive?, can_unarchive?(space, socket.assigns.user_id))
       |> assign(:can_cancel_deletion?, socket.assigns.fabrikam_admin?)
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
       |> assign(:archived_channels, archived_channels)
       |> assign(:dm_conversations, dm_convos)
       |> assign(:spaces, channels ++ dm_convos)
       |> assign(
         :channel_sections,
         channel_sections(channels, dm_convos, MapSet.new(), socket.assigns.hidden_channel_ids)
       )
       |> assign(
         :sidebar_sections,
         resolve_sidebar_sections(
           socket.assigns.user_id,
           channels,
           socket.assigns.hidden_channel_ids
         )
       )
       |> clear_unread(space.id)}
    end
  end

  def handle_params(_params, _url, socket) do
    case socket.assigns.channels do
      [first | _] ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{space_nav_target(first)}")}

      [] ->
        {:noreply, socket}
    end
  end

  @impl true
  # Stage 2 (search-forward entry): the opener can declare a search intent
  # (phx-value-intent="search" on the pills-strip magnifying glass — whose
  # aria-label has always promised "Search channels and DMs"). The intent
  # rides to the drawer's input as a data attribute; the DrawerSearchFocus
  # hook focuses the field client-side on mount. Openers WITHOUT the intent
  # get a plain browse drawer — no focus, no keyboard.
  def handle_event("toggle_mobile_browser", params, socket) do
    opening = !socket.assigns.mobile_browser_open

    {:noreply,
     socket
     |> assign(:mobile_browser_open, opening)
     |> assign(:drawer_search_intent, opening and params["intent"] == "search")
     # Toggling closed discards the search, same as close_mobile_browser.
     |> then(&if(opening, do: &1, else: assign(&1, :drawer_query, "")))}
  end

  def handle_event("close_mobile_browser", _params, socket) do
    # Closing the drawer discards any in-progress search — reopening always
    # starts from the full browse list, never stale state.
    {:noreply,
     socket
     |> assign(:mobile_browser_open, false)
     |> assign(:drawer_query, "")}
  end

  # ── Junk-batch confirmation modal (M5b/019f6e2c stage 4) ────────────────
  #
  # `CanvasHooks` opens the modal by assigning `:show_junk_batch_modal`
  # + `:junk_batch_target` when a `junk_batch:*` action_row is clicked;
  # these two events tear it down and fire the destructive write.
  # Authorization already ran at the intercept (see
  # `authorize_junk_batch/2` in `CanvasHooks`) so the confirm handler
  # trusts that the socket reached this state legitimately. Defense-
  # in-depth: `Platform.Meetings.Triage.junk_batch/2` is idempotent —
  # a second confirm on an already-drained canvas returns `{:ok, 0}`
  # without a duplicate audit row or canvas note.
  def handle_event("close_junk_batch_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_junk_batch_modal, false)
     |> assign(:junk_batch_target, nil)}
  end

  def handle_event("confirm_junk_batch", _params, socket) do
    case socket.assigns[:junk_batch_target] do
      %{canvas_id: canvas_id} ->
        actor_id = confirm_junk_batch_actor_id(socket)

        socket =
          case Platform.Meetings.Triage.junk_batch(canvas_id, actor_id: actor_id) do
            {:ok, 0} ->
              # Defensive branch — the preview should have caught this
              # and hidden the confirm button. Reaching here means the
              # last surviving task was junked between preview + confirm.
              put_flash(socket, :info, "Nothing to roll back — batch already handled.")

            {:ok, n} ->
              put_flash(
                socket,
                :info,
                "Batch rolled back — #{n} #{if n == 1, do: "task", else: "tasks"} soft-deleted."
              )

            {:error, reason} ->
              Logger.warning(
                "confirm_junk_batch failed for canvas=#{canvas_id}: #{inspect(reason)}"
              )

              put_flash(socket, :error, "Could not junk this batch.")
          end

        {:noreply,
         socket
         |> assign(:show_junk_batch_modal, false)
         |> assign(:junk_batch_target, nil)}

      _ ->
        # Modal open flag flipped without a target — nothing to do.
        {:noreply,
         socket
         |> assign(:show_junk_batch_modal, false)
         |> assign(:junk_batch_target, nil)}
    end
  end

  defp confirm_junk_batch_actor_id(socket) do
    case socket.assigns do
      %{current_participant: %{user_id: id}} when is_binary(id) -> id
      %{current_user_record: %{id: id}} when is_binary(id) -> id
      %{current_user: %{id: id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  # ── Drawer search (mobile channel search Stage 1) ─────────────────────
  #
  # Filter-as-you-type over the drawer's already-loaded sections + DMs.
  # Pure assign write — the filtering itself happens at render via the
  # drawer_filter_* helpers, so there is no query cost and the desktop
  # rail (same underlying assigns) is untouched. The input is debounced
  # client-side (phx-debounce) and the value is length-capped here because
  # it is external input, even though it only ever feeds String.contains?.
  def handle_event("drawer_search", %{"value" => value}, socket) when is_binary(value) do
    {:noreply, assign(socket, :drawer_query, String.slice(value, 0, 100))}
  end

  def handle_event("drawer_search", _params, socket), do: {:noreply, socket}

  def handle_event("drawer_search_clear", _params, socket) do
    {:noreply, assign(socket, :drawer_query, "")}
  end

  # Per-channel hide affordance (chat sidebar v3 Stage 2). The sub-org
  # row's eye-slash button posts `hide_channel` with `phx-value-id`. We
  # persist the id into `users.preferences["hidden_channel_ids"]` via
  # `Accounts.hide_channel/2` (no-op for anonymous-session UUIDs that
  # don't match a real user row), then re-derive `@channel_sections`
  # with the updated hidden MapSet.
  #
  # Pinned and DM rows do NOT render the hide button (template-level
  # scope), so this handler is only reachable from sub-org rows. The
  # filter inside `channel_sections/4` still drops hidden ids from the
  # DMs bucket as a defense-in-depth, but the only path to add a DM id
  # to the hidden set today is direct DB manipulation.
  def handle_event("hide_channel", %{"id" => space_id}, socket) when is_binary(space_id) do
    user_id = socket.assigns.user_id

    # Capture the channel name from the current assigns BEFORE we re-derive
    # @channel_sections (which drops the hidden one from the visible map).
    # Stage 3 surfaces this in the undo-toast — "Hidden #foo — [Undo]".
    channel_name =
      case Enum.find(socket.assigns.channels, fn ch -> ch.id == space_id end) do
        %{name: name} -> name
        _ -> nil
      end

    _ = Accounts.hide_channel(user_id, space_id)
    hidden = Accounts.get_hidden_channel_ids(user_id)

    # Schedule auto-clear of the undo toast in 4s. The :clear_undo_toast
    # handler only nils the assign when the toast still points at THIS
    # space_id, so a second hide arriving inside the 4s window simply
    # replaces the toast and the earlier timer's fire becomes a no-op —
    # no need to track / cancel timer refs.
    if channel_name, do: Process.send_after(self(), {:clear_undo_toast, space_id}, 4_000)

    # Note: do NOT auto-collapse the hidden-channels drawer here. An earlier
    # iteration did, because the toast was absolute-positioned and could
    # overlap an expanded drawer panel. The toast is now in-flow above
    # "+ New channel" (Marlowe's 2026-05-29 review), so the toast and an
    # expanded drawer panel occupy different vertical bands and never
    # collide — collapsing the drawer here would just yank the user's
    # browsing context away for no UX win.
    {:noreply,
     socket
     |> assign(:hidden_channel_ids, hidden)
     |> assign(
       :channel_sections,
       channel_sections(
         socket.assigns.channels,
         socket.assigns.dm_conversations,
         MapSet.new(),
         hidden
       )
     )
     |> assign(
       :sidebar_sections,
       resolve_sidebar_sections(
         user_id,
         socket.assigns.channels,
         hidden
       )
     )
     |> assign(:undo_toast, channel_name && %{space_id: space_id, name: channel_name})}
  end

  # Stage 3 v3 (chat sidebar Option B). Toggle the single global
  # `Hidden channels` drawer at the bottom of the sidebar. There's only one
  # drawer state now (a boolean), not one expand-state per sub-org bucket
  # as in v2 — Marlowe's review removed the per-section chips in favour of a
  # single quieter affordance at the rail's foot.
  def handle_event("toggle_hidden_drawer", _params, socket) do
    {:noreply, assign(socket, :hidden_drawer_open, !socket.assigns.hidden_drawer_open)}
  end

  # Stage 3 (chat sidebar v3). Restore a hidden channel back into the
  # sidebar. Reached from two paths: the inline "Show" button under an
  # expanded Hidden (N) list (`unhide_channel`), and the undo toast's
  # Undo button (`undo_hide`) — both do the same work. We also clear
  # the undo toast when the channel being unhidden is the one currently
  # advertised in it, so the toast doesn't linger after the user has
  # explicitly reversed the action.
  def handle_event("unhide_channel", %{"id" => space_id}, socket) when is_binary(space_id) do
    {:noreply, do_unhide(socket, space_id)}
  end

  def handle_event("undo_hide", %{"id" => space_id}, socket) when is_binary(space_id) do
    {:noreply, do_unhide(socket, space_id)}
  end

  defp do_unhide(socket, space_id) do
    user_id = socket.assigns.user_id
    _ = Accounts.unhide_channel(user_id, space_id)
    hidden = Accounts.get_hidden_channel_ids(user_id)

    cleared_toast =
      case socket.assigns.undo_toast do
        %{space_id: ^space_id} -> nil
        other -> other
      end

    # Stage 3 v3: collapse the global Hidden drawer when the user has
    # just unhidden the last remaining channel — the drawer trigger goes
    # silent (template-level :if guard), so leaving `:hidden_drawer_open`
    # stuck at true would cause the panel to re-pop expanded the next
    # time the user hides something. Reset to closed instead.
    drawer_open =
      if MapSet.size(hidden) == 0, do: false, else: socket.assigns.hidden_drawer_open

    socket
    |> assign(:hidden_channel_ids, hidden)
    |> assign(
      :channel_sections,
      channel_sections(
        socket.assigns.channels,
        socket.assigns.dm_conversations,
        MapSet.new(),
        hidden
      )
    )
    |> assign(
      :sidebar_sections,
      resolve_sidebar_sections(
        user_id,
        socket.assigns.channels,
        hidden
      )
    )
    |> assign(:undo_toast, cleared_toast)
    |> assign(:hidden_drawer_open, drawer_open)
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
  # ephemeral UI state.
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

  # ── Edit-layout mode (chat sidebar Stage 5) ────────────────────────────
  #
  # Desktop per-user arrangement. All writes target the CURRENT user's prefs
  # only — the user id comes from the `@user_id` assign (seeded in mount from
  # the session), NEVER from the client payload, so a forged payload can't
  # rearrange another user's sidebar. Each write broadcasts `:sidebar_changed`
  # on the user's own topic (so other tabs of the same user converge) and
  # recomputes `@sidebar_sections` locally for an immediate optimistic update.

  # Flip the rail between normal (navigate) and personal-edit (rearrange) mode.
  # Entering personal-edit always exits admin-edit (Stage 6) — the two modes
  # are mutually exclusive so the admin can never have both sets of gestures
  # routing at once (personal → user prefs, admin → org default).
  def handle_event("toggle_sidebar_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:sidebar_edit, !socket.assigns.sidebar_edit)
     |> assign(:sidebar_admin_edit, false)
     # Entering (or leaving) personal-edit always closes the overflow menu —
     # the header shows the menu OR an active mode's "Done" control, never both.
     |> assign(:sidebar_menu_open, false)
     # Clear any active scope filter so editing always sees the full rail —
     # otherwise a filtered-out section is unreachable (and a recolor could
     # make the section being edited vanish from the filtered view).
     |> assign(:scope_filter, nil)
     # Same principle for the mobile drawer's search (Stage 1 guard rail):
     # edit mode and search are mutually exclusive — reordering a FILTERED
     # list would persist an order computed against a partial view.
     |> assign(:drawer_query, "")}
  end

  # Open/close the sidebar layout overflow menu (chat sidebar header). The
  # menu is the SINGLE entry point that fans out to personal-edit and (for
  # Fabrikam admins) admin-edit, so the ~260px rail header only ever hosts one
  # control. Closing on phx-click-away / Escape is handled in the template;
  # this handler is the explicit toggle on the "More" button itself.
  def handle_event("toggle_sidebar_menu", _params, socket) do
    {:noreply, assign(socket, :sidebar_menu_open, !socket.assigns.sidebar_menu_open)}
  end

  # Close the sidebar overflow menu without toggling a mode. Bound to the
  # menu container's phx-click-away and a phx-window-keydown Escape so a
  # click outside or the Escape key dismisses the popover.
  def handle_event("close_sidebar_menu", _params, socket) do
    {:noreply, assign(socket, :sidebar_menu_open, false)}
  end

  # ── Fabrikam-admin "Edit default" mode (chat sidebar Stage 6) ──────────────
  #
  # A SEPARATE mode from the personal "Edit layout" above. Visible ONLY to
  # Fabrikam admins and routes gestures to the GLOBAL org default (Sidebar Stage 2
  # API), not the acting user's prefs. Every write re-checks authorization
  # SERVER-SIDE by going through `Sidebar.*`, which gates on
  # `Tenancy.fabrikam_admin?/1` — the toggle + controls are an affordance, never
  # the gate. A forged event from a non-admin client returns
  # `{:error, :unauthorized}` and we no-op (with a flash). On success we
  # recompute the acting admin's own `@sidebar_sections` and broadcast
  # `:sidebar_defaults_changed` so every OTHER connected session refreshes.

  # Flip the rail between normal and admin-edit (curate org default) mode.
  # Entering admin-edit always exits personal-edit (mutual exclusivity). We
  # re-check `@fabrikam_admin?` here too so a forged toggle from a non-admin
  # client can't even open the mode (the per-gesture Sidebar gate is the real
  # backstop, but refusing to flip the assign keeps the UI honest).
  def handle_event("toggle_sidebar_admin_edit", _params, socket) do
    if socket.assigns.fabrikam_admin? do
      {:noreply,
       socket
       |> assign(:sidebar_admin_edit, !socket.assigns.sidebar_admin_edit)
       |> assign(:sidebar_edit, false)
       # Entering (or leaving) admin-edit always closes the overflow menu.
       |> assign(:sidebar_menu_open, false)
       # Clear any active scope filter so the admin always curates the full
       # rail — a recolor must never make the edited section drop out of view.
       |> assign(:scope_filter, nil)}
    else
      {:noreply, socket}
    end
  end

  # Rename an org-default section (admin-edit). Inline form per section header.
  def handle_event("rename_section_default", %{"section_id" => section_id} = params, socket)
      when is_binary(section_id) do
    name = String.trim(params["name"] || "")

    cond do
      name == "" ->
        {:noreply, socket}

      true ->
        case Sidebar.rename_section(%{id: socket.assigns.user_id}, section_id, name) do
          {:ok, _section} ->
            {:noreply, recompute_sidebar_after_admin_write(socket)}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

          {:error, _other} ->
            {:noreply, put_flash(socket, :error, "Could not rename the section.")}
        end
    end
  end

  # Recolor an org-default section (admin-edit). `color` is one of the 5 scope
  # tokens (fabrikam / soylent / wayne-tech / sxi / paragon) — the compact palette
  # in the section header.
  def handle_event(
        "recolor_section_default",
        %{"section_id" => section_id, "color" => color},
        socket
      )
      when is_binary(section_id) and is_binary(color) do
    if valid_scope_token?(color) do
      case Sidebar.recolor_section(%{id: socket.assigns.user_id}, section_id, color) do
        {:ok, _section} ->
          {:noreply, recompute_sidebar_after_admin_write(socket)}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

        {:error, _other} ->
          {:noreply, put_flash(socket, :error, "Could not recolor the section.")}
      end
    else
      {:noreply, socket}
    end
  end

  # Reassign a channel to another section GLOBALLY (admin-edit channel drag).
  # The ChannelMembershipDrag hook pushes this (instead of `channel_moved`)
  # when `data-admin-edit="true"`. We resolve the TARGET section's owning
  # `org_id` from `@sidebar_sections` (already loaded) and call
  # `Sidebar.reassign_channel/3`, which sets `chat_spaces.org_id` globally and
  # prunes per-user placement overrides so the admin move wins everywhere.
  def handle_event(
        "channel_reassigned",
        %{"channel_id" => channel_id, "target_section_id" => section_id},
        socket
      )
      when is_binary(channel_id) and is_binary(section_id) do
    case section_org_id(socket.assigns.sidebar_sections, section_id) do
      nil ->
        {:noreply, socket}

      org_id ->
        case Sidebar.reassign_channel(%{id: socket.assigns.user_id}, channel_id, org_id) do
          {:ok, _space} ->
            {:noreply, recompute_sidebar_after_admin_write(socket)}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

          {:error, _other} ->
            {:noreply, put_flash(socket, :error, "Could not move the channel.")}
        end
    end
  end

  # ── Container lifecycle (task 019f4eaa stage 6) ───────────────────────
  # Fabrikam-admin-only archive / schedule-deletion on the org section headers.
  # The controls only render behind `@fabrikam_admin?` and only for tenant orgs
  # (never the root), and every call re-authorizes underneath in
  # `Platform.Tenancy.Lifecycle`, so a forged event still gets refused.

  def handle_event("toggle_lifecycle_menu", %{"key" => key}, socket) do
    next = if socket.assigns.lifecycle_menu_key == key, do: nil, else: key
    {:noreply, assign(socket, :lifecycle_menu_key, next)}
  end

  def handle_event("archive_container", %{"type" => type, "id" => id} = params, socket) do
    case LifecycleActions.archive(%{id: socket.assigns.user_id}, type, id) do
      {:ok, resource} ->
        # Undo toast rather than a flash (Marlowe, 2026-07-16) — archive stays
        # instant + dialog-free, but says what it took. See
        # PlatformWeb.LifecycleControls.archive_undo_toast/1.
        {:noreply,
         socket
         |> assign(:lifecycle_menu_key, nil)
         |> refresh_chat_containers()
         |> assign(:undo_archive, %{
           type: type,
           id: id,
           name: params["name"] || Map.get(resource, :name, "it"),
           hidden: LifecycleActions.cascade_hidden_labels(type, id)
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:lifecycle_menu_key, nil)
         |> put_flash(:error, LifecycleActions.error_message(reason))}
    end
  end

  def handle_event("undo_archive", _params, socket) do
    case socket.assigns[:undo_archive] do
      nil ->
        {:noreply, socket}

      %{type: type, id: id} ->
        case LifecycleActions.unarchive(%{id: socket.assigns.user_id}, type, id) do
          {:ok, _resource} ->
            {:noreply,
             socket
             |> assign(:undo_archive, nil)
             |> refresh_chat_containers()
             |> put_flash(:info, "Restored.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:undo_archive, nil)
             |> put_flash(:error, LifecycleActions.error_message(reason))}
        end
    end
  end

  def handle_event("dismiss_undo_archive", _params, socket) do
    {:noreply, assign(socket, :undo_archive, nil)}
  end

  # Orgs open the "surface & choose" checklist (task 019f7600 stage 5): every
  # child — active, cascade-hidden, or hand-archived — is enumerated so the admin
  # can keep any of them from the org's purge.
  def handle_event(
        "open_delete_modal",
        %{"type" => "org" = type, "id" => id, "name" => name},
        socket
      ) do
    modal = build_org_delete_modal(id, name, PlatformWeb.LifecycleActions.purge_preview(type, id))

    {:noreply, socket |> assign(:lifecycle_menu_key, nil) |> assign(:delete_modal, modal)}
  end

  # Channels/projects have no children — the simple confirm (empty `preview`).
  def handle_event("open_delete_modal", %{"type" => type, "id" => id, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(:lifecycle_menu_key, nil)
     |> assign(:delete_modal, %{
       type: type,
       id: id,
       name: name,
       preview: PlatformWeb.LifecycleActions.cascade_preview(type, id)
     })}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply, assign(socket, :delete_modal, nil)}
  end

  def handle_event("delete_modal_change", params, socket) do
    {:noreply, update_delete_modal(socket, &delete_modal_apply_change(&1, params))}
  end

  def handle_event("delete_keep_all", _params, socket) do
    {:noreply, update_delete_modal(socket, &delete_modal_keep_all/1)}
  end

  def handle_event("delete_include_all", _params, socket) do
    {:noreply, update_delete_modal(socket, &delete_modal_include_all/1)}
  end

  def handle_event("confirm_schedule_deletion", _params, socket) do
    actor = %{id: socket.assigns.user_id}

    case socket.assigns.delete_modal do
      # Org: honor the include/keep choices, gated on the acknowledgement.
      %{type: "org", acknowledged: true, id: id, kept: kept} ->
        result = LifecycleActions.schedule_deletion(actor, "org", id, MapSet.to_list(kept))
        {:noreply, finish_schedule_deletion(socket, result)}

      # Gate not armed — ignore the submit, leave the modal open.
      %{type: "org"} ->
        {:noreply, socket}

      %{type: type, id: id} ->
        result = LifecycleActions.schedule_deletion(actor, type, id)
        {:noreply, finish_schedule_deletion(socket, result)}

      _ ->
        {:noreply, assign(socket, :delete_modal, nil)}
    end
  end

  # Only orgs carry the include/keep modal state; a channel modal is a no-op here.
  defp update_delete_modal(socket, fun) do
    case socket.assigns.delete_modal do
      %{type: "org"} = modal -> assign(socket, :delete_modal, fun.(modal))
      _ -> socket
    end
  end

  defp finish_schedule_deletion(socket, {:ok, _resource}) do
    socket
    |> assign(:delete_modal, nil)
    |> refresh_chat_containers()
    |> put_flash(:info, "Scheduled for deletion. You can still restore it before then.")
  end

  defp finish_schedule_deletion(socket, {:error, reason}) do
    socket
    |> assign(:delete_modal, nil)
    |> put_flash(:error, LifecycleActions.error_message(reason))
  end

  # Channel drag-drop OR keyboard move. The hook emits the TARGET section's
  # resulting channel-id order; `Sidebar.put_channel_order/3` records that
  # order for the section AND removes those channels from every other section
  # (single-placement invariant), which is exactly how a cross-section move
  # is persisted. We re-derive `@sidebar_sections` so the row appears under
  # its new section immediately.
  def handle_event(
        "channel_moved",
        %{"channel_id" => channel_id, "target_section_id" => section_id, "ordered_ids" => ids},
        socket
      )
      when is_binary(channel_id) and is_binary(section_id) and is_list(ids) do
    {:noreply,
     socket
     |> apply_channel_move(section_id, ids)
     |> announce_channel_move(channel_id, nil)}
  end

  # Keyboard alternative to the drag (WCAG 2.1.1 — no drag-only affordance).
  # Each channel row in edit mode renders focusable Up/Down buttons that
  # post `move_channel` with the channel id, its current section, and the
  # direction. We recompute the section's order from the live resolver,
  # swap the channel with its neighbour, and persist the new order via the
  # same `put_channel_order/3` path the drag uses.
  def handle_event(
        "move_channel",
        %{"channel_id" => channel_id, "section_id" => section_id, "direction" => direction},
        socket
      )
      when is_binary(channel_id) and is_binary(section_id) and direction in ["up", "down"] do
    current_ids = section_channel_ids(socket.assigns.sidebar_sections, section_id)
    new_ids = move_in_list(current_ids, channel_id, direction)

    if new_ids == current_ids do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> apply_channel_move(section_id, new_ids)
       |> announce_channel_move(channel_id, direction)}
    end
  end

  # Hide or show a whole section in the user's view. `hidden` arrives as the
  # DESIRED next state ("true"/"false" or a boolean) so the toggle is
  # idempotent regardless of client-side render races.
  def handle_event("toggle_section_hidden", %{"section_id" => section_id} = params, socket)
      when is_binary(section_id) do
    hidden? = truthy?(params["hidden"])
    _ = Sidebar.set_section_hidden(socket.assigns.user_id, section_id, hidden?)
    ChatPubSub.broadcast_sidebar_changed_from(socket.assigns.user_id, self())
    {:noreply, recompute_sidebar(socket)}
  end

  # Reset the user's entire personal arrangement (section order, channel
  # placement, hidden sections) back to the org default. Resetting clears the
  # explicit personal order, so the rail snaps back to the ADMIN DEFAULT order
  # (`Section.position`) in the same patch — we pass `{:default, ...}` so the
  # resolver's position ordering is honored rather than re-sorted. The next
  # personal drag re-derives its baseline order from the rendered
  # `@sidebar_sections` ids, so there's no cached order assign to reset.
  def handle_event("reset_sidebar", _params, socket) do
    _ = Sidebar.reset_to_default(socket.assigns.user_id)
    ChatPubSub.broadcast_sidebar_changed_from(socket.assigns.user_id, self())

    {:noreply,
     assign(
       socket,
       :sidebar_sections,
       resolve_sidebar_sections(
         socket.assigns.user_id,
         socket.assigns.channels,
         socket.assigns.hidden_channel_ids
       )
     )}
  end

  # Shared body for drag + keyboard channel moves: persist the target
  # section's order (best-effort — anonymous user ids fail-soft), broadcast
  # the invalidation, and recompute the rail locally.
  # Screen-reader confirmation for a row move (channel-row reorder
  # Stage 3). Both the ▲▼ buttons (direction known) and the touch drag
  # (position change only) funnel here; the drawer renders the text into a
  # polite aria-live region. Sighted users never see it (sr-only).
  defp announce_channel_move(socket, channel_id, direction) do
    name =
      case Enum.find(socket.assigns.channels, fn ch -> ch.id == channel_id end) do
        %{name: name} -> name
        _ -> nil
      end

    text =
      case {name, direction} do
        {nil, _} -> nil
        {name, "up"} -> "Moved ##{name} up"
        {name, "down"} -> "Moved ##{name} down"
        {name, nil} -> "Moved ##{name}"
      end

    assign(socket, :drawer_reorder_announcement, text)
  end

  defp apply_channel_move(socket, section_id, ids) do
    _ = Sidebar.put_channel_order(socket.assigns.user_id, section_id, ids)
    ChatPubSub.broadcast_sidebar_changed_from(socket.assigns.user_id, self())
    recompute_sidebar(socket)
  end

  # Recompute `@sidebar_sections` from the current channel list + saved
  # prefs (section order + channel placement + hidden sections all live in
  # `users.preferences`, read fresh by the resolver). The resolver owns the
  # render order — id-keyed personal order over `Section.position` default — so
  # an admin reorder stays visible to non-customized users.
  defp recompute_sidebar(socket) do
    assign(
      socket,
      :sidebar_sections,
      resolve_sidebar_sections(
        socket.assigns.user_id,
        socket.assigns.channels,
        socket.assigns.hidden_channel_ids
      )
    )
  end

  # Refresh after an org archive / schedule-deletion (task 019f4eaa stage 6):
  # the cascade hides that org's channels, so re-fetch the active channel
  # list before recomputing the sidebar or the just-hidden channels would
  # linger in the rail until the next navigation.
  defp refresh_chat_containers(socket) do
    socket
    |> assign(:channels, rail_channels(socket))
    |> recompute_sidebar()
  end

  # The rail's channel list, scoped to the acting user. rbac-external-users M5:
  # every reload of `:channels` after mount (nav, `:space_created` broadcast,
  # org-archive refresh, unarchive) must re-apply `@external_scope` or a
  # workspace-wide `list_spaces` would re-broaden an external user's rail past
  # their allowlist. For internal / anonymous sessions `@external_scope` is nil
  # and this is a pass-through — the internal rail is byte-for-byte unchanged.
  defp rail_channels(socket) do
    Chat.list_spaces(kind: "channel", scope: socket.assigns[:external_scope])
  end

  # Current ordered channel ids for a section, read from the already-resolved
  # `@sidebar_sections` (the live render state). Used by the keyboard move
  # handler to compute the new order without a DB round-trip.
  defp section_channel_ids(sidebar_sections, section_id) do
    case Enum.find(sidebar_sections, fn %{section: s} -> s.id == section_id end) do
      %{channels: channels} -> Enum.map(channels, & &1.id)
      _ -> []
    end
  end

  # Swap `id` one slot toward the head ("up") or tail ("down") of `ids`.
  # Returns the list unchanged when the move would fall off either end or
  # the id isn't present (defensive against a stale render).
  defp move_in_list(ids, id, direction) do
    case Enum.find_index(ids, &(&1 == id)) do
      nil ->
        ids

      idx ->
        target = if direction == "up", do: idx - 1, else: idx + 1

        if target < 0 or target >= length(ids) do
          ids
        else
          neighbour = Enum.at(ids, target)

          Enum.map(ids, fn
            ^id -> neighbour
            ^neighbour -> id
            other -> other
          end)
        end
    end
  end

  # Coerce a hide/show flag (boolean or "true"/"false" string from the
  # client) into a boolean. Anything other than a truthy marker is false.
  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # Sectioned-rail drag-reorder (chat plan v2 Stage 3 + Stage 6). The JS hook
  # (`section_reorder.js`) emits `{from: <section_id>, to: <section_id>}` after
  # a drop onto another sub-org section. Reordering moves `from` into `to`'s
  # slot in the list — the displaced section and everything after it shift one
  # position toward `from`'s former slot (standard reorder semantics).
  #
  # Identity is the section `id`, NOT its `color` token. Stage 6 made `color`
  # an admin-editable, non-unique cosmetic attribute (two sections can share a
  # color after a recolor), so keying drag identity off `color` would make a
  # drag onto a duplicate-color section ambiguous and resolve to the wrong (or
  # no) section. Section `id` is stable and unique, so both the admin and the
  # personal reorder paths resolve `from`/`to` by id against the currently
  # rendered `@sidebar_sections`.
  #
  # Pinned + DMs are NOT reorderable — the JS hook drops their drag handle and
  # the server-side guard rejects payloads whose ids aren't in the rendered
  # sub-org sections, so both branches no-op on a bogus/stale id.
  def handle_event("section_reordered", %{"from" => from_id, "to" => to_id}, socket)
      when is_binary(from_id) and is_binary(to_id) do
    # Stage 6: in admin-edit mode the same section-header drag persists to the
    # GLOBAL org default (channel_sections.position) via Sidebar.reorder_sections
    # instead of the per-user section_order. Branch here so the SectionReorder
    # hook stays mode-agnostic — the server decides which layer to write.
    if socket.assigns.sidebar_admin_edit do
      reorder_sections_default(socket, from_id, to_id)
    else
      reorder_sections_personal(socket, from_id, to_id)
    end
  end

  # Personal section-reorder (Stage 3). Persist the per-user `chat_section_order`
  # as a list of section IDS (not names). IDs are stable across admin
  # rename/recolor, so a personally-reordered user keeps their arrangement even
  # after an admin renames a section — the previous name-keyed store silently
  # dumped a renamed section to the rail's tail because the saved order still
  # held the OLD name (HIGH audit finding #3). The baseline order is derived
  # from the rendered `@sidebar_sections` (the same id-driven source the admin
  # reorder path uses), so there's no separate name-keyed `@section_order`
  # assign to keep in sync.
  defp reorder_sections_personal(socket, from_id, to_id) do
    current_ids = Enum.map(socket.assigns.sidebar_sections, fn %{section: s} -> s.id end)

    cond do
      from_id not in current_ids or to_id not in current_ids ->
        # Unknown id (Pinned/DMs aren't reorderable, and any other bogus
        # payload is a client/version mismatch). Ignore silently.
        {:noreply, socket}

      true ->
        new_ids = compute_reorder(current_ids, from_id, to_id)

        if new_ids == current_ids do
          {:noreply, socket}
        else
          # Best-effort persistence — anonymous / deleted user rows return
          # :not_found. We DON'T re-read prefs to render: a fail-soft write
          # would otherwise snap the rail back to position order. Instead we
          # apply `new_ids` to the already-resolved sections in-memory so the UI
          # reflects the drag immediately whether or not the write landed.
          _ = Sidebar.put_section_order(socket.assigns.user_id, new_ids)

          # Stage 5: invalidate the user's other connected tabs so a section
          # reorder converges everywhere, not just the tab that did the drag.
          ChatPubSub.broadcast_sidebar_changed_from(socket.assigns.user_id, self())

          reordered =
            order_resolved_by_ids(
              resolve_sidebar_sections(
                socket.assigns.user_id,
                socket.assigns.channels,
                socket.assigns.hidden_channel_ids
              ),
              new_ids
            )

          {:noreply, assign(socket, :sidebar_sections, reordered)}
        end
    end
  end

  # Admin section-reorder (Stage 6): persist the GLOBAL default order to
  # `channel_sections.position`. The SectionReorder hook's `from`/`to` are
  # section ids (data-section-id); we resolve them against the currently
  # rendered `@sidebar_sections` to confirm they're real, build the new
  # ordered id list, and write it via `Sidebar.reorder_sections/2` (which
  # gates on fabrikam_admin?). On success we broadcast `:sidebar_defaults_changed`
  # so all other sessions converge, then recompute this admin's view.
  defp reorder_sections_default(socket, from_id, to_id) do
    current_ids = Enum.map(socket.assigns.sidebar_sections, fn %{section: s} -> s.id end)

    cond do
      from_id not in current_ids or to_id not in current_ids ->
        {:noreply, socket}

      true ->
        new_ids = compute_reorder(current_ids, from_id, to_id)

        if new_ids == current_ids do
          {:noreply, socket}
        else
          case Sidebar.reorder_sections(%{id: socket.assigns.user_id}, new_ids) do
            {:ok, _count} ->
              {:noreply, recompute_sidebar_after_admin_write(socket)}

            {:error, :unauthorized} ->
              {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
          end
        end
    end
  end

  # Resolve a section's owning `org_id` from the rendered sections — used by
  # the admin channel-reassign handler to translate a TARGET section id into
  # the org_id `Sidebar.reassign_channel/3` writes onto the channel.
  defp section_org_id(sidebar_sections, section_id) do
    case Enum.find(sidebar_sections, fn %{section: s} -> s.id == section_id end) do
      %{section: %{org_id: org_id}} -> org_id
      _ -> nil
    end
  end

  # The 5 scope tokens are the recolor palette — whitelist-validate the
  # inbound color so a forged payload can't write an arbitrary string onto a
  # section's `color` (defense-in-depth on top of the admin gate).
  defp valid_scope_token?(color),
    do: color in ["paragon", "soylent", "fabrikam", "wayne-tech", "sxi"]

  # Shared tail for every successful admin-default write: broadcast the
  # shared-defaults invalidation to all OTHER sessions (so non-admin users and
  # the admin's other tabs converge live), then recompute the acting admin's
  # own `@sidebar_sections` from the now-updated default layer. Channels +
  # hidden ids + the admin's personal section_order are unchanged — only the
  # default sections moved — so we re-resolve with the same inputs.
  defp recompute_sidebar_after_admin_write(socket) do
    ChatPubSub.broadcast_sidebar_defaults_changed_from(self())
    recompute_sidebar(socket)
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

  # ── Archived-channel events (task 019e95ea stage 2) ────────────────────────

  def handle_event("toggle_archived_section", _params, socket) do
    {:noreply, assign(socket, :archived_open, !socket.assigns.archived_open)}
  end

  # Unarchive from the read-only banner. Authorization lives in
  # `Chat.unarchive_space/2` (Fabrikam admin or creator) — the banner button is
  # UI affordance only. On success we re-ensure the user's participant row
  # (implicit join is frozen on archived spaces, so `ensure_participant/2`
  # returned nil when the user entered the archived view) and refresh the
  # sidebar lists the space moves between.
  def handle_event("unarchive_space", _params, socket) do
    case socket.assigns.active_space do
      nil ->
        {:noreply, socket}

      space ->
        case Chat.unarchive_space(%{id: socket.assigns.user_id}, space) do
          {:ok, updated} ->
            participant =
              socket.assigns.current_participant ||
                ensure_participant(updated.id, socket.assigns.user_id)

            channels = rail_channels(socket)
            archived_channels = Chat.list_spaces(kind: "channel", archived: true)
            dm_convos = socket.assigns.dm_conversations

            {:noreply,
             socket
             |> assign(:active_space, updated)
             |> assign(:can_unarchive?, can_unarchive?(updated, socket.assigns.user_id))
             |> assign(:current_participant, participant)
             |> assign(:channels, channels)
             |> assign(:archived_channels, archived_channels)
             |> assign(:spaces, channels ++ dm_convos)
             |> assign(
               :channel_sections,
               channel_sections(
                 channels,
                 dm_convos,
                 MapSet.new(),
                 socket.assigns.hidden_channel_ids
               )
             )
             |> assign(
               :sidebar_sections,
               resolve_sidebar_sections(
                 socket.assigns.user_id,
                 channels,
                 socket.assigns.hidden_channel_ids
               )
             )
             |> put_flash(:info, "##{updated.name} was unarchived.")}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(socket, :error, "You don't have permission to unarchive this channel.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not unarchive this channel.")}
        end
    end
  end

  # Cancel a scheduled deletion from the read-only banner (task 019e95ea
  # stage 4). Fabrikam-admin only — `Chat.cancel_space_deletion/2` is the gate,
  # the banner button is UI affordance. The space stays archived (the banner
  # reverts to the archive copy with its Unarchive button) and reappears in
  # the sidebar's Archived section, which excludes deletion-flagged channels.
  def handle_event("cancel_space_deletion", _params, socket) do
    case socket.assigns.active_space do
      nil ->
        {:noreply, socket}

      space ->
        case Chat.cancel_space_deletion(%{id: socket.assigns.user_id}, space) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:active_space, updated)
             |> assign(:can_unarchive?, can_unarchive?(updated, socket.assigns.user_id))
             |> assign(:can_cancel_deletion?, socket.assigns.fabrikam_admin?)
             |> assign(:archived_channels, Chat.list_spaces(kind: "channel", archived: true))
             |> put_flash(:info, "Deletion cancelled — the channel remains archived.")}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(socket, :error, "You don't have permission to cancel this deletion.")}

          {:error, :not_scheduled} ->
            {:noreply, put_flash(socket, :error, "No deletion is scheduled for this channel.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not cancel the deletion.")}
        end
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
        {:noreply, push_navigate(socket, to: ~p"/chat/#{space_nav_target(updated)}")}

      {:error, :not_promotable} ->
        {:noreply,
         put_flash(socket, :error, "This conversation cannot be promoted to a channel.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not promote to channel.")}
    end
  end

  # ── Pin-to-Chat rail unpin (task 019f62a1 stage 4 fixup #2) ───────────────
  #
  # Rowan asked for a "small pin icon next to the task" so users can unpin
  # a task-exec space directly from the Pinned rail without navigating to
  # the task detail panel. This handler is PARTICIPANT-SCOPED — every
  # viewer that sees a rail row can unpin themselves regardless of whether
  # they're the sponsor (the rail surfaces rows for BOTH the sponsor's own
  # pin AND for participants pinned via sponsor @-mention in stage 3). A
  # sponsor unpin removes only her row; other participants keep seeing the
  # space until they unpin themselves or the task hits `done` (which
  # cascades via `ChatPins.unpin_all_for_task/1`).
  #
  # No sponsor gate here on purpose — that gate lives on the pin ADD path
  # in `TasksLive.handle_event("toggle_task_chat_pin", ...)` because the
  # add path is the earliest point that materialises a chat_spaces row.
  # Unpin cannot materialise anything, so a bypass has no side-effect
  # beyond removing a pin the caller already owns.
  def handle_event("unpin_task_from_chat", %{"task-id" => task_id}, socket)
      when is_binary(task_id) and task_id != "" do
    case socket.assigns[:current_user_email] do
      nil ->
        # Anonymous session or user record was deleted between mount and
        # click. Refuse silently — the pin row is keyed by email so we
        # can't even attribute a delete.
        {:noreply, put_flash(socket, :error, "You need to be signed in to unpin tasks.")}

      email ->
        participant = %{kind: "user", id: email}
        _ = Platform.Tasks.ChatPins.unpin(task_id, participant, email)
        {:noreply, put_flash(socket, :info, "Unpinned from Chat.")}
    end
  end

  def handle_event("unpin_task_from_chat", _params, socket), do: {:noreply, socket}

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

  # Flash + navigate MUST happen in one pipeline: a flash sent as its own
  # message renders (and is consumed) on the old view for a few ms before
  # the navigate remounts, so the user never sees it (task 019e95ea —
  # Marlowe's stage-4 review caught the missing delete confirmation toast).
  def handle_info({:settings_navigate, path, {kind, msg}}, socket) do
    {:noreply,
     socket
     |> assign(:show_settings, false)
     |> put_flash(kind, msg)
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

    # rbac-external-users M5: scope the reload so a channel created elsewhere in
    # the workspace never pops into an external user's rail (the external
    # session is subscribed to the space-lifecycle topic for its own allowlisted
    # channels). Pass-through for internal sessions.
    channels = rail_channels(socket)
    dm_conversations = socket.assigns.dm_conversations

    {:noreply,
     socket
     |> assign(:channels, channels)
     |> assign(:spaces, channels ++ dm_conversations)
     |> assign(
       :channel_sections,
       channel_sections(
         channels,
         dm_conversations,
         MapSet.new(),
         socket.assigns.hidden_channel_ids
       )
     )
     |> assign(
       :sidebar_sections,
       resolve_sidebar_sections(
         socket.assigns.user_id,
         channels,
         socket.assigns.hidden_channel_ids
       )
     )}
  end

  def handle_info({:space_created, _space}, socket), do: {:noreply, socket}

  # Pin-to-Chat stage 4 (task 019f62a1). Broadcasts arrive on the global
  # `chat:spaces` topic via `ChatPubSub.broadcast_space_event/1`. We match
  # only user-participant events aimed at THIS session's email; agent pins
  # and other users' pins ride the same topic but must never shift this
  # sidebar's rail. On a match, re-fetch the pinned-spaces list (cheap
  # single query) AND (for `:task_pin_added`) subscribe to the new space's
  # per-space topic so unread counts and `:new_message` broadcasts start
  # flowing without waiting for a fresh mount.
  def handle_info(
        {:task_pin_added,
         %{space_id: space_id, participant_kind: "user", participant_id: participant_id}},
        socket
      ) do
    if participant_id != nil and participant_id == socket.assigns[:current_user_email] do
      if connected?(socket), do: ChatPubSub.subscribe(space_id)
      {:noreply, refresh_pinned_task_spaces(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:task_pin_added, _payload}, socket), do: {:noreply, socket}

  def handle_info(
        {:task_pin_removed, %{participant_kind: "user", participant_id: participant_id}},
        socket
      ) do
    if participant_id != nil and participant_id == socket.assigns[:current_user_email] do
      {:noreply, refresh_pinned_task_spaces(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:task_pin_removed, _payload}, socket), do: {:noreply, socket}

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

  # Stage 3 (chat sidebar v3). Auto-clear the undo toast 4s after a hide.
  # Only clear when the toast still points at this space_id — a later hide
  # inside the 4s window replaces the toast, and the earlier timer firing
  # here would otherwise wipe the newer toast prematurely.
  def handle_info({:clear_undo_toast, space_id}, socket) do
    case socket.assigns.undo_toast do
      %{space_id: ^space_id} -> {:noreply, assign(socket, :undo_toast, nil)}
      _ -> {:noreply, socket}
    end
  end

  # Sidebar-shape invalidation (chat sidebar v3 Stage 4). Fired on the
  # per-user `chat:sidebar:<user_id>` topic when a personal arrangement change
  # (Stage 5) or an admin action in ANOTHER session — e.g. a Recovery-hub
  # channel restore (task 019f7600), which broadcasts via
  # `Lifecycle.restore_space_with_ancestors/2` → `broadcast_sidebar_changed/1`
  # — moves a channel between the active and archived buckets.
  #
  # Re-read BOTH channel lists from the DB, then recompute `@sidebar_sections`
  # off the FRESH `@channels`. Recomputing off the stale `socket.assigns.channels`
  # alone (the pre-019f7600 behavior) refreshed the active sub-org sections but
  # left the collapsed "Archived" group — which renders straight off
  # `@archived_channels` — still showing a channel that is no longer archived,
  # until a manual reload. This mirrors the own-session unarchive/navigation
  # refresh so a cross-session restore drops the archived row live. Embedded
  # surfaces have no sidebar and never subscribe (see `do_mount/3`), so they
  # keep their empty lists.
  def handle_info(:sidebar_changed, socket) do
    if socket.assigns.embedded do
      {:noreply, socket}
    else
      channels = Chat.list_spaces(kind: "channel")
      archived_channels = Chat.list_spaces(kind: "channel", archived: true)

      {:noreply,
       socket
       |> assign(:channels, channels)
       |> assign(:archived_channels, archived_channels)
       |> assign(
         :sidebar_sections,
         resolve_sidebar_sections(
           socket.assigns.user_id,
           channels,
           socket.assigns.hidden_channel_ids
         )
       )}
    end
  end

  # Shared org-DEFAULT invalidation (chat sidebar Stage 6). Fired on the
  # `chat:sidebar:defaults` topic when a Fabrikam admin curates the default layer
  # (rename / recolor / reorder / reassign). EVERY connected session receives
  # this (except the acting admin's own tab, which recomputed synchronously)
  # and re-resolves its `@sidebar_sections` so the admin's default change is
  # visible to all users without a refresh. Same recompute as `:sidebar_changed`
  # — the resolver reads the now-updated default sections from the DB.
  def handle_info(:sidebar_defaults_changed, socket) do
    {:noreply,
     assign(
       socket,
       :sidebar_sections,
       resolve_sidebar_sections(
         socket.assigns.user_id,
         socket.assigns.channels,
         socket.assigns.hidden_channel_ids
       )
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Valid slug pattern: lowercase alphanumerics separated by hyphens (1–64 chars).
  # This intentionally excludes anything with underscores, uppercase, special chars,
  # or tool-artifact strings like "__from_file__" that should never create real spaces.
  @slug_pattern ~r/^[a-z0-9][a-z0-9\-]{0,62}[a-z0-9]$/

  # Slug prefixes that belong to system-managed chat_spaces (meetings, task
  # execution rooms, DMs, group spaces). bootstrap_space/2 MUST refuse to mint
  # a `kind="channel"` row for any of these — they're owned by their respective
  # creation paths (`Meetings.create_meeting/2`, `Orchestration.ExecutionSpace`,
  # the DM/group flows). Visiting `/chat/meeting-<uuid>` for a meeting space the
  # caller doesn't have org-scoped access to should fall through to the
  # `/chat` redirect, NOT create a parallel duplicate channel with the same slug.
  # Each duplicate would have been silently allowed by the pre-existing
  # partial unique indexes (`chat_spaces_unique_org_slug WHERE org_id IS NOT NULL`
  # and `chat_spaces_unique_slug ON (workspace_id, slug)`) because both
  # workspace_id and org_id are NULL on bootstrap inserts.
  @reserved_slug_prefixes ~w(meeting- task-exec- dm- group-)

  defp bootstrap_space(slug, org_id) when is_binary(slug) do
    cond do
      # Never bootstrap for UUIDs — those are fetched directly
      valid_uuid?(slug) ->
        nil

      # Refuse system-managed slug prefixes regardless of pattern match
      Enum.any?(@reserved_slug_prefixes, &String.starts_with?(slug, &1)) ->
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

        attrs =
          %{name: name, slug: slug, kind: "channel"}
          |> maybe_put_org_id(org_id)

        case Chat.create_space(attrs) do
          {:ok, space} -> space
          {:error, _} -> Chat.get_space_by_slug(slug, org_id: org_id)
        end
    end
  end

  defp bootstrap_space(_, _), do: nil

  # Safety-net lookup for system-managed slug prefixes (exec, meeting, dm,
  # group). These spaces are minted by orchestration code paths and MAY
  # have `org_id = NULL` (exec spaces created before the org_id backfill
  # migration; meeting/dm/group spaces intentionally cross-org). The
  # org-scoped `get_space_by_slug/2` filters them out; fall back to an
  # unscoped lookup, guarded by the reserved-prefix list so the ADR-0042
  # per-org channel-slug scoping ("#general" in Fabrikam vs "#general" in SXI)
  # is NEVER weakened for user-created channel slugs.
  defp system_prefix_fallback(slug) when is_binary(slug) do
    if Enum.any?(@reserved_slug_prefixes, &String.starts_with?(slug, &1)) do
      Chat.get_space_by_slug(slug, [])
    end
  end

  defp system_prefix_fallback(_), do: nil

  defp maybe_put_org_id(attrs, nil), do: attrs
  defp maybe_put_org_id(attrs, org_id), do: Map.put(attrs, :org_id, org_id)

  defp valid_uuid?(string) when is_binary(string) do
    case Ecto.UUID.cast(string) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  # Pick the org_id we should scope ambiguous slug lookups to (e.g. "general").
  # Reads from the LiveAuth-installed `:current_user_org_membership` assign
  # (populated by `PlatformWeb.LiveAuth.on_mount(:default)` via
  # `Tenancy.load_membership/1`), so no DB call on the hot mount path.
  #
  # Returns `nil` for anonymous mounts, multi-org users whose preloaded
  # membership list was empty, or any non-LiveAuth surface — in which case
  # `Chat.get_space_by_slug/2` falls through to its back-compat oldest-row
  # behavior (the pre-fix shape).
  defp resolve_active_org_id(socket) do
    case socket.assigns[:current_user_org_membership] do
      %{org: %Platform.Tenancy.Org{id: org_id}} -> org_id
      _ -> nil
    end
  end

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

  # ── Drawer search filters (mobile channel search Stage 1) ─────────────
  #
  # Render-time, in-memory filters over the drawer's already-computed
  # assigns. An empty query passes everything through unchanged, so the
  # non-searching drawer renders exactly what it did before this stage.
  # Case-insensitive substring — no fuzzy matching at this scale
  # (~5 sections / <30 channels), where "just filtering" is enough.

  defp drawer_match?(nil, _query), do: false

  defp drawer_match?(name, query) when is_binary(name) do
    String.contains?(String.downcase(name), String.downcase(query))
  end

  # Plain space lists (Pinned) — filter on the space name.
  defp drawer_filter_spaces(spaces, ""), do: spaces

  defp drawer_filter_spaces(spaces, query),
    do: Enum.filter(spaces, &drawer_match?(&1.name, query))

  # DM rows are labeled by their computed display name (the other
  # participant / group title), so that is what the filter must match —
  # a DM's underlying space.name is not what the user sees.
  defp drawer_filter_dms(dms, "", _user_id), do: dms

  defp drawer_filter_dms(dms, query, user_id) do
    Enum.filter(dms, &drawer_match?(sidebar_display_name(&1, user_id), query))
  end

  # Sub-org sections: filter each section's channels; drop sections with no
  # matches entirely (their headers would be noise), but keep headers on
  # sections that DO match — two orgs can hold same-named channels and the
  # section label is the only disambiguator.
  defp drawer_filter_sections(sections, ""), do: sections

  defp drawer_filter_sections(sections, query) do
    sections
    |> Enum.map(fn %{channels: channels} = entry ->
      %{entry | channels: Enum.filter(channels, &drawer_match?(&1.name, query))}
    end)
    |> Enum.filter(fn %{channels: channels} -> channels != [] end)
  end

  # True when an active search matched nothing anywhere — drives the
  # dedicated "No matches" state (NOT the genuinely-empty-account copy).
  defp drawer_no_matches?(_channel_sections, _sidebar_sections, "", _user_id), do: false

  defp drawer_no_matches?(channel_sections, sidebar_sections, query, user_id) do
    drawer_filter_spaces(channel_sections.pinned, query) == [] and
      drawer_filter_dms(channel_sections.dms, query, user_id) == [] and
      drawer_filter_sections(sidebar_sections, query) == []
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
  # Task 019e95ea stage 2: UI mirror of the context-layer archive/unarchive
  # authorization (Fabrikam admin or space creator). Affordance only — the real
  # gate is `with_space_lifecycle_authz/3` inside `Chat.unarchive_space/2`.
  defp can_unarchive?(space, user_id) do
    Platform.Tenancy.fabrikam_admin?(%{id: user_id}) or space.created_by == user_id
  end

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
  @spec channel_sections(
          [Platform.Chat.Space.t()],
          [Platform.Chat.Space.t()],
          MapSet.t(String.t()),
          MapSet.t(String.t())
        ) :: %{
          pinned: [Platform.Chat.Space.t()],
          dms: [Platform.Chat.Space.t()],
          sub_orgs: %{String.t() => [Platform.Chat.Space.t()]},
          hidden_sub_orgs: %{String.t() => [Platform.Chat.Space.t()]}
        }
  def channel_sections(
        channels,
        dm_conversations,
        pinned_channel_ids \\ MapSet.new(),
        hidden_channel_ids \\ MapSet.new()
      )
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

    # Drop hidden ids from sub-org buckets and DMs (Pinned is non-hideable
    # per Stage 2 plan — pinned stays whole as defense-in-depth even if a
    # pinned channel id somehow ended up in the user's hidden set).
    # Stage 3: also expose the per-bucket hidden list under `hidden_sub_orgs`
    # so the header `Hidden (N)` chip and the inline unhide list can render
    # without re-doing the bucketing/filter in the template.
    {visible_dms, _hidden_dms} = HiddenChannels.filter(dm_conversations, hidden_channel_ids)

    bucketed =
      Map.new(sub_orgs, fn {bucket, spaces} ->
        {visible, hidden} = HiddenChannels.filter(spaces, hidden_channel_ids)
        {bucket, %{visible: visible, hidden: hidden}}
      end)

    visible_sub_orgs = Map.new(bucketed, fn {bucket, %{visible: v}} -> {bucket, v} end)
    hidden_sub_orgs = Map.new(bucketed, fn {bucket, %{hidden: h}} -> {bucket, h} end)

    %{
      pinned: pinned,
      dms: visible_dms,
      sub_orgs: visible_sub_orgs,
      hidden_sub_orgs: hidden_sub_orgs
    }
  end

  # ── Resolver-driven sub-org rail (chat sidebar v3 Stage 4) ─────────────
  #
  # The sub-org rail now renders from `Sidebar.resolve_for_user/2` — the
  # org-default sections (one per org, `channel_sections` table) merged with
  # the user's personal arrangement prefs. Channels are distributed into
  # sections by `chat_spaces.org_id` (the identity key), replacing the old
  # name-pattern bucketing in `channel_sections/4` (kept only for the
  # pure-function grouping tests + the Pinned/DMs derivation above).
  #
  # We feed the resolver the *visible* channels — non-hidden, non-pinned
  # `kind: "channel"` spaces — so hidden/pinned handling stays consistent
  # with the rest of the rail. Pinning isn't wired yet (empty pinned set
  # today), so `channels` minus hidden is the visible set.
  #
  # Section ORDER is owned entirely by `Sidebar.resolve_for_user/2`, the single
  # source of ordering truth: it reads the user's `chat_section_order` prefs (a
  # list of section IDS) and applies its id-keyed `order_sections/2` —
  # skip-unknown, append-unplaced-by-position. That means:
  #
  #   * No personal order (fresh user / cleared pref) → `Section.position`
  #     order, so an admin reorder is visible to every non-customized user.
  #   * A personal order → those sections first in the saved id order, any
  #     others appended by position. IDs are stable across admin rename/recolor
  #     (HIGH audit finding #3), so a personal arrangement survives both.
  #
  # The LiveView used to RE-order the resolver output by a name-keyed personal
  # order (a holdover from when prefs stored names, which Sidebar's id-keyed
  # resolver couldn't interpret). With prefs now id-keyed that second pass was
  # redundant AND could disagree with the resolver for partial orders, so it's
  # gone — there is now exactly ONE ordering pass.
  @spec resolve_sidebar_sections(
          binary() | nil,
          [Platform.Chat.Space.t()],
          MapSet.t()
        ) ::
          [Sidebar.resolved()]
  defp resolve_sidebar_sections(user_id, channels, hidden_ids) do
    {visible_channels, _hidden} = HiddenChannels.filter(channels, hidden_ids)

    Sidebar.resolve_for_user(user_id, visible_channels)
  end

  # Apply an explicit section-id order to already-resolved sections IN-MEMORY,
  # used only by the personal-reorder handler so the rail reflects a drag even
  # when persistence fail-softs (anonymous / deleted user row). The persisted
  # prefs remain the source of truth for every other recompute path; this is a
  # one-shot overlay for the dragging tab. Sections absent from `ids` sort to
  # the tail in their resolver order.
  defp order_resolved_by_ids(resolved, ids) when is_list(ids) do
    rank = ids |> Enum.with_index() |> Map.new()
    fallback = length(ids)

    Enum.sort_by(resolved, fn %{section: section} ->
      Map.get(rank, section.id, fallback)
    end)
  end

  # Map a section's `color` token (CSS form, e.g. "wayne-tech") to the scope
  # atom the `scope_pill` component takes. Unknown tokens return `nil` so the
  # template can fall back to a plain header without a pill rather than
  # crashing on an unrecognized scope.
  @doc false
  @spec section_scope_atom(String.t() | nil) :: atom() | nil
  def section_scope_atom("paragon"), do: :paragon
  def section_scope_atom("soylent"), do: :soylent
  def section_scope_atom("fabrikam"), do: :fabrikam
  def section_scope_atom("wayne-tech"), do: :wayne_tech
  def section_scope_atom("sxi"), do: :sxi
  def section_scope_atom(_), do: nil

  # Map a section's `color` token (CSS form, e.g. "wayne-tech") to its color-only
  # dot utility class (`bg-<token>-dot`, defined in app.css). Used by the
  # section header to render a decorative color swatch WITHOUT a text label —
  # the section's identity text comes solely from `section.name`. Decoupling the
  # swatch from the scope enum is the fix for "recolor renames the chip": the
  # dot reflects color only, never a name. Unknown tokens return `nil` so the
  # template omits the dot rather than rendering a class-less span.
  @doc false
  @spec section_dot_class(String.t() | nil) :: String.t() | nil
  def section_dot_class("paragon"), do: "bg-paragon-dot"
  def section_dot_class("soylent"), do: "bg-soylent-dot"
  def section_dot_class("fabrikam"), do: "bg-fabrikam-dot"
  def section_dot_class("wayne-tech"), do: "bg-wayne-tech-dot"
  def section_dot_class("sxi"), do: "bg-sxi-dot"
  def section_dot_class(_), do: nil

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
  # The per-user `chat_section_order` is a list of section IDS (HIGH audit
  # finding #3 — IDs are stable across admin rename/recolor, names are not).
  # ORDER RESOLUTION lives entirely in `Sidebar.resolve_for_user/2` +
  # `Sidebar.order_sections/2` (id-keyed, skip-unknown, append-unplaced): no
  # pref → `Section.position` (admin default); a saved order → those sections in
  # the saved id order, the rest appended by position. Writes go through
  # `Sidebar.put_section_order/2` (also id-keyed). There's no LiveView-side
  # validation gate or re-ordering pass anymore — that was a holdover from the
  # name-keyed era when Sidebar's id resolver couldn't interpret the prefs.

  @doc """
  Move `from` to `to`'s slot in `order`. The displaced item and everything
  between shifts one position toward `from`'s former slot — standard
  drag-reorder semantics.

  Generic over the element type — both the personal and admin reorder paths
  pass section IDS. Returns the input list unchanged when:
    * `from == to` (drop on self)
    * either id is absent from `order` (defensive — JS shouldn't emit
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

  # Resolve the URL nav target for a space link. For org-scoped channels
  # (post-ADR-0042: any space with a non-nil `org_id`), return the space's
  # UUID so the URL handler's UUID-fallback branch hits `Chat.get_space/1`
  # exactly — bypassing the slug-then-org-resolve cascade that would
  # otherwise route ambiguous slugs (e.g. "general") to the user's PRIMARY
  # membership org, not the org of the section they actually clicked.
  # For org-less spaces (DMs / pre-ADR-0042 legacy channels), keep the
  # slug-when-present behavior so shareable-DM-link semantics are preserved
  # (`|| id` covers DMs without a slug).
  #
  # Map-pattern signature so it works on both the loaded `%Space{}` struct
  # and any plain map carrying `:org_id`, `:slug`, `:id` (e.g. test fixtures).
  @doc false
  @spec space_nav_target(map()) :: String.t()
  def space_nav_target(%{org_id: org_id, id: id}) when not is_nil(org_id), do: id
  def space_nav_target(%{slug: slug, id: id}), do: slug || id
  def space_nav_target(%{id: id}), do: id

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

  # `section_slug/1` (bucket-name → slug) was retired in Stage 4: the
  # resolver-driven rail sets `data-section-slug` directly from a section's
  # `color` token (already in CSS slug form, e.g. "wayne-tech"), so the
  # name→slug mapping is no longer needed. Its inverse `bucket_from_slug/1`
  # is kept below — the Stage 3 `section_reordered` handler still translates
  # the JS hook's slug payload back to the section name.

  # `bucket_from_slug/1`: translates the SectionReorder hook's slug payload
  # back to the bucket display name used by the `section_reordered` handler.
  # Reuses the `@sub_org_slug_to_bucket` mapping that `channel_scope/1` needs
  # for the (Pinned/DMs) classification pass.
  @doc false
  @spec bucket_from_slug(String.t()) :: String.t() | nil
  def bucket_from_slug(slug) when is_binary(slug) do
    Map.get(@sub_org_slug_to_bucket, String.downcase(slug))
  end

  def bucket_from_slug(_), do: nil

  # ── Pin-to-Chat helpers (task 019f62a1 stage 4) ────────────────────────
  #
  # `fetch_user_email_for_pins/1` is the one Repo hop we allow at mount to
  # translate the session `current_user_id` UUID into the email the
  # `task_chat_pins` table indexes by. `Accounts.get_user/1` also preloads
  # `:org_memberships` for the LiveAuth on_mount hook so the record it
  # returns is already warm — no extra query. Nil on missing user, keeping
  # anonymous / deleted-user sessions from lighting up the pin flow.
  defp fetch_user_email_for_pins(nil), do: nil

  defp fetch_user_email_for_pins(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %{email: email} when is_binary(email) -> email
      _ -> nil
    end
  end

  # Central refresh point for the pinned-tasks rail. Called from BOTH
  # `:task_pin_added` (after the per-space subscribe) and `:task_pin_removed`.
  # Also refreshes `:spaces` — the ChatLive template's channel-lookup paths
  # (unread counts, active-space matching) all read from `@pinned_task_spaces`
  # for the rail rows, but downstream unread-count aggregation walks
  # `@spaces` to know which space ids to consider.
  defp refresh_pinned_task_spaces(socket) do
    case socket.assigns[:current_user_email] do
      nil ->
        socket

      email ->
        pinned = Platform.Tasks.ChatPins.list_pinned_task_spaces_for(%{kind: "user", id: email})
        channels = socket.assigns[:channels] || []
        dm_conversations = socket.assigns[:dm_conversations] || []

        socket
        |> assign(:pinned_task_spaces, pinned)
        |> assign(:spaces, channels ++ pinned ++ dm_conversations)
    end
  end

  @impl true
  def terminate(_reason, socket) do
    MeetingHooks.on_terminate(socket)
    :ok
  end
end
