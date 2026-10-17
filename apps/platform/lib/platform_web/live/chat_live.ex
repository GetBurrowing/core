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
  import Ecto.Query, only: [from: 2]

  import PlatformWeb.ChatLive.Partials
  import PlatformWeb.ChatLive.Partials.Composer
  import PlatformWeb.ChatLive.Partials.Conversation
  import PlatformWeb.ChatLive.Partials.ExternalRail
  import PlatformWeb.ChatLive.Partials.MobileBrowser
  import PlatformWeb.ChatLive.Partials.Overlays
  import PlatformWeb.ChatLive.Partials.MessageContext, only: [message_context_overlay: 1]
  import PlatformWeb.ChatLive.Partials.Rail
  import PlatformWeb.ChatLive.RenderHelpers

  alias Platform.Accounts
  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Chat
  alias Platform.Chat.ClosedDms
  alias Platform.Chat.HiddenChannels
  alias Platform.Chat.PinnedSpaces
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Section
  alias Platform.Chat.Sidebar

  alias PlatformWeb.ChatLive.ActiveAgentHooks
  alias PlatformWeb.ChatLive.CanvasHooks
  alias PlatformWeb.ChatLive.GoalCadenceForm
  alias PlatformWeb.ChatLive.MeetingHooks
  alias PlatformWeb.ChatLive.MentionsHooks
  alias PlatformWeb.ChatLive.MessageContextHooks
  alias PlatformWeb.ChatLive.MessagesHooks
  alias PlatformWeb.ChatLive.NewChannelComponent
  alias PlatformWeb.ChatLive.NewConversationComponent
  alias PlatformWeb.ChatLive.PinHooks
  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ChatLive.PrototypeUpload
  alias PlatformWeb.ChatLive.SearchHooks
  alias PlatformWeb.ChatLive.MembersComponent
  alias PlatformWeb.ChatLive.SettingsComponent
  alias PlatformWeb.ChatLive.LargeUploadHooks
  alias PlatformWeb.ChatLive.UploadHooks
  alias PlatformWeb.Extensions
  alias PlatformWeb.LifecycleActions
  alias PlatformWeb.ShellLive
  alias PlatformWeb.SpaceTopics

  # The quick-react row's contents, for every surface that renders one: the
  # desktop hover action row, the mobile double-tap pill and the mobile
  # message-actions sheet. All three take it from this assign, and this assign
  # now has exactly one source (task 019e0814 stage 2).
  #
  # It used to be a FOUR-emoji literal on this line while the longpress pill
  # carried a SIX-emoji `~w()` of its own, so the product disagreed with itself
  # about what a quick reaction is — on the same message, in the same account,
  # differing only by which device it was opened on. Six is the number the
  # ticket asks for and the number already live on touch, so four was the odd
  # one out.
  #
  # STATIC AND SYSTEM-WIDE, deliberately. Nothing per-user, per-space or
  # per-session feeds this: no recents, no last-used, no override column. Two
  # people looking at one message get the same emoji in the same order, on any
  # device, on their first day and their thousandth — which is what makes the
  # row teachable and its screenshots stable. `Platform.Chat.Emoji` records
  # what changing that would cost.
  #
  # Resolved at compile time, so `Platform.Chat.Emoji` is a compile-time
  # dependency of this module and editing the set recompiles this file.
  @quick_emojis Platform.Chat.Emoji.quick_defaults()
  @max_upload_entries 5
  @max_upload_size 15_000_000

  # How long the `?message=` arrival ring stays on before it is cleared
  # (task 019fabe8 stage 2). Long enough for the reader to register where
  # they landed, short enough that the marker never becomes permanent
  # decoration. Overridable via `:anchor_highlight_ms` so tests can drive
  # the real timer instead of asserting on a hand-sent message.
  @anchor_highlight_ms 6_000

  @doc """
  The per-file chat attachment cap, in bytes. Public so the native app's
  share endpoint (`PlatformWeb.AppApiController`) enforces the same number
  as the composer instead of a second copy of it (task 01a10882).
  """
  @spec max_upload_size() :: pos_integer()
  def max_upload_size, do: @max_upload_size

  # How long the move confirmation stays at the foot of the rail (task 019ffcad
  # stage 4). The same 4s the hide toast uses, because it is the same element in
  # the same place and the stage asks for the same dismissal.
  @move_toast_ms 4_000

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
  @spec presence_subscribe_space_ids([%{id: binary()}], binary(), Platform.Access.Scope.t() | nil) ::
          [binary()]
  def presence_subscribe_space_ids(all_spaces, user_id, access_scope \\ nil) do
    ids = Enum.map(all_spaces, & &1.id)

    ids =
      if Platform.Tenancy.external_user?(%{id: user_id}) do
        scope = Platform.Chat.Presence.external_scope_space_ids(user_id)
        Enum.filter(ids, &MapSet.member?(scope, &1))
      else
        ids
      end

    case {ids, access_scope} do
      {[], _} ->
        []

      {ids, %Platform.Access.Scope{} = scope} ->
        readable =
          from(s in Platform.Chat.Space, where: s.id in ^ids, select: s.id)
          |> Platform.Access.Query.restrict(scope, "chat.read", :space, %{id: :id})
          |> Platform.Repo.all()
          |> MapSet.new()

        Enum.filter(ids, &MapSet.member?(readable, &1))

      {ids, _} ->
        ids
    end
  end

  # The set of spaces this session holds a rail-driven PubSub subscription for
  # (task 01a011e9). `handle_params/3`'s teardown asks it one question: did the
  # space being left have a subscription before it became active, and therefore
  # does leaving owe it one back?
  #
  # Derived, never stored. The same `presence_subscribe_space_ids/2` over the
  # same `channels ++ pinned_task_spaces ++ dm_conversations` that `mount/3`
  # subscribes from, read off the assigns rather than re-queried, so the two can
  # only ever agree. An assign captured at mount would have to be recomputed at
  # every site that rebuilds the rail — `:space_created` and `:task_pin_added`
  # both subscribe a new topic AND refresh those assigns — and the first one
  # that forgot would silently stop restoring that row's subscription.
  #
  # Costs one `external_user?/1` existence query per navigation, on a path that
  # already re-reads the channel list, the participant roster and the pinned
  # spaces. Paid deliberately: reusing the mount function verbatim is what makes
  # drift impossible, and a cached copy of the answer is the bug being fixed.
  @spec rail_subscribe_space_ids(Phoenix.LiveView.Socket.t()) :: MapSet.t(binary())
  defp rail_subscribe_space_ids(socket) do
    %{
      channels: channels,
      pinned_task_spaces: pinned_task_spaces,
      dm_conversations: dm_conversations,
      user_id: user_id
    } = socket.assigns

    (channels ++ pinned_task_spaces ++ dm_conversations)
    |> presence_subscribe_space_ids(user_id, socket.assigns[:access_scope])
    |> MapSet.new()
  end

  # The space topics this session holds a registration for, and the only two
  # functions in this module allowed to change that (tasks 01a017a3, 01a01a1b).
  #
  # `Phoenix.PubSub`'s registry runs `keys: :duplicate`, so `subscribe/1` is not
  # idempotent per pid — a second call adds a SECOND registration and every
  # broadcast on the topic is then delivered twice — and `unsubscribe/2` is
  # `Registry.unregister/2`, which drops EVERY registration this pid holds for
  # the topic at once. Neither call can be issued safely without knowing what is
  # already held.
  #
  # The bookkeeping that answers "what is already held" is PROCESS-scoped, not
  # module-scoped, and lives in `PlatformWeb.SpaceTopics`. That distinction is
  # the whole of task 01a01a1b: `PlatformWeb.ShellLive` is an `on_mount` hook
  # (`router.ex`, `live_session :authenticated`) and so runs in THIS pid, and
  # `PlatformWeb.TasksLive` shares the socket too. A held set private to this
  # module could see its registrations destroyed by a sibling surface's
  # `unsubscribe` and would then decline to re-subscribe — a silently dead
  # topic, which is strictly worse than the duplicate delivery it set out to
  # fix. `SpaceTopics` is the single writer for every surface on the pid, and
  # these two helpers are this module's only door to it.
  #
  # EVERY `ChatPubSub.subscribe/1` and `ChatPubSub.unsubscribe/1` for a
  # `chat:space:<id>` topic in this module goes through this pair. The `owner`
  # is explicit at every call site and never inferred: `:chat_rail` for the
  # rail's background subscriptions (mount loop, `:sidebar_changed` reconcile,
  # `:space_created`, `:task_pin_added`) and `:chat_active` for the space the
  # viewer is actually looking at. They are separate holds on purpose — a rail
  # space that becomes active and is then navigated away from must KEEP its
  # rail hold, and that is what makes the old unsubscribe-then-restore dance in
  # `handle_params/3` unnecessary.
  #
  # `rail_subscribe_space_ids/1` above is the DESIRED set, derived from the rail
  # assigns. The HELD set is `SpaceTopics`'. They answer different questions, and
  # the gap between them is what the reconcile closes.
  @spec subscribe_space(Phoenix.LiveView.Socket.t(), binary(), SpaceTopics.owner()) ::
          Phoenix.LiveView.Socket.t()
  defp subscribe_space(socket, space_id, owner) do
    SpaceTopics.hold(socket, space_id, owner)
  end

  # Releases only THIS owner's hold. The topic is unsubscribed iff no other
  # surface on the pid still holds it, because `unsubscribe/2` really does drop
  # all of this pid's registrations at once and a release by a non-holder would
  # therefore destroy somebody else's registration.
  @spec unsubscribe_space(Phoenix.LiveView.Socket.t(), binary(), SpaceTopics.owner()) ::
          Phoenix.LiveView.Socket.t()
  defp unsubscribe_space(socket, space_id, owner) do
    SpaceTopics.release(socket, space_id, owner)
  end

  # ADD-ONLY, deliberately. Every id comes through `presence_subscribe_space_ids/2`
  # (via `rail_subscribe_space_ids/1`), so this can never widen back to
  # subscribe-to-everything, which is the defect task 01a011d4 exists to remove.
  #
  # Releasing the subscription for a space that DROPPED OUT of the rail is task
  # 01a0181f (revoke) and is out of scope here. Taking the difference in both
  # directions would mean issuing an `unsubscribe`, and on a `keys: :duplicate`
  # registry that drops every registration this pid holds for the topic at once,
  # which is what task 01a011e9 had to repair on the navigation path.
  #
  # No held-set query in front of the loop, and none is needed: `hold/3` is
  # idempotent for a repeated hold by the same owner, so re-holding a
  # `:chat_rail` space this session already holds registers nothing. That is why
  # task 01a01a1b could delete `:subscribed_space_ids` outright rather than
  # re-express it as a `SpaceTopics` query — the decision this reconcile used to
  # take off the held set is now taken inside the single writer, where it cannot
  # be taken off a stale copy.
  #
  # Costs one `external_user?/1` existence query per `:sidebar_changed`. The
  # same cost is already accepted per navigation (see `rail_subscribe_space_ids/1`);
  # a cache of the answer is the shape of the bug being fixed.
  #
  # The caller reloads `@channels`, `@archived_channels` and — since task
  # 01a01ccf — `@dm_conversations`, so three of the arms this reconcile reads
  # are fresh. A DM or group conversation a user is added to mid-session is now
  # reached from here.
  #
  # REMAINING GAP, pre-existing and deliberately not widened: `@pinned_task_spaces`
  # is still read off an assign this path never refreshes. Left alone because it
  # has its own live path — `:task_pin_added` / `:task_pin_removed` call
  # `refresh_pinned_task_spaces/1`, which refreshes `@spaces` alongside it — so a
  # redundant pin re-read on every sidebar change would close no defect.
  defp reconcile_rail_subscriptions(socket) do
    if connected?(socket) do
      socket
      |> rail_subscribe_space_ids()
      |> Enum.reduce(socket, &subscribe_space(&2, &1, :chat_rail))
    else
      socket
    end
  end

  defp do_mount(session, socket, opts) do
    embedded? = Keyword.fetch!(opts, :embedded?)
    user_id = session["current_user_id"] || Ecto.UUID.generate()
    # Only consulted on the embedded path; standalone uses handle_params.
    embedded_space_slug = if embedded?, do: session["chat_space_slug"]

    # rbac-external-users M5: the chrome-less external chat surface. Derive the
    # read-scope + render flag from the user's IDENTITY, never from the host-set
    # `chat_mode` session key.
    #
    # SECURITY (task 019f9257): `chat_mode => "external"` is merged ONLY by M4's
    # `:external_chat` live_session on the `chat.` host. On the suite (`:app`)
    # host the internal `:authenticated` live_session carries NO `chat_mode`, so
    # keying `external?`/`external_scope` off it left an external user served on
    # the suite host with `external_scope = nil` → `Chat.list_spaces(scope: nil)`
    # is pass-through → EVERY channel across EVERY org leaked into their rail.
    #
    # FIX: build M7's read-scope ONCE via `ExternalScope.for_user/1` (a single
    # membership `EXISTS`) UNCONDITIONALLY, and derive `external?` from the
    # struct's precomputed flag. `for_user/1` yields `external?: false` for every
    # internal id → `scope_spaces/2` is pass-through → the internal rail is
    # byte-for-byte unchanged; and an external identity can NEVER be scoped `nil`
    # regardless of host or live_session. The scope is then threaded into every
    # rail read so the external user's rail lists ONLY the spaces they are a
    # `chat_participants` member of.
    #
    # Embedded is an internal meeting surface (the LiveKit chat pane) — it paints
    # ONE space, populates no sidebar, and must never render external chrome, so
    # it short-circuits to a nil (pass-through) scope and `external? = false`.
    #
    # BOUNDARY: M5 owns the RENDER branch only. The scope threaded here filters
    # what the rail SHOWS; the guarantee that an external user cannot REACH an
    # off-limits space is M6's plug + M7's query filter, not this render.
    #
    # RBAC v2 (task 01a1386d-e528 stage 3): when LiveAuth assigned an
    # `@access_scope` for THIS user, it IS the read-scope, so explicit grants
    # compose into every rail read (`ExternalScope`'s Scope clauses). Otherwise
    # `ExternalScope.for_user/1`, as before; its return type never changes.
    #
    # THE SWITCH HAZARD: a `%Platform.Access.Scope{}` does not match
    # `%ExternalScope{external?: true}`, so the old `match?/2` would read every
    # guest as internal and hand them the unscoped archived-channel list below.
    # `external?` is therefore asked of each struct through `guest_scope?/1`
    # (`Platform.Access.Scope.guest?/1` for a Scope), never by a struct match.
    # Both live in `PlatformWeb.ChatLive.ReadScope`. Guard:
    # `test/platform_web/live/chat_live_access_scope_guest_test.exs`.
    access_scope = socket.assigns[:access_scope]

    {external_scope, external?} =
      PlatformWeb.ChatLive.ReadScope.resolve(access_scope, user_id, embedded?)

    readable_channels =
      if embedded?, do: [], else: Chat.list_spaces(kind: "channel", scope: external_scope)

    listed_channels =
      if embedded?,
        do: [],
        else:
          Chat.list_spaces(kind: "channel", scope: channel_listing_scope(external?, user_id))
          |> PlatformWeb.ChatLive.ReadScope.within_org_fence(access_scope)

    # Archived channels (task 019e95ea stage 2) feed ONLY the sidebar's
    # collapsed "Archived" group — they are deliberately kept out of
    # `channels` / `channel_sections/4` so no active bucket renders them.
    # External users get NONE: the archived group is an internal discovery
    # surface (design canvas §1 non-goals).
    archived_scope = PlatformWeb.ChatLive.ReadScope.fenced_scope(access_scope)

    archived_channels =
      if embedded? or external?,
        do: [],
        else: Chat.list_spaces(kind: "channel", archived: true, scope: archived_scope)

    restricted_channel_ids =
      restricted_channel_ids(
        socket,
        readable_channels ++ listed_channels,
        archived_channels,
        user_id
      )

    channels =
      include_restricted_channels(readable_channels, listed_channels, restricted_channel_ids)

    # `dm_conversations_for/3` and not the socket-shaped `rail_dm_conversations/1`:
    # none of these three values is in `socket.assigns` yet — they are assigned
    # further down this function — so the wrapper would read three nils here.
    dm_conversations = dm_conversations_for(user_id, external_scope, embedded?)

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

    # Read ONCE (task 01a0ca8b): the same value feeds `@agents_block` and the
    # org-list exclusion in `resolve_sidebar_sections/4`, so mount cannot see
    # two different answers to "which space does the block show".
    agents_block = Sidebar.agents_rail_block()

    socket =
      socket
      |> assign(:page_title, "Chat")
      # Screen-share name masking (task 01a00c66). Session-only view state:
      # OFF by default, never persisted to a preferences row / cookie /
      # localStorage, never broadcast.
      #
      # THESE TWO LINES ARE THE WHOLE PERSISTENCE MODEL, and they only hold
      # because channel switching is a `patch`, not a `navigate`. Stage 6
      # found the opposite: every rail row in `chat_live.html.heex` used
      # `<.link navigate=…>`, which remounts ChatLive over the same socket, so
      # `mount/3` re-ran and BOTH the mask flag and the per-org reveal set were
      # reset mid-screen-share — real names silently repainting, with the strip
      # that would have signalled it gone from the DOM too. Those rows are now
      # `<.link patch=…>`; `handle_params/3` already did 100% of the
      # per-channel work, so no state had to move.
      #
      # The LiveView process lifetime IS the session scope, structurally:
      #   * in-session nav → patch → same process → both assigns survive
      #   * full page reload → new process → assigns start fresh → the rail
      #     comes back with REAL names, which is deliberate. Someone who
      #     masked for one call and returns next morning must not find a rail
      #     where their orgs appear to be missing.
      # Do NOT "improve" this with sessionStorage: it survives a reload and
      # would break the second bullet.
      #
      # If you add a new way to reach `/chat/:space_slug` from inside this
      # LiveView, it must be a patch. A `navigate` re-enters `mount/3` here
      # and silently unmasks.
      |> assign(:mask_names?, false)
      |> assign(:revealed_section_ids, MapSet.new())
      |> assign(:user_id, user_id)
      # The HELD PubSub subscribe set is NOT an assign of this module. Task
      # 01a01a1b moved it to `PlatformWeb.SpaceTopics`, whose `:chat_space_holders`
      # assign is shared by every surface on this pid. Two records of one fact
      # can only disagree about time, so `:subscribed_space_ids` was deleted
      # rather than kept in step. Seeded here as well as in ShellLive's
      # `on_mount` hook because `ensure_holders/1` is idempotent and neither
      # mount may assume it ran first.
      |> SpaceTopics.ensure_holders()
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
      # Agents goal surface (task 01a0b491 stage 4). All four are nil/false
      # whenever `AGENTS_GOAL_SURFACE` is unset: `agents_rail_block/0` and
      # `goal_panel/1` both return nil behind the flag, so the rail block and
      # the header strip render zero DOM and the stage-1 columns stay inert
      # even when they hold values.
      #
      # `@goal_panel` is re-derived in `assign_active_space/2` on every space
      # change; seeded here because `mount/3` has no active space yet and the
      # component's attrs are `required: true`.
      |> assign(:agents_block, agents_block)
      |> assign(:goal_panel, nil)
      |> assign(:goal_edit, false)
      |> assign(:goal_invite?, false)
      |> assign(:goal_scope_options, [])
      |> assign(:goal_scope_error, nil)
      # Check progress (task 01a0e882 stage 3): the open editor's cadence
      # selection (nil while closed) and the viewer's zone for its hour
      # labels. `get_connect_params/1` is root-and-mount-only, so the
      # embedded child LV (no goal editor) never asks.
      |> assign(:goal_cadence_form, nil)
      |> assign(
        :goal_time_zone,
        if(!embedded?, do: GoalCadenceForm.time_zone(get_connect_params(socket)))
      )
      |> assign(:archived_channels, archived_channels)
      |> assign(:restricted_channel_ids, restricted_channel_ids)
      # Collapse state for the sidebar's "Archived" group (task 019e95ea
      # stage 2) — collapsed by default, toggled by `toggle_archived_section`.
      |> assign(:archived_open, false)
      # Whether the CURRENT user may unarchive the active space (root-org admin
      # or creator). UI affordance only — `Chat.unarchive_space/2` is the
      # gate. Recomputed wherever :active_space is (re)assigned.
      |> assign(:can_unarchive?, false)
      # Whether the CURRENT user may cancel a scheduled deletion on the
      # active space (task 019e95ea stage 4). root-org admin ONLY — creators
      # don't qualify, mirroring `Chat.cancel_space_deletion/2`. Affordance
      # only; recomputed wherever :active_space is (re)assigned.
      |> assign(:can_cancel_deletion?, false)
      |> assign(:dm_conversations, dm_conversations)
      |> assign(:hidden_channel_ids, Accounts.get_hidden_channel_ids(user_id))
      # The user's closed DMs as `%{space_id => closed_at}` (task 019ffc5f).
      # Held as an assign for the same reason `:hidden_channel_ids` is: EVERY
      # site that rebuilds `@channel_sections` has to pass it, and a site that
      # forgets renders a rail with a closed DM back on it until the next
      # navigation. Timestamps rather than ids, because the row's return is a
      # comparison against its newest activity.
      |> assign(:closed_dm_at, Accounts.get_closed_dm_at(user_id))
      # Task 019ffb7b stage 5: whether this user has dismissed the notification
      # opt-in banner. Read from `users.preferences` on every mount — same
      # column and same read-at-mount / write-on-event shape as
      # `:hidden_channel_ids` on the line above — so the dismissal survives a
      # reload instead of dying with the LiveView process.
      |> assign(
        :notification_banner_dismissed,
        Accounts.notification_banner_dismissed?(user_id)
      )
      # The user's pinned conversations, ordered most-recently-pinned last
      # (task 019fd80f). Held as an assign so every rail recompute below can
      # pass the same list without re-reading preferences; the Pinned block
      # empties itself on the next channel switch if any site forgets.
      |> assign(:pinned_space_ids, Sidebar.list_pinned_space_ids(user_id))
      |> assign(
        :channel_sections,
        channel_sections(
          channels,
          dm_conversations,
          Sidebar.list_pinned_space_ids(user_id),
          Accounts.get_hidden_channel_ids(user_id),
          Accounts.get_closed_dm_at(user_id)
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
      # Task 019ffcad stage 4: the move confirmation at the foot of the rail.
      # `%{channel_id: <uuid>, channel_name: <name>, section_name: <name>}` while
      # active, `nil` otherwise. Cleared by `{:clear_move_toast, channel_id}` on
      # the same guarded-late-fire pattern as the hide toast above.
      #
      # A SEPARATE assign from `:undo_toast` rather than a second variant of it.
      # The two lines are raised by different verbs that a person can perform
      # seconds apart, and on one assign whichever came second would silently
      # blank the first. Task 019ffc5f already tried sharing this element between
      # two verbs and Marlowe rejected the result, so the shared surface stays and
      # the state does not.
      |> assign(:move_toast, nil)
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
          Accounts.get_hidden_channel_ids(user_id),
          agents_block
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
      # root-admin "Edit default" mode (chat sidebar Stage 6). A SEPARATE mode
      # from the personal "Edit layout" (@sidebar_edit): admin-edit routes the
      # same gestures to the GLOBAL org default (Sidebar Stage 2 API) instead
      # of the acting user's prefs, so a root-org admin curates what every user
      # sees by default. Visible ONLY to root-org admins (@root_admin? gate) and
      # mutually exclusive with @sidebar_edit — entering one exits the other.
      #
      # We compute @root_admin? here from the resolved user_id (rather than
      # relying solely on the LiveAuth `:default` on_mount that also assigns it
      # on the /chat route) so the assign is guaranteed present on BOTH mount
      # paths — the standalone surface AND the embedded child LV (which mounts
      # via `embedded_mount/3` and does not run the LiveAuth on_mount chain).
      # The actor we pass to every Sidebar.* admin write is `%{id: user_id}`,
      # the same shape root_admin?/1 authorizes, so the client-side toggle and
      # the server-side gate agree. Desktop only — the whole rail is
      # `hidden lg:flex`; the admin toggle lives inside that aside.
      |> assign(:root_admin?, Platform.Tenancy.root_admin?(%{id: user_id}))
      # Who may edit the goal. root-org admin only, mirroring
      # `:can_cancel_deletion?` above: the goal is org-wide state with a
      # daily heartbeat behind it, not a per-user preference. This is an
      # AFFORDANCE — `save_goal` re-checks it server-side before writing.
      |> assign(:can_edit_goal?, Platform.Tenancy.root_admin?(%{id: user_id}))
      # Container-lifecycle affordances on the org section headers (task
      # 019f4eaa stage 6). `:tenant_org_ids` is the set of NON-root org ids —
      # the root section never gets archive controls (the lifecycle
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
      # Explicit "Move to organisation…" (task 019fd76a stage 1).
      # `:reassign_picker` is nil or the `%{channel_id:, channel_name:,
      # destinations:}` the destination chooser renders (one row at a time);
      # `:reassign_confirm` is nil or the resolved
      # `%{channel_id:, channel_name:, from:, to:}` the confirmation dialog
      # renders AND the confirm handler writes from. Nothing is written until
      # the confirm event fires.
      |> assign(:reassign_picker, nil)
      |> assign(:reassign_confirm, nil)
      # Sidebar layout overflow menu (chat sidebar header). The "CHANNELS"
      # header is a ~260px rail that can't fit two text toggles (personal
      # "Edit layout" + admin "Edit default"), so both entry points collapse
      # into ONE kebab/"More" button that opens this popover. `false` = closed.
      # Entering either edit mode (toggle_sidebar_edit / _admin_edit) closes it
      # so the header never shows both the menu and an active edit mode at once.
      |> assign(:sidebar_menu_open, false)
      |> assign_active_space(nil)
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
      # Mobile drawer row-actions sheet (task 019fe998): nil when closed,
      # else the space_id of the row whose overflow control was tapped. Only
      # the ID is held — name and pinned-ness are re-derived at render by
      # `row_actions_target/5`, so the sheet's header and its Pin/Unpin verb
      # stay correct after any change to the underlying row. Same shape as
      # `:open_message_actions_id` above.
      |> assign(:row_actions_space_id, nil)
      |> assign(:show_new_channel_modal, false)
      # The org a new channel is filed into by default, and the destinations
      # offered (task 01a00910 stage 5). Both come from `org_bucket_index/0`,
      # the SAME index the rail buckets by and the "Move to organisation…"
      # picker reads — a second source of org options is exactly the
      # disagreeing-lists defect this task exists to kill.
      |> assign(:active_org_id, resolve_active_org_id(socket))
      |> assign(:new_channel_org_options, new_channel_org_options(user_id))
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
      # Channel members panel (task 01a0fd62 stage 3, MembersComponent).
      |> assign(:show_members, false)
      |> assign(:quick_emojis, @quick_emojis)
      # `:push_permission` is seeded by `PlatformWeb.ShellLive`'s on_mount
      # (task 019ffb7b stage 3), which every live_session ChatLive is routed
      # under runs. Seeding it a second time here would overwrite a state the
      # hook may already have reported.
      |> assign(:unread_counts, Chat.unread_counts_for_user(user_id))
      |> assign(:lightbox_url, nil)
      # Jump-to-latest state (task 01a03c76 stage 1; `:jump_deep_in_history`
      # added by task 01a0419a stage 4). Both booleans are reported by the
      # ScrollToBottom hook — the NEAR_BOTTOM_PX (150) and DEEP_HISTORY_PX
      # (1800) thresholds stay in JS so no pixel count is duplicated
      # server-side. `:jump_new_message_count` counts top-level messages from
      # OTHER participants that arrived while away from the tip. The three
      # compose into the control's visibility in ONE place —
      # `MessagesHooks.jump_chip_visible?/3` — so the template never spells
      # the rule out itself.
      |> assign(:jump_away_from_bottom, false)
      |> assign(:jump_deep_in_history, false)
      |> assign(:jump_new_message_count, 0)
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
      # The New canvas form's Prototype drop zone (task 01a1316b-4e46 stage
      # 2). Hidden until `:can_publish_prototype?` (set by
      # `assign_active_space/2`) says the install and this space's org admit
      # the viewer; see `PrototypeUpload`.
      |> PrototypeUpload.allow()

    # Pin-to-Chat stage 4: pinned task-exec spaces ride the same PubSub
    # subscribe loop as channels + DMs so unread counts + `:new_message`
    # broadcasts stay live on the pinned rail rows.
    #
    # CAUTION: `ChatPubSub.subscribe/1` is NOT idempotent per pid. The
    # `Phoenix.PubSub` registry is started with `keys: :duplicate`
    # (deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex) and `subscribe/3`
    # is a bare `Registry.register/3`
    # (deps/phoenix_pubsub/lib/phoenix/pubsub.ex), so a second subscribe from
    # the same pid to the same topic adds a SECOND registration and every
    # broadcast on it is delivered twice.
    #
    # The list below concatenates three independently-sourced sets, so the
    # same space id CAN appear twice (e.g. a pinned exec space that is also
    # listed as a channel). Task 01a017a3 closed that and task 01a01a1b widened
    # the guarantee past this module: the loop runs through `subscribe_space/3`,
    # which is `PlatformWeb.SpaceTopics.hold/3`, and that subscribes only when
    # NOBODY on this pid already holds the topic. A repeated id — or an id
    # ShellLive's roster/presence hooks already hold, which is the common case
    # since those hooks run in this same process — takes exactly one
    # registration between them. Do not reach past that helper for a bare
    # `ChatPubSub.subscribe/1` here or anywhere else in this module.
    all_spaces = channels ++ pinned_task_spaces ++ dm_conversations

    # Subscribe to chat pubsub for unread counts in background conversations
    # (active space subscription happens in handle_params).
    # Also subscribe to the global space-lifecycle topic so newly created
    # channels appear in the sidebar without requiring a refresh.
    # In embedded mode we skip both: the embed only renders ONE space and
    # has no sidebar to keep in sync, so the cross-space subscriptions
    # would just be noise.
    socket =
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
        socket =
          all_spaces
          |> presence_subscribe_space_ids(user_id, socket.assigns[:access_scope])
          |> Enum.reduce(socket, &subscribe_space(&2, &1, :chat_rail))

        ChatPubSub.subscribe_spaces()
        # Per-user sidebar-invalidation topic (Stage 4): a `:sidebar_changed`
        # broadcast (Stage 5 personal arrangement writes) triggers a resolver
        # recompute for this user's OTHER tabs. Task 01a017a3 also hangs the
        # subscribe-set reconcile off this topic, so a channel granted after
        # mount picks up its subscription without a reload.
        ChatPubSub.subscribe_sidebar(user_id)
        # Shared org-default topic (Stage 6): a `:sidebar_defaults_changed`
        # broadcast from a root-admin curation write (rename / recolor / reorder
        # / reassign) triggers a resolver recompute in EVERY connected session,
        # so an admin's default change is visible to all users live.
        ChatPubSub.subscribe_sidebar_defaults()
        # Role assignments (task 01a0b491 stage 4). The agents surface resolves
        # its leader through `role_assignments`, which is the pin that
        # broadcasts; subscribing here is what lets a leader swap repaint the
        # rail avatar AND the header avatar with no reload. Subscribed
        # unconditionally rather than behind the feature flag: the flag is read
        # at render time from application env, so a subscription taken while it
        # was off would otherwise have to be established retroactively when it
        # was turned on. The handler is a no-op for every role_key but ours.
        Platform.Roles.subscribe_assignments()
        socket
      else
        socket
      end

    space_ids = Enum.map(all_spaces, & &1.id)

    socket =
      socket
      |> PresenceHooks.attach()
      |> MessagesHooks.attach()
      |> PinHooks.attach()
      |> SearchHooks.attach()
      |> MentionsHooks.attach()
      # Before UploadHooks, which halts "upload_dialog_close" (task 01a120be).
      |> LargeUploadHooks.attach()
      |> UploadHooks.attach()
      |> CanvasHooks.attach()
      |> Extensions.attach_live_hooks()
      |> ActiveAgentHooks.attach()
      |> MessageContextHooks.attach()

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

    # EXTERNAL ADMISSION GATE (task 01a011ed), the embedded half. Collapsed into
    # `nil` rather than given its own branch, because here a denial IS the
    # unresolvable case: the pane loads no space and renders nothing, exactly as
    # it already does for a slug that names nothing.
    #
    # Deliberately NOT the standalone deny. This LiveView is `live_render`ed
    # inside MeetingLive, so `push_navigate/2` would move the PARENT surface out
    # of the meeting. Denial here is silent and local to the pane.
    space =
      if space &&
           (external_space_denied?(socket, space) or restricted_space_denied?(socket, space)),
         do: nil,
         else: space

    case space do
      nil ->
        socket

      space ->
        socket =
          if connected?(socket) do
            # Embedded surfaces render exactly ONE space and have no rail, so
            # this is the active-space hold, not a rail hold.
            socket = subscribe_space(socket, space.id, :chat_active)
            Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space.id}")
            socket
          else
            socket
          end

        participant = find_user_participant(space.id, socket.assigns.user_id)
        participants = Chat.list_participants(space.id)

        page_title =
          space_page_title(
            space,
            participants,
            socket.assigns.user_id,
            space_mask(socket.assigns)
          )

        socket
        |> assign(:page_title, page_title)
        |> assign_active_space(space)
        |> assign(:can_unarchive?, can_unarchive?(space, socket.assigns.user_id))
        |> assign(:can_cancel_deletion?, socket.assigns.root_admin?)
        |> assign(:current_participant, participant)
        # Same teardown as the standalone surface's `handle_params/3`. The
        # embed bootstraps once per mount, so today this clears an already-
        # empty MapSet; it is here so both entry points into
        # `PresenceHooks.enter_space/4` reach it with no carried-over message
        # ids, whatever a later change does to the embed's lifecycle.
        |> MessagesHooks.clear_rendered_messages()
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
  def handle_params(%{"space_slug" => slug_or_id} = params, _url, socket) do
    # Save the outgoing channel's draft AND cancel any staged uploads —
    # the upload slots are LV-process-scoped, not per-space, so without
    # an explicit cancel, a file staged in space A remains visible and
    # send-eligible in space B's composer (BACKLOG #10).
    socket =
      if prev = socket.assigns.active_space do
        # Release ONLY the active-space hold. Task 01a011e9 had to
        # unsubscribe-then-conditionally-resubscribe here, because
        # `Phoenix.PubSub.unsubscribe/2` is `Registry.unregister/2` on a
        # `keys: :duplicate` registry and so dropped every entry this pid held
        # for the topic — including the one `mount/3` took to feed the unread
        # badge of a space nobody is looking at. That workaround is gone
        # (task 01a01a1b): `SpaceTopics.release/3` unsubscribes only when the
        # holder set empties, so a rail space keeps its `:chat_rail` hold
        # through the navigation and a space reached only by URL — an execution
        # space, say, which the rail never lists — has nothing left holding it
        # and is unsubscribed. Same two end states as the restore branch
        # produced, with no window in which the registration does not exist.
        socket = unsubscribe_space(socket, prev.id, :chat_active)

        # Deliberately NOT given the same treatment: only the enter path below
        # subscribes `active_agent:`, so removing every entry is the whole of the
        # correct behaviour there.
        Phoenix.PubSub.unsubscribe(Platform.PubSub, "active_agent:#{prev.id}")

        {main_cancelled, socket} = UploadHooks.cancel_all(socket, :attachments)
        {thread_cancelled, socket} = UploadHooks.cancel_all(socket, :thread_attachments)

        # Message bookkeeping keyed by id, with no space in it
        # (`:rendered_message_ids`, `:msg_day_labels`), describes rows that
        # stop being on screen the moment we leave `prev`. Drop it here, in
        # the same teardown as the draft and the presence untrack, so nothing
        # between this point and the new space's loader can re-hydrate the
        # outgoing space's messages into the incoming space's stream
        # (task 01a0119e).
        socket =
          socket
          |> PresenceHooks.leave_space(prev.id)
          |> MessagesHooks.save_draft(prev.id)
          |> MessagesHooks.clear_rendered_messages()

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

    # A `?message=` deep link is by construction a link to something that
    # ALREADY EXISTS, so it must never reach `bootstrap_space/2` — the
    # friendly-slug AUTO-CREATE path. Task 019fabe8 stage 3 hit this for real:
    # an org-less space's slug URL, opened by a reader whose active org is set,
    # misses the org-scoped `get_space_by_slug/2`, misses the uuid branch, and
    # MINTS a second empty channel with that slug in the reader's org — into
    # which the deep link is then refused. Stage 4's `space_path_segment/1`
    # removes the usual way to produce such a url, but a stale row emitted
    # before this shipped, or a hand-edited link, still carries one. Deep links
    # resolve or they fall back; they do not create.
    space =
      Chat.get_space_by_slug(slug_or_id, org_id: active_org_id) ||
        (valid_uuid?(slug_or_id) && Chat.get_space(slug_or_id)) ||
        system_prefix_fallback(slug_or_id) ||
        maybe_bootstrap_space(params, slug_or_id, active_org_id, socket)

    # EXTERNAL ADMISSION GATE (task 01a011ed). Folded into the SAME condition as
    # "did not resolve" on purpose: one branch and one outcome, so an off-limits
    # slug stays indistinguishable from a missing one and the denial is not an
    # existence oracle (the plug documents the same property).
    #
    # Sitting in this condition also puts it ahead of EVERY load in the success
    # branch below — the subscribe, `ensure_participant/2` (which inserts a
    # `chat_participants` row with no authorization check of its own, and is
    # what converts a read bypass into permanent membership), the roster read
    # and the whole assign pipeline. Do not move it below any of them.
    #
    # INTERNAL ADMISSION GATE (task 01a01d0e) joins the same condition, for the
    # same reason. The external gate above is scoped to external sessions BY
    # CONSTRUCTION, so before this an INTERNAL session passed admission for
    # every space row that resolved — and `Chat.get_space/1` is called here
    # with no `:scope`, so every row in the table resolves by id. The result
    # was that `/chat/<uuid>` handed any authenticated internal user a
    # permanent, self-authorizing participant row in another pair's DM.
    # Deliberately a SEPARATE predicate rather than a widening of
    # `external_space_denied?/2`: the two ask different questions of different
    # populations, and collapsing them would put the external allowlist in the
    # internal path.
    restricted? =
      space && not external_space_denied?(socket, space) &&
        restricted_space_denied?(socket, space)

    if is_nil(space) or external_space_denied?(socket, space) or
         implicit_join_denied?(socket, space) or restricted? or
         internal_read_denied?(socket, space) do
      # The URL saved by the RouteResume hook (`route_resume:chat` in
      # localStorage) points at a space this user can no longer resolve
      # (deleted, unauthorized). Signal the client to clear the entry so the
      # next Chat-tile click falls back to `/chat` rather than looping right
      # back into this dead resolve. See PlatformWeb.RouteResume.
      socket =
        if restricted?, do: put_flash(socket, :error, "Restricted, ask an admin"), else: socket

      {:noreply,
       socket
       |> handle_route_stale("chat")
       |> push_navigate(to: ~p"/chat")}
    else
      socket =
        if connected?(socket) do
          # Mount's subscribe loop (see `mount/3`) has usually already taken a
          # `:chat_rail` hold on whichever space is about to become active, and
          # ShellLive's hooks may hold it too. Phoenix.PubSub does NOT dedupe
          # subscriptions per pid, so this used to unsubscribe first to
          # normalise down to a single registration. It no longer has to: a
          # second HOLD by a different owner registers nothing new, and taking
          # the active hold as its own entry is what lets the teardown above
          # drop it without touching the rail's (task 01a01a1b).
          socket = subscribe_space(socket, space.id, :chat_active)
          Phoenix.PubSub.subscribe(Platform.PubSub, "active_agent:#{space.id}")
          socket
        else
          socket
        end

      participant = ensure_participant(space.id, socket.assigns.user_id)
      participants = Chat.list_participants(space.id)

      page_title =
        space_page_title(
          space,
          participants,
          socket.assigns.user_id,
          space_mask(socket.assigns)
        )

      # Refresh sidebar lists. rbac-external-users M5: re-thread the same
      # `@external_scope` the mount used so a channel-to-channel nav re-derives
      # the SAME filtered rail rather than re-broadening it workspace-wide.
      # Internal / nil scope is pass-through, so the internal path is unchanged.
      scope = socket.assigns[:access_scope] || socket.assigns.external_scope
      readable_channels = rail_channels(socket)

      listed_channels =
        Chat.list_spaces(
          kind: "channel",
          scope: channel_listing_scope(socket.assigns.external?, socket.assigns.user_id)
        )
        |> PlatformWeb.ChatLive.ReadScope.within_org_fence(socket.assigns[:access_scope])

      archived_channels = rail_archived_channels(socket)

      restricted_channel_ids =
        restricted_channel_ids(socket, readable_channels ++ listed_channels, archived_channels)

      channels =
        include_restricted_channels(readable_channels, listed_channels, restricted_channel_ids)

      dm_convos = rail_dm_conversations(socket)

      # `?message=<id>` deep link (task 019fabe8 stage 2). `Platform.Chat`
      # has always written this param into the inbox url and `InboxLive`
      # push_navigates to it verbatim; until now `handle_params/3` read
      # only `"space_slug"` and dropped the identity, so a mention click
      # landed at the channel's default position. Resolve it BEFORE the
      # pipeline so the message-window loader can be chosen up front.
      anchor = resolve_deep_link_anchor(params, space, scope)

      # The second way a closed DM comes back (task 019ffc5f). Entering the
      # conversation reverses the close outright, ahead of the recompute
      # below so this render already shows the row.
      #
      # This is what makes "I start a new DM with that person" work:
      # `Chat.find_or_create_dm/4` returns the SAME space for an existing
      # pair, so a "new" DM lands on the closed space id and would otherwise
      # open a conversation whose row is missing from the rail.
      closed_dm_at = maybe_reopen_dm(socket, space)

      {:noreply,
       socket
       |> assign(:page_title, page_title)
       |> assign_active_space(space)
       |> assign(:can_unarchive?, can_unarchive?(space, socket.assigns.user_id))
       |> assign(:can_cancel_deletion?, socket.assigns.root_admin?)
       |> assign(:current_participant, participant)
       # Reconnect-aware meeting restore (task 019e4b3e stage 2): after a
       # transient LV socket drop, if the user still has an active live
       # participant row here, re-assign :in_meeting + re-push join-meeting
       # so the LiveKit session (kept alive in stage 1) is rejoined. No-op
       # on a fresh first mount — that still needs the explicit Join button.
       |> MeetingHooks.maybe_restore_on_reconnect(space)
       |> PresenceHooks.enter_space(space, participant, participants)
       |> enter_space_window(anchor, space, participant)
       |> SearchHooks.reset_for_space()
       |> MentionsHooks.reset_for_space()
       |> PinHooks.load_for_space(space.id)
       |> CanvasHooks.load_for_space(space.id)
       |> ActiveAgentHooks.resolve_for_space(space.id, participants)
       |> assign(:mobile_browser_open, false)
       |> assign(:channels, channels)
       |> assign(:archived_channels, archived_channels)
       |> assign(:restricted_channel_ids, restricted_channel_ids)
       |> assign(:dm_conversations, dm_convos)
       |> assign(:spaces, channels ++ dm_convos)
       |> assign(:closed_dm_at, closed_dm_at)
       |> assign(
         :channel_sections,
         channel_sections(
           channels,
           dm_convos,
           socket.assigns.pinned_space_ids,
           socket.assigns.hidden_channel_ids,
           closed_dm_at
         )
       )
       |> assign(
         :sidebar_sections,
         resolve_sidebar_sections(
           socket.assigns.user_id,
           channels,
           socket.assigns.hidden_channel_ids,
           socket.assigns.agents_block
         )
       )
       |> clear_unread(space.id)
       # AFTER `SearchHooks.reset_for_space/1`, which clears
       # `:highlighted_message_id` — setting the arrival highlight any
       # earlier in this pipeline would be wiped a line later.
       |> apply_anchor_arrival(anchor)}
    end
  end

  def handle_params(_params, _url, socket) do
    restricted_ids =
      restricted_channel_ids(socket, socket.assigns.channels, socket.assigns.archived_channels)

    socket = assign(socket, :restricted_channel_ids, restricted_ids)

    # A denied deep link navigates here with this flash. Keep /chat as its
    # landing URL instead of immediately selecting an unrelated channel.
    if Phoenix.Flash.get(socket.assigns.flash, :error) == "Restricted, ask an admin" do
      {:noreply, socket}
    else
      default_chat_landing(socket, restricted_ids)
    end
  end

  defp default_chat_landing(socket, restricted_ids) do
    case Enum.reject(socket.assigns.channels, &MapSet.member?(restricted_ids, &1.id)) do
      [first | _] ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{space_nav_target(first)}")}

      [] ->
        {:noreply, socket}
    end
  end

  # ── `?message=<id>` deep link (task 019fabe8 stage 2) ──────────────────
  #
  # Classify the requested anchor once, so both the window loader and the
  # arrival marker below read the same decision:
  #
  #   * `:none`               — no `?message=` at all. Ordinary entry,
  #                             and crucially NO flash: silence is only
  #                             correct when nothing was asked for.
  #   * `{:top_level, msg}`   — anchorable in the main message list.
  #   * `{:thread, msg}`      — a thread reply. The main window is
  #                             `top_level_only`, so it structurally
  #                             cannot hold this; take the thread branch.
  #   * `:miss`               — asked for, not deliverable.
  #
  # `MessagesHooks.enter_space_anchored/4` re-validates the anchor itself
  # and silently falls back, which makes it safe standalone — but it
  # cannot distinguish "no anchor requested" from "anchor refused", and
  # the difference is exactly what the reader needs to be told. Hence the
  # separate pass here.
  #
  # Guards, all load-bearing:
  #   * `Chat.get_message/2` validates the uuid and applies the
  #     external-scope space gate, but does NOT filter `deleted_at` (see
  #     chat.ex) — so check it explicitly. The template refuses to render
  #     deleted rows, so an unchecked deleted anchor scrolls to nothing.
  #   * `msg.space_id == space.id` — a hand-edited `?message=` pointing
  #     into another space must neither anchor nor leak.
  defp resolve_deep_link_anchor(%{"message" => message_id}, space, scope)
       when is_binary(message_id) do
    with %Chat.Message{} = msg <- Chat.get_message(message_id, scope: scope),
         true <- msg.space_id == space.id,
         true <- is_nil(msg.deleted_at) do
      case MessagesHooks.resolve_anchor(msg) do
        {:top_level, _id} -> {:top_level, msg}
        {:thread, _thread_id} -> {:thread, msg}
        :none -> :miss
      end
    else
      _ -> :miss
    end
  end

  defp resolve_deep_link_anchor(_params, _space, _scope), do: :none

  # Only a top-level anchor changes which messages are loaded. A thread
  # reply is reached by expanding its parent inside the ordinary window,
  # and a miss deliberately lands at the channel's normal position.
  defp enter_space_window(socket, {:top_level, msg}, space, participant),
    do: MessagesHooks.enter_space_anchored(socket, space, participant, msg.id)

  defp enter_space_window(socket, _anchor, space, participant),
    do: MessagesHooks.enter_space(socket, space, participant)

  # Arrival marker. Three layers, none permanent: the client-side 1.5s
  # `.chat-message-pulse` (applied by chat_scroll_to_message.js) says
  # "here", `:highlighted_message_id` holds the ring while the reader
  # orients, and a server-side timer clears it.
  defp apply_anchor_arrival(socket, {:top_level, msg}), do: mark_arrival(socket, msg.id)

  defp apply_anchor_arrival(socket, {:thread, msg}) do
    # Mirrors `handle_event("search_open_result", …)` rather than adding a
    # second thread-jump implementation: expand the parent's inline
    # thread and mark the PARENT, since the reply has no row of its own
    # in the main list. Falls back to marking the reply id when the
    # parent is outside the loaded window — same degradation search has.
    parent_msg_id =
      Enum.find_value(socket.assigns.thread_previews, fn {pmid, %{thread_id: tid}} ->
        if tid == msg.thread_id, do: pmid
      end)

    thread_msgs = MessagesHooks.load_thread_messages(msg.space_id, msg.thread_id)

    if parent_msg_id do
      socket
      |> MessagesHooks.open_thread_context(parent_msg_id, thread_msgs)
      |> mark_arrival(parent_msg_id)
    else
      mark_arrival(socket, msg.id)
    end
  end

  defp apply_anchor_arrival(socket, :miss) do
    # Land in the channel with an explicit note rather than scrolling to
    # nothing. Plain text — no emoji.
    socket
    |> assign(:anchor_message_id, nil)
    |> put_flash(:info, "That message is no longer available.")
  end

  defp apply_anchor_arrival(socket, :none), do: assign(socket, :anchor_message_id, nil)

  defp mark_arrival(socket, message_id) do
    # The timer is scheduled unconditionally (a dead render's process is
    # short-lived and never receives it) but the push is connected-only —
    # there is no client to receive an event during the static render.
    Process.send_after(self(), {:clear_anchor_highlight, message_id}, anchor_highlight_ms())

    socket =
      socket
      |> assign(:anchor_message_id, message_id)
      # `reinsert: false` — `enter_space_window/4` reset the messages
      # stream earlier in THIS pipeline, so every row re-renders with the
      # ring already applied. A reinsert in the same diff defaults to
      # `at: -1` and would re-append the anchor row to the end of the
      # container, so the reader would arrive at the right message
      # surrounded by the wrong conversation (task 019fabe8 stage 3).
      |> SearchHooks.set_highlights(message_id, reinsert: false)

    if connected?(socket) do
      push_event(socket, "chat:scroll-to-message", %{id: message_id})
    else
      socket
    end
  end

  defp anchor_highlight_ms do
    Application.get_env(:platform, :anchor_highlight_ms, @anchor_highlight_ms)
  end

  @impl true
  # Stage 2 (search-forward entry): the opener can declare a search intent
  # (phx-value-intent="search" on the pills-strip magnifying glass — whose
  # aria-label has always promised "Search channels and DMs"). The intent
  # rides to the drawer's input as a data attribute; the DrawerSearchFocus
  # hook focuses the field client-side on mount. Openers WITHOUT the intent
  # get a plain browse drawer — no focus, no keyboard.
  # ── Agents goal editing (task 01a0b491 stage 4) ───────────────────────────
  #
  # ONE WRITE, NOT TWO. There is no insert-vs-update split and no "set goal"
  # event distinct from an "edit goal" event: `save_goal` always runs
  # `Chat.update_space/2` through the stage-1 changeset. The blank-goal clause
  # below is an install-level SCOPE gate (task 01a0ca99), not a second write
  # path: a first goal is refused unless `Sidebar.first_goal_offered?/1` holds.
  def handle_event("edit_goal", _params, socket) do
    %{can_edit_goal?: editable?, active_space: space} = socket.assigns
    options = if editable?, do: Sidebar.goal_scope_options(space), else: []

    cadence_form =
      if editable?,
        do: GoalCadenceForm.open(socket.assigns.goal_panel, socket.assigns.goal_time_zone)

    {:noreply,
     assign(socket,
       goal_edit: editable?,
       goal_scope_error: nil,
       goal_scope_options: options,
       goal_cadence_form: cadence_form
     )}
  end

  def handle_event("cancel_goal_edit", _params, socket) do
    {:noreply, assign(socket, goal_edit: false, goal_cadence_form: nil)}
  end

  # Preview only: re-assigns the Check progress selection so the "at"
  # select and the "Next check" line follow the admin's pick. NEVER writes;
  # `save_goal` is the only write.
  def handle_event("goal_form_change", params, socket) do
    case socket.assigns.goal_cadence_form do
      nil ->
        {:noreply, socket}

      current ->
        {:noreply, assign(socket, :goal_cadence_form, GoalCadenceForm.change(current, params))}
    end
  end

  def handle_event("save_goal", %{"goal" => goal} = params, socket) do
    space = socket.assigns.active_space

    cond do
      not socket.assigns.can_edit_goal? ->
        # The pencil is an affordance; THIS is the gate.
        {:noreply, put_flash(socket, :error, "You cannot edit this goal.")}

      is_nil(space) ->
        {:noreply, socket}

      # `update_space/2` broadcasts nothing, so a stale invitation can still
      # submit; refusing here keeps it from minting a second agents space.
      space.goal in [nil, ""] and not Sidebar.first_goal_offered?(space) ->
        {:noreply, put_flash(socket, :error, "A first goal cannot be set on this channel.")}

      true ->
        # No `goal_project_id` key (an old client) keeps the CURRENT scope:
        # the stored value passes through `put_goal_scope/2` as unchanged.
        scope = Map.get(params, "goal_project_id", (space.metadata || %{})["goal_project_id"])

        case Sidebar.save_goal(space, goal, scope) do
          {:error, :unknown_project} ->
            {:noreply, assign(socket, :goal_scope_error, :unknown_project)}

          {:ok, updated} ->
            # The cadence rides the same Save (task 01a0e882 stage 3). The
            # context re-checks admin and audits; an old client that sends
            # no `goal_cadence` changes nothing.
            socket = maybe_save_goal_cadence(socket, params)

            # RE-DERIVE, never carry forward. `goal_panel/1` recomputes the
            # measurement from the SAVED goal, so a goal that can no longer
            # name a number shows the no-measurement state immediately rather
            # than the previous goal's numeral. A stale number that looks live
            # is the failure this whole feature was designed against, so there
            # is no cached measurement for it to fall back to.
            {:noreply,
             socket
             |> assign_active_space(updated)
             |> assign_agents_block(Sidebar.agents_rail_block())}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not save that goal.")}
        end
    end
  end

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
         socket.assigns.pinned_space_ids,
         hidden,
         socket.assigns.closed_dm_at
       )
     )
     |> assign(
       :sidebar_sections,
       resolve_sidebar_sections(
         user_id,
         socket.assigns.channels,
         hidden,
         socket.assigns.agents_block
       )
     )
     # Hide is the only action that raises this toast. Stage 2 of task
     # 019ffc5f added a `:kind` so DM Close could share it; Marlowe rejected
     # that acknowledgement at the stage-3 gate, so the map is back to the
     # two fields the one remaining verb needs.
     |> assign(:undo_toast, channel_name && %{space_id: space_id, name: channel_name})
     # Dismiss the mobile row-actions sheet if the hide came from there (task
     # 019fe998). Mandatory rather than cosmetic: the hidden row is gone from
     # the rail, so a sheet left open would name a conversation that is no
     # longer on screen and still offer to act on it.
     |> assign(:row_actions_space_id, nil)}
  end

  # ── The DM Close action (task 019ffc5f stage 2) ────────────────────────
  #
  # Close takes ONE DM row off the rail and nothing else. It is not Hide:
  # `hide_channel` writes `hidden_channel_ids` and is reversed by a drawer
  # that lists channels, whereas a closed DM comes back by itself on the next
  # message in it (`Platform.Chat.ClosedDms.filter/2`) or the moment the user
  # opens it (`maybe_reopen_dm/2` in `handle_params/3`). Those two returns are
  # why there is no closed-DM drawer to build or maintain.
  #
  # The id is resolved against `@dm_conversations` and the handler no-ops when
  # it matches nothing. Close has no meaning for a channel, and a stale click
  # racing a rail refresh should do nothing rather than write a channel id
  # into the closed map where the DM filter would never look at it again.
  def handle_event("close_dm", %{"id" => space_id}, socket) when is_binary(space_id) do
    case Enum.find(socket.assigns.dm_conversations, &(&1.id == space_id)) do
      nil -> {:noreply, socket}
      space -> {:noreply, do_close_dm(socket, space)}
    end
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

  # Scope filter (chat plan v2 Stage 4). Clicking a scope-pill in the
  # sectioned rail (or the chat-header pill) narrows the visible sub-org
  # sections to just that scope. Clicking the same scope again clears the
  # filter (toggle semantics). Payload `scope` is the atom name as a
  # string (e.g. "sxi", "wayne_tech"). Unknown values clear the filter.
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
  # root-org admins) admin-edit, so the ~260px rail header only ever hosts one
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

  # "Mark all as read" (sidebar header menu, task
  # `01a02491-a407-794f-a13e-d18398e4b092` stage 3). Clears exactly the set the
  # left rail's Chat badge counts, through the one query that defines that set.
  # See `Chat.mark_all_chat_spaces_read/1` for why the badge and the dismiss
  # must not own separate membership queries.
  #
  # The viewer comes from `@current_user_record` (seeded by
  # `PlatformWeb.ShellLive`'s on_mount), never from the client payload: that
  # struct carries the tenancy visibility the clearing query fences on.
  def handle_event("mark_all_read", _params, socket) do
    {:ok, _advanced} = Chat.mark_all_chat_spaces_read(socket.assigns[:current_user_record])

    user_id = socket.assigns[:user_id]

    {:noreply,
     socket
     |> assign(:sidebar_menu_open, false)
     # The per-channel pills read the WIDE unread map, so recompute it rather
     # than emptying it: a pinned task conversation renders a pill the rail
     # badge deliberately does not count, and this action does not clear it.
     |> assign(:unread_counts, if(user_id, do: Chat.unread_counts_for_user(user_id), else: %{}))
     # The rail badge is ShellLive's assign in THIS process (it mounts as a
     # hook on the same socket). Queue its recompute so the number the reader
     # just dismissed goes away without a navigation.
     |> ShellLive.queue_chat_unread_refresh()}
  end

  # ── root-admin "Edit default" mode (chat sidebar Stage 6) ──────────────
  #
  # A SEPARATE mode from the personal "Edit layout" above. Visible ONLY to
  # root-org admins and routes gestures to the GLOBAL org default (Sidebar Stage 2
  # API), not the acting user's prefs. Every write re-checks authorization
  # SERVER-SIDE by going through `Sidebar.*`, which gates on
  # `Tenancy.root_admin?/1` — the toggle + controls are an affordance, never
  # the gate. A forged event from a non-admin client returns
  # `{:error, :unauthorized}` and we no-op (with a flash). On success we
  # recompute the acting admin's own `@sidebar_sections` and broadcast
  # `:sidebar_defaults_changed` so every OTHER connected session refreshes.

  # Flip the rail between normal and admin-edit (curate org default) mode.
  # Entering admin-edit always exits personal-edit (mutual exclusivity). We
  # re-check `@root_admin?` here too so a forged toggle from a non-admin
  # client can't even open the mode (the per-gesture Sidebar gate is the real
  # backstop, but refusing to flip the assign keeps the UI honest).
  def handle_event("toggle_sidebar_admin_edit", _params, socket) do
    if socket.assigns.root_admin? do
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

  # Set or clear an org-default section's sidebar label (admin-edit). A blank
  # name CLEARS the label so the header follows the org again (task 01a08212);
  # the "Use organisation name" reset sends exactly that.
  def handle_event("rename_section_default", %{"section_id" => section_id} = params, socket)
      when is_binary(section_id) do
    name = String.trim(params["name"] || "")

    case Sidebar.rename_section(%{id: socket.assigns.user_id}, section_id, name) do
      {:ok, _section} ->
        {:noreply, recompute_sidebar_after_admin_write(socket)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not rename the section.")}
    end
  end

  # Recolor an org-default section (admin-edit). `color` is one of the five
  # sibling scope tokens (soylent / wayne-tech / sxi / paragon / cyberdyne) or
  # the section's OWN org token — the compact palette in the section header.
  def handle_event(
        "recolor_section_default",
        %{"section_id" => section_id, "color" => color},
        socket
      )
      when is_binary(section_id) and is_binary(color) do
    if valid_scope_token?(color, section_id, socket.assigns[:sidebar_sections] || []) do
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

  # ── Explicit "Move to organisation…" (task 019fd76a stage 1) ────────────
  #
  # This replaced a `channel_reassigned` event that the admin-edit channel
  # drag used to push: a drop resolved the target section's org and wrote
  # `chat_spaces.org_id` for everyone, with no confirmation. Both the gesture
  # and that handler were deleted in stage 2. There is no longer ANY event
  # that refiles a channel across orgs without passing through the two steps
  # below, which is the point of the pair.
  #
  # Refiling a channel is a company-wide act with a consequence that is not
  # visible in the gesture: `CanvasAccess.org_readable_space?/2` grants read
  # on this channel's canvases to any member of the owning org, with no
  # channel membership required, so a move hands the destination org's
  # members a direct link they did not have and takes it away from the
  # source org's. That is not something to do on a drop, which is why the
  # drag path is being retired in favour of these three events.
  #
  # TWO STEPS, and the split is the security property. Step 1 resolves
  # display data and WRITES NOTHING. Step 2 carries no ids at all: it reads
  # the channel and the destination org back out of `@reassign_confirm`, so
  # the most a forged confirm can do is confirm the move THIS session has
  # already requested and rendered. It cannot re-point an approved move at a
  # different channel or a different destination.

  # Step 1 — open the confirmation. `@root_admin?` is re-checked here (the
  # control is an affordance, never the gate) so a non-admin's forged request
  # assigns nothing and therefore has nothing to confirm.
  def handle_event(
        "request_channel_reassign",
        %{"channel_id" => channel_id, "target_section_id" => section_id},
        socket
      )
      when is_binary(channel_id) and is_binary(section_id) do
    with true <- socket.assigns.root_admin?,
         %{} = destination <- section_summary(socket.assigns.sidebar_sections, section_id),
         %Chat.Space{kind: "channel"} = channel <- Chat.get_space(channel_id),
         # The SOURCE org is the channel's own `org_id`, read from the ORG
         # RECORD rather than matched against `@sidebar_sections`. Three real
         # states break the section lookup and none of them should block a
         # legitimate move: an unfiled channel falls back to the lowest-position
         # section (`Sidebar.default_section_id/3`), a section the acting admin
         # has hidden is absent from the resolver's output, and an ARCHIVED
         # org's section is dropped by `list_active_default_sections/0`. The
         # dialog's canvas-access line is a claim about `org_id`, so `org_id`
         # is what names it.
         %Platform.Tenancy.Org{} = source_org <- Platform.Tenancy.get_org(channel.org_id),
         # A move to where it already is has no confirmation to write. The
         # popover excludes the current section; this catches a forged one.
         false <- destination.org_id == channel.org_id do
      # Label the source the way the RAIL labels it, so the sentence echoes
      # the words the admin just read: the destination half of it is the
      # section name they clicked in the popover, and an admin can rename a
      # section away from its org's name. The org record is the fallback for
      # exactly the three states above, where there is no section to read.
      source = %{name: source_section_name(socket.assigns.sidebar_sections, source_org)}

      {:noreply,
       socket
       # Picking a destination closes the chooser it was picked from — the
       # confirmation is the next step, not a second layer on top of it.
       |> assign(:reassign_picker, nil)
       |> assign(:reassign_confirm, %{
         channel_id: channel.id,
         channel_name: channel.name,
         from: source,
         to: destination
       })}
    else
      _ -> {:noreply, socket}
    end
  end

  # Step 2 — perform the move. Takes NO parameters from the client on
  # purpose; see the block comment above.
  def handle_event("confirm_channel_reassign", _params, socket) do
    case socket.assigns.reassign_confirm do
      # `destination` and `confirm` are bound alongside the fields rather than
      # destructuring `section_id` / `channel_name` into the head: the head
      # decides whether the MOVE happens, and those two are only needed for the
      # rail-expansion and the confirmation line below it. Adding either to the
      # pattern would mean an assign shape missing one presentation field
      # silently cancels the write instead of merely skipping the cosmetic half.
      %{channel_id: channel_id, to: %{org_id: org_id, name: to_name} = destination} = confirm ->
        socket = assign(socket, :reassign_confirm, nil)

        # The destination is re-checked for archival here, not just when the
        # dialog opened. `Chat.assign_space_org/2` has no such guard, and a
        # channel filed to an archived org loses its section for EVERY user
        # (`list_active_default_sections/0` drops it) and lands in the
        # fallback one. The popover never offers an archived org, so this
        # only closes the window between opening the dialog and confirming.
        if org_archived?(org_id) do
          {:noreply,
           put_flash(socket, :error, "#{to_name} was archived. The channel was not moved.")}
        else
          case Sidebar.reassign_channel(%{id: socket.assigns.user_id}, channel_id, org_id) do
            {:ok, _space} ->
              {:noreply,
               socket
               |> expand_destination_section(destination[:section_id])
               |> recompute_sidebar_after_admin_write()
               |> raise_move_toast(channel_id, confirm[:channel_name], to_name)}

            {:error, :unauthorized} ->
              {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, reassign_error_message(reason, to_name))}
          end
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_channel_reassign", _params, socket) do
    {:noreply, assign(socket, :reassign_confirm, nil)}
  end

  # Open / close the destination chooser for one row. One at a time, and it
  # resolves its own list server-side so the picker markup carries no
  # authority: `request_channel_reassign` re-derives everything anyway.
  #
  # The chooser is a CENTRED dialog, not a popover hanging off the row. A
  # row-anchored popover was built first and measured: `#chat-section-list`
  # is `overflow-y-auto`, which computes `overflow-x` to `auto` as well, so
  # it clips on both axes. On the lower rows the destination list fell
  # entirely below the scroller's bottom edge (popover bottom 992px against a
  # nav bottom of 810px) and none of the destinations were reachable, and on
  # the sub-org rows the box ran about 9px past the rail's left edge, cutting
  # into the leading colour dots. The rail is only ~224px wide, so there is
  # no width at which a row-anchored list both fits and stays legible.
  def handle_event("toggle_reassign_menu", %{"channel_id" => channel_id}, socket)
      when is_binary(channel_id) do
    already_open? =
      match?(%{channel_id: ^channel_id}, socket.assigns.reassign_picker)

    with false <- already_open?,
         true <- socket.assigns.root_admin?,
         %Chat.Space{} = channel <- Chat.get_space(channel_id),
         true <- movable_channel?(channel) do
      {:noreply,
       assign(socket, :reassign_picker, %{
         channel_id: channel.id,
         channel_name: channel.name,
         destinations: reassign_destinations(socket.assigns.sidebar_sections, channel.org_id)
       })}
    else
      _ -> {:noreply, assign(socket, :reassign_picker, nil)}
    end
  end

  def handle_event("close_reassign_menu", _params, socket) do
    {:noreply, assign(socket, :reassign_picker, nil)}
  end

  # ── Container lifecycle (task 019f4eaa stage 6) ───────────────────────
  # root-admin-only archive / schedule-deletion on the org section headers.
  # The controls only render behind `@root_admin?` and only for tenant orgs
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

  # Channel row drag-drop — a WITHIN-SECTION reorder, and nothing else (task
  # 019fd76a stage 2). The hook emits the section's resulting channel-id
  # order and `Sidebar.put_channel_order/3` records it.
  #
  # THIS IS THE GATE, not the hook. `put_channel_order/3` writes whatever ids
  # it is handed into `section_id` and strips them from every other section,
  # so an unguarded `channel_moved` is a complete cross-org filing primitive
  # for any client that can send an event. Refiling a channel is a
  # company-wide act (it re-points `CanvasAccess.org_readable_space?/2` at
  # the destination org) and belongs to `request_channel_reassign` /
  # `confirm_channel_reassign` alone.
  #
  # So both halves of the payload are checked against the render state, and
  # the second half is the one that is easy to miss: guarding `channel_id`
  # while trusting `ordered_ids` leaves the hole wide open, because the
  # ordered list is itself a placement instruction. A channel absent from
  # `@sidebar_sections` (pinned, or hidden) has no current section and so
  # cannot be dragged anywhere — matching the rail, where those rows render
  # outside the drag hook's element and carry no handle.
  def handle_event(
        "channel_moved",
        %{"channel_id" => channel_id, "target_section_id" => section_id, "ordered_ids" => ids},
        socket
      )
      when is_binary(channel_id) and is_binary(section_id) and is_list(ids) do
    current_ids = section_channel_ids(socket.assigns.sidebar_sections, section_id)

    if channel_id in current_ids do
      # Keep only ids that already live in this section. A legitimate drop
      # sends exactly those (it is read off the section's own rows), so this
      # is a no-op for the real gesture and a hard stop for a forged one.
      retained = Enum.filter(ids, &(&1 in current_ids))

      {:noreply,
       socket
       |> apply_channel_move(section_id, retained)
       |> announce_channel_move(channel_id, nil)}
    else
      {:noreply, socket}
    end
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

  # Collapse or expand a section in the user's view. Like `toggle_section_hidden`
  # above, `collapsed` arrives as the DESIRED next state so a render race can't
  # flip it twice. Unlike hide, the section stays in the rail: the resolver only
  # stamps `collapsed?` on it, and the template decides whether to draw the rows.
  # Broadcast so the user's other tabs converge on the same fold state.
  def handle_event("toggle_section_collapsed", %{"section_id" => section_id} = params, socket)
      when is_binary(section_id) do
    collapsed? = truthy?(params["collapsed"])
    _ = Sidebar.set_section_collapsed(socket.assigns.user_id, section_id, collapsed?)
    ChatPubSub.broadcast_sidebar_changed_from(socket.assigns.user_id, self())
    {:noreply, recompute_sidebar(socket)}
  end

  # Screen-share name masking (task 01a00c66).
  #
  # `masked` arrives as the DESIRED next state ("true"/"false") rather than as a
  # flip, matching `toggle_section_collapsed` above: a duplicated event from a
  # client-side render race is then idempotent instead of landing in the
  # opposite mode from the one the button showed.
  #
  # Turning the mode OFF also clears the per-section reveals, so re-enabling
  # starts fully masked. Otherwise a reveal from earlier in the session is
  # resurrected on the next share and one org is silently visible — the feature
  # failing in the exact direction it exists to prevent.
  #
  # Pure view state: no write, no broadcast.
  def handle_event("toggle_mask_names", params, socket) do
    masked? = truthy?(params["masked"])

    {:noreply,
     socket
     |> assign(:mask_names?, masked?)
     |> assign(
       :revealed_section_ids,
       if(masked?, do: socket.assigns.revealed_section_ids, else: MapSet.new())
     )
     |> refresh_page_title()}
  end

  # Reveal exactly one section's real name while the mode stays on — the
  # "walk this client through their own channel" case. One click, no menu.
  def handle_event("reveal_section", %{"section_id" => section_id}, socket)
      when is_binary(section_id) do
    {:noreply,
     socket
     |> assign(
       :revealed_section_ids,
       MapSet.put(socket.assigns.revealed_section_ids, section_id)
     )
     |> refresh_page_title()}
  end

  # Re-mask everything in one action, leaving the mode on.
  def handle_event("remask_all", _params, socket) do
    {:noreply,
     socket
     |> assign(:revealed_section_ids, MapSet.new())
     |> refresh_page_title()}
  end

  # Pin or unpin one conversation for this user (task 019fd80f stage 3).
  #
  # `pinned` arrives as the DESIRED next state ("true"/"false") rather than as
  # a flip, so a duplicated event from a client-side render race is idempotent
  # instead of a silent unpin. Same contract as `toggle_section_hidden` above.
  #
  # The param is `space_id`, not `channel_id`: the Pinned block holds channels
  # AND direct messages, and both are `chat_spaces` rows.
  #
  # No confirmation and no toast. The action is reversible by the same control
  # in one click, which is the definition of one that should not ask.
  def handle_event("toggle_pinned", %{"space_id" => space_id} = params, socket)
      when is_binary(space_id) do
    pinned? = truthy?(params["pinned"])
    _ = Sidebar.set_space_pinned(socket.assigns.user_id, space_id, pinned?)
    ChatPubSub.broadcast_sidebar_changed_from(socket.assigns.user_id, self())

    # Dismiss the mobile row-actions sheet if this came from there (task
    # 019fe998). Unconditional because it is already nil on every desktop
    # path, and leaving it open would leave a menu on screen describing a row
    # that has just moved between sections.
    {:noreply, socket |> assign(:row_actions_space_id, nil) |> recompute_pinned()}
  end

  # Reorder within the Pinned block, DRAG path (task 019fe987). Modelled on
  # `section_reordered` below: the client sends the order it just drew, the
  # server owns persistence and re-renders from what it wrote.
  #
  # The param is `space_id`, not `channel_id`: pinned rows carry DM ids too,
  # and a `channel_id` name here would invite a `kind` check that empties the
  # block of people while passing every channel-only test.
  #
  # Pinning stays out of this path. Dragging INTO or OUT OF the block is not
  # a thing the hook can express — the pinned drag scope contains only pinned
  # rows — so a reorder can never change WHAT is pinned, only its order.
  def handle_event(
        "pinned_reordered",
        %{"space_id" => space_id, "ordered_ids" => ordered_ids},
        socket
      )
      when is_binary(space_id) and is_list(ordered_ids) do
    {:noreply, apply_pinned_move(socket, space_id, ordered_ids, nil)}
  end

  # Reorder within the Pinned block, KEYBOARD and screen-reader path (WCAG
  # 2.1.1). Not a touch fallback: drag alone is operable by one kind of user
  # with one kind of input, and this rail already carries a logged defect
  # where a hover-gated control was unreachable without a pointer.
  #
  # Shares every line of persistence with the drag above. The direction is
  # resolved against the RENDERED block (what the user is looking at), then
  # translated to a stored index by `pinned_destination_index/3`.
  def handle_event(
        "move_pinned",
        %{"space_id" => space_id, "direction" => direction},
        socket
      )
      when is_binary(space_id) and direction in ["up", "down"] do
    rendered = rendered_pinned_ids(socket)
    reordered = move_in_list(rendered, space_id, direction)

    if reordered == rendered do
      {:noreply, socket}
    else
      {:noreply, apply_pinned_move(socket, space_id, reordered, direction)}
    end
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
         socket.assigns.hidden_channel_ids,
         socket.assigns.agents_block
       )
     )}
  end

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

  # ── Mobile drawer row actions (task 019fe998) ─────────────────────────────
  #
  # Pin, unpin and hide were all revealed by `group-hover/row:` /
  # `focus-within:`, and Tailwind compiles `hover:` inside
  # `@media (hover: hover)`, so none of the three could fire on a phone. The
  # drawer row's overflow control opens a bottom sheet carrying all three.
  #
  # These two handlers are the ONLY new events, and they carry no business
  # logic: the sheet's actions reuse `toggle_pinned` and `hide_channel`
  # unchanged. Same shape as `open_message_actions` above.
  #
  # Only the id is stored. Name and pinned-ness are re-derived at render, so
  # the header and the Pin/Unpin verb cannot go stale against the row.
  def handle_event("open_row_actions", %{"space_id" => space_id}, socket)
      when is_binary(space_id) do
    {:noreply, assign(socket, :row_actions_space_id, space_id)}
  end

  def handle_event("close_row_actions", _params, socket) do
    {:noreply, assign(socket, :row_actions_space_id, nil)}
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
          |> PlatformWeb.ChatLive.MessagesHooks.try_load_older_messages(space_id)

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

    # Chat.get_message/1 rather than the fully-qualified Platform.Repo.get/2 —
    # `msg_id` is a `phx-value-` param, and the fully-qualified spelling is
    # invisible to `git grep "Repo.get("`, which is how it evaded the sweep.
    with %Platform.Chat.Message{} = msg <- Platform.Chat.get_message(msg_id),
         :ok <- Chat.authorize_author(msg, socket.assigns.current_participant) do
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

  # The five push events ("push_subscribed", "push_permission_state",
  # "push_unsupported", "push_subscribe_failed", "enable_notifications")
  # moved to the `:push_events` attach in `PlatformWeb.ShellLive` in task
  # 019ffb7b stage 3, alongside the `#push-subscribe` anchor. Attached
  # handlers run ahead of a LiveView's own `handle_event/3` and halt, so
  # they now answer on every shell surface instead of only on `/chat`.

  # The banner's dismiss control (task 019ffb7b stage 5) stays HERE rather
  # than joining that attach, because the banner it dismisses is a chat-only
  # component. `enable_notifications` moved because both the banner and the
  # `/inbox` row emit it; nothing outside `/chat` emits this one.
  #
  # Persisted, not session-scoped: `Accounts.dismiss_notification_banner/1`
  # writes `users.preferences["notification_banner_dismissed"]`, the same
  # column and the same `_ =` no-op-on-anonymous shape as `hide_channel`
  # below. The assign flip is what takes the banner down now; the write is
  # what keeps it down on the next mount.
  def handle_event("dismiss_notification_banner", _params, socket) do
    _ = Accounts.dismiss_notification_banner(socket.assigns.user_id)

    {:noreply, assign(socket, :notification_banner_dismissed, true)}
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

  # `handle_event("toggle_watch", ...)` used to live here. Deleted with the
  # header control that called it (task 019f9790 stage 4): the eye is now the
  # agent mutex, and a second, persisted flag that could disagree with it was
  # the whole bug. This was the only writer of `chat_spaces.watch_enabled` in
  # `lib/`; the column stays (no migration) and `AttentionRouter` stops reading
  # it in stage 5.

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
  # Keeps the New canvas form's Blank/Prototype choice and title across
  # re-renders, and is the change event LiveView needs to validate the
  # Prototype drop zone's upload.
  def handle_event("canvas_new_change", params, socket) do
    {:noreply, CanvasHooks.reset_new_form(socket, Map.get(params, "canvas", %{}))}
  end

  def handle_event(
        "canvas_create",
        %{"canvas" => %{"kind" => "prototype"} = canvas_params},
        socket
      ) do
    with true <- socket.assigns.can_publish_prototype?,
         space when not is_nil(space) <- socket.assigns.active_space,
         participant when not is_nil(participant) <- socket.assigns.current_participant do
      title = Map.get(canvas_params, "title")

      with {:ok, published} <-
             PrototypeUpload.publish(socket, space, socket.assigns.user_id, title),
           {:ok, canvas, message} <-
             Chat.create_canvas_with_message(
               space.id,
               participant.id,
               PrototypeUpload.canvas_attrs(published, title)
             ) do
        {:noreply,
         socket
         |> CanvasHooks.put(canvas)
         |> MessagesHooks.stream_insert_message(message)
         |> CanvasHooks.set_active(canvas)
         |> MessagesHooks.reset_thread_panel()
         |> CanvasHooks.show_panel()
         |> CanvasHooks.reset_new_form()
         |> put_flash(:info, PrototypeUpload.success_message(published))}
      else
        {:error, message} when is_binary(message) ->
          {:noreply,
           socket
           |> put_flash(:error, message)
           |> CanvasHooks.reset_new_form(canvas_params)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, put_flash(socket, :error, CanvasHooks.changeset_error_summary(changeset))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create canvas: #{inspect(reason)}")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

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
  # `Chat.unarchive_space/2` (root-org admin or creator) — the banner button is
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
            archived_channels = rail_archived_channels(socket)
            dm_convos = socket.assigns.dm_conversations

            {:noreply,
             socket
             |> assign_active_space(updated)
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
                 socket.assigns.pinned_space_ids,
                 socket.assigns.hidden_channel_ids,
                 socket.assigns.closed_dm_at
               )
             )
             |> assign(
               :sidebar_sections,
               resolve_sidebar_sections(
                 socket.assigns.user_id,
                 channels,
                 socket.assigns.hidden_channel_ids,
                 socket.assigns.agents_block
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
  # stage 4). root-admin only — `Chat.cancel_space_deletion/2` is the gate,
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
             |> assign_active_space(updated)
             |> assign(:can_unarchive?, can_unarchive?(updated, socket.assigns.user_id))
             |> assign(:can_cancel_deletion?, socket.assigns.root_admin?)
             |> assign(:archived_channels, rail_archived_channels(socket))
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
        # `patch`, not `navigate`: the promoted space is served by THIS
        # LiveView, and a remount would drop the screen-share mask state
        # (see the assign comment in `mount/3`).
        {:noreply, push_patch(socket, to: ~p"/chat/#{space_nav_target(updated)}")}

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

        # Dismiss the rail's row-actions menu, which is where this click now
        # comes from (task 019ff8ba, 2026-08-13). Same line `toggle_pinned`
        # carries and for the same reason: the row is about to leave the rail,
        # and a menu describing a row that is gone is a menu with no subject.
        # Unconditional because the assign is already nil on every other path
        # into this handler.
        {:noreply,
         socket
         |> assign(:row_actions_space_id, nil)
         |> put_flash(:info, "Unpinned from Chat.")}
    end
  end

  def handle_event("unpin_task_from_chat", _params, socket), do: {:noreply, socket}

  # ── Settings modal (see SettingsComponent) ────────────────────────────────

  def handle_event("settings_open", _params, socket) do
    {:noreply, assign(socket, :show_settings, true)}
  end

  # ── Members panel (see MembersComponent, task 01a0fd62 stage 3) ───────────
  #
  # Opened from the header "members" button and from the refused-summon
  # notice's "View members". Opening is harmless for anyone: the panel's
  # controls are affordance only and the Chat context re-authorizes writes.
  def handle_event("members_open", _params, socket) do
    {:noreply, assign(socket, :show_members, true)}
  end

  defp confirm_junk_batch_actor_id(socket) do
    case socket.assigns do
      %{current_participant: %{user_id: id}} when is_binary(id) -> id
      %{current_user_record: %{id: id}} when is_binary(id) -> id
      %{current_user: %{id: id}} when is_binary(id) -> id
      _ -> nil
    end
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
        socket.assigns.pinned_space_ids,
        hidden,
        socket.assigns.closed_dm_at
      )
    )
    |> assign(
      :sidebar_sections,
      resolve_sidebar_sections(
        user_id,
        socket.assigns.channels,
        hidden,
        socket.assigns.agents_block
      )
    )
    |> assign(:undo_toast, cleared_toast)
    |> assign(:hidden_drawer_open, drawer_open)
  end

  # Close raises NO acknowledgement. Stage 2 gave it an undo toast and stage 3
  # gave that toast a line explaining the return; Marlowe rejected both at the
  # stage-3 gate: "We don't need a acknowledgement / affirmation for a close
  # action on a DM. A User can simply search for a person or agent to DM again
  # if they want to bring back the window." The row leaves and that is the
  # whole feedback. `@undo_toast` is therefore untouched here — a hide toast
  # raised moments earlier is still true and still has its own timer running,
  # so clearing it would be a second unasked-for behaviour change.
  defp do_close_dm(socket, space) do
    user_id = socket.assigns.user_id

    # Closing a PINNED DM unpins it as well, so the row leaves the rail on the
    # click that closed it (Marlowe, 2026-08-13: "Closing a pinned item doesn't
    # do anything. As soon as I unpin the item (DM), it disappears because I
    # closed it at some point. I expect if I closed a pinned item, it would
    # undo the pin and close the DM.").
    #
    # `channel_sections/5` runs the close filter over the UNPINNED DM
    # remainder only, because the Pinned block is a conversation's one place
    # and nothing filters it. Without the unpin the close was still recorded,
    # the row sat there, and the DM disappeared whenever the user unpinned it
    # later: possibly days later, attached to an action they had no reason to
    # connect to it. One rule everywhere instead. Close means this leaves my
    # list now.
    #
    # THE OLD PIN IS DISCARDED, NOT STASHED. Designer's decision, tradeoff
    # accepted by Marlowe: a DM that comes back (a new message in it, or the user
    # opening it) comes back UNPINNED and is re-pinned in one click. Do not
    # "improve" this by remembering the pin and restoring it on return. That
    # would be a second piece of state the user cannot see, and invisible state
    # is precisely what produced this bug.
    #
    # Written unconditionally rather than under a `pinned?` test, and BEFORE
    # the close. `Sidebar.set_space_pinned/3` takes the DESIRED state, so
    # stating the end state costs one idempotent write on a human-rate click,
    # whereas a membership test against `@pinned_space_ids` can be stale and
    # would fail by silently restoring the old behaviour. Unpin first because
    # if the second write fails the user is left with an unpinned DM still on
    # the rail, which is visible and recoverable; the other order fails back
    # into the bug.
    _ = Sidebar.set_space_pinned(user_id, space.id, false)
    _ = Accounts.close_dm(user_id, space.id)

    # Both halves are user preferences, so the user's OTHER tabs have to
    # converge or they keep rendering a pinned row whose pin no longer exists.
    # `toggle_pinned` already broadcasts for the pin half; a close broadcast
    # nothing, so a second tab kept a closed DM on the rail until its next
    # navigation. `handle_info(:sidebar_changed, ...)` re-reads the close store
    # as well as the pin list, so the receiving tab applies BOTH halves. With
    # only the pin half it would move the row out of Pinned into Direct
    # Messages and leave it sitting there, which is this same bug one tab over.
    ChatPubSub.broadcast_sidebar_changed_from(user_id, self())

    socket
    |> assign(:closed_dm_at, Accounts.get_closed_dm_at(user_id))
    # The menu that issued this is still open on a row that has just left the
    # rail. Same reason `hide_channel` does it: a menu naming a conversation
    # the user can no longer see, still offering to act on it, is worse than
    # the lost context of closing it.
    |> assign(:row_actions_space_id, nil)
    # Rebuilds `@channel_sections` off the pin list as PERSISTED. Rebuilding it
    # here from `@pinned_space_ids` would use the pin this function has just
    # dropped, and the row would stay in the Pinned block until the next
    # navigation.
    |> recompute_pinned()
  end

  # Entering a conversation clears its close, and returns the map the rail
  # should be rebuilt from.
  #
  # Reads the STORE, not `@closed_dm_at`. The assign would be right today, but
  # only because every space change remounts this LiveView and mount reads the
  # store moments earlier. The store is the thing a second tab writes to, and
  # the day a `<.link patch=` lands on a space route this would become a
  # silent lost write: the user opens the DM, reads it, and the close another
  # tab made survives to hide the row again. One preferences read on a DM
  # navigation is not worth that trap.
  #
  # The write is still guarded on the key being present, so an ordinary DM
  # navigation costs one read and no UPDATE.
  #
  # Groups are treated exactly like DMs, because `closeable` offers Close on
  # both. A group whose close could only be undone by someone else posting in
  # it would be the one closed conversation with no way back from the user's
  # own side.
  defp maybe_reopen_dm(socket, %{kind: kind, id: space_id}) when kind in ["dm", "group"] do
    closed_dm_at = Accounts.get_closed_dm_at(socket.assigns.user_id)

    if Map.has_key?(closed_dm_at, space_id) do
      _ = Accounts.reopen_dm(socket.assigns.user_id, space_id)
      Map.delete(closed_dm_at, space_id)
    else
      closed_dm_at
    end
  end

  defp maybe_reopen_dm(socket, _space), do: socket.assigns.closed_dm_at

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

  # ── Pinned-block reorder (task 019fe987) ──────────────────────────────

  # The ▲▼ baseline: the block AS RENDERED, filtered to the rows a
  # conversation may legally move among. Derived from
  # `pinned_conversation_entries/2` rather than read off
  # `@channel_sections.pinned`, so the arrows and the screen can never
  # describe two different lists. See that function for why.
  defp rendered_pinned_ids(socket) do
    socket.assigns.channel_sections.pinned
    |> pinned_conversation_entries(socket.assigns.pinned_task_spaces)
    |> Enum.map(& &1.space.id)
  end

  # Persist, broadcast so the user's other tabs converge, then re-render from
  # what was written. `recompute_pinned/1` re-reads preferences rather than
  # patching the assign, so a write that did not land shows as a block that
  # did not move instead of a rail that disagrees with the database.
  defp apply_pinned_move(socket, space_id, ordered_ids, direction) do
    stored = Sidebar.list_pinned_space_ids(socket.assigns.user_id)

    case pinned_destination_index(stored, space_id, ordered_ids) do
      nil ->
        # Not pinned any more (a second tab unpinned it mid-drag), or a stale
        # payload from a client that has since re-rendered. Ignore silently,
        # the same way the section reorder ignores an unknown id.
        socket

      to_index ->
        _ = Sidebar.move_pinned_space(socket.assigns.user_id, space_id, to_index)
        ChatPubSub.broadcast_sidebar_changed_from(socket.assigns.user_id, self())

        socket
        |> recompute_pinned()
        |> announce_pinned_move(space_id, direction)
    end
  end

  # Translate a RENDERED order into an index in the STORED pin list.
  #
  # The two lists are not the same. `PinnedSpaces.partition/2` drops a pinned
  # id that names no loaded space (archived, or in an org the viewer has left),
  # and states that skip-unknown property in its own moduledoc, so the block
  # can render a strict SUBSET of what is stored. Writing the rendered order
  # back wholesale would unpin every conversation it could not see.
  #
  # So resolve one anchor instead: the first id after `space_id` in the new
  # rendered order that is still stored. The pin lands immediately before that
  # anchor, leaving unrendered pins where they are. No anchor means the pin was
  # moved to the end of the block, so it appends.
  #
  # Returns nil when `space_id` is not pinned at all, which the caller treats
  # as "ignore this event".
  defp pinned_destination_index(stored, space_id, ordered_ids) do
    if space_id in stored do
      rest = Enum.reject(stored, &(&1 == space_id))

      successor =
        ordered_ids
        |> Enum.drop_while(&(&1 != space_id))
        |> Enum.drop(1)
        |> Enum.find(&(&1 in rest))

      case successor do
        nil -> length(rest)
        id -> Enum.find_index(rest, &(&1 == id))
      end
    end
  end

  # Feeds the drawer's existing sr-only aria-live region. The name comes from
  # `sidebar_row_label/2`, the same helper the row's visible label uses, so a
  # DM announces the person's name rather than a nil `space.name`. No "#"
  # prefix: the block holds channels and people, and a hash on a person is
  # the wrong object type.
  defp announce_pinned_move(socket, space_id, direction) do
    name =
      case Enum.find(socket.assigns.channel_sections.pinned, &(&1.id == space_id)) do
        nil -> nil
        space -> sidebar_row_label(space, socket.assigns.user_id)
      end

    text =
      case {name, direction} do
        {nil, _} -> nil
        {name, "up"} -> "Moved #{name} up"
        {name, "down"} -> "Moved #{name} down"
        {name, nil} -> "Moved #{name}"
      end

    assign(socket, :drawer_reorder_announcement, text)
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
        socket.assigns.hidden_channel_ids,
        socket.assigns.agents_block
      )
    )
  end

  # Re-read the pin list and rebuild every rail region that consumes it:
  # `@channel_sections` (the Pinned block plus the DM and sub-org remainders
  # a pin is lifted out of) and `@sidebar_sections` (the resolver-driven
  # client sections, which exclude pinned channels).
  #
  # Reads back from preferences rather than patching `@pinned_space_ids` in
  # place, so the render agrees with what was persisted — including the
  # append-if-absent ordering `Sidebar.set_space_pinned/3` applies and the
  # no-op it performs for an anonymous session with no user row.
  defp recompute_pinned(socket) do
    pinned_space_ids = Sidebar.list_pinned_space_ids(socket.assigns.user_id)

    socket
    |> assign(:pinned_space_ids, pinned_space_ids)
    |> assign(
      :channel_sections,
      channel_sections(
        socket.assigns.channels,
        socket.assigns.dm_conversations,
        pinned_space_ids,
        socket.assigns.hidden_channel_ids,
        socket.assigns.closed_dm_at
      )
    )
    |> recompute_sidebar()
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
    Chat.list_spaces(
      kind: "channel",
      scope: socket.assigns[:access_scope] || socket.assigns[:external_scope]
    )
  end

  # The rail's ARCHIVED channel list. Sibling of `rail_channels/1` above, and
  # deliberately a separate function rather than an `archived: true` flag on it:
  # the two lists treat an external user differently, and a boolean parameter
  # would bury that asymmetry at every call site. The live list is FILTERED to
  # the allowlist; this one is EMPTIED outright, because the collapsed
  # "Archived" group is an internal discovery surface (design canvas §1
  # non-goals) and an external user has no archived view at all. That is the
  # same reason `do_mount/3` already states where it seeds the assign.
  #
  # Latent, not live, at the time of writing (task 019ffebf-4745): both
  # renderings of the archived group sit inside `!@external?` gates in
  # `chat_live.html.heex`, and `@external?` is assigned once in `do_mount/3`
  # and never reassigned, so the gate cannot flip mid-session and an unrendered
  # assign never reaches the wire. Routed through here anyway so that deleting
  # one of those template gates cannot silently turn an unscoped read into a
  # leak.
  defp rail_archived_channels(socket) do
    if socket.assigns[:external?],
      do: [],
      else:
        Chat.list_spaces(kind: "channel", archived: true, scope: socket.assigns[:access_scope])
  end

  # The rail's DM and group conversation list, scoped to the acting user.
  # Third sibling of `rail_channels/1` and `rail_archived_channels/1` above,
  # and the single derivation behind every site that needs one: `do_mount/3`
  # seeds the assign, `handle_params/3` re-reads it on each navigation, and
  # `:sidebar_changed` re-reads it when someone is added to a conversation
  # mid-session (task 01a01ccf).
  #
  # That third site is why this function exists. The same query-and-filter was
  # already written out twice, and the two copies had drifted — only
  # `do_mount/3` carried the embedded / nil-user short-circuit — so a third
  # literal copy would have had to pick which of the two was the rule. One
  # function, one answer, and a fourth caller inherits it.
  #
  # `Chat.list_user_conversations/2` returns every space the user holds a
  # participant row in, which includes execution and meeting spaces. The `kind`
  # filter is what narrows that to the two kinds the rail's "Direct Messages"
  # section renders, and it belongs here rather than in the query: that
  # function's other consumers want the unfiltered list.
  #
  # Split across two heads because `do_mount/3` derives this BEFORE any of the
  # three inputs reaches `socket.assigns` — `:user_id`, `:external_scope` and
  # `:embedded` are all assigned further down that same function — so the
  # socket-shaped sibling cannot serve it. `dm_conversations_for/3` holds the
  # rule; the socket wrapper is the post-mount door to it, which is what keeps
  # mount and every later refresh reading the same one.
  defp rail_dm_conversations(socket) do
    dm_conversations_for(
      socket.assigns[:user_id],
      socket.assigns[:access_scope] || socket.assigns[:external_scope],
      socket.assigns[:embedded]
    )
  end

  # Embedded is the meeting chat pane: it paints ONE space and populates no
  # sidebar, so it never pays for this query. The nil-user head covers the
  # anonymous session, which holds no participant rows to find.
  defp dm_conversations_for(_user_id, _scope, true), do: []
  defp dm_conversations_for(nil, _scope, _embedded?), do: []

  defp dm_conversations_for(user_id, scope, _embedded?) do
    user_id
    |> Chat.list_user_conversations(scope: scope)
    |> Enum.filter(&(&1.kind in ["dm", "group"]))
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
                socket.assigns.hidden_channel_ids,
                socket.assigns.agents_block
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
  # gates on root_admin?). On success we broadcast `:sidebar_defaults_changed`
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

  # One rendered section flattened into what the "Move to organisation…"
  # dialog and the write both need: the human-readable name, the colour dot
  # token, and the `org_id` that actually goes onto `chat_spaces`.
  defp section_summary(sidebar_sections, section_id) when is_binary(section_id) do
    Enum.find_value(sidebar_sections, fn
      %{section: %{id: ^section_id} = s} ->
        %{section_id: s.id, org_id: s.org_id, name: Section.display_name(s), color: s.color}

      _ ->
        nil
    end)
  end

  # The rail's own label for the org a channel is moving OUT of, falling back
  # to the org record's name when that org has no section in the rail. Both
  # readers here go through `Section.display_name/1` (task 01a08212): a
  # following section's `name` is nil, and a nil must never reach the move
  # dialog or `raise_move_toast/4`'s is_binary guard, which drops the toast.
  defp source_section_name(sidebar_sections, %Platform.Tenancy.Org{} = org) do
    Enum.find_value(sidebar_sections, org.name, fn
      %{section: %{org_id: section_org_id} = section} when section_org_id == org.id ->
        Section.display_name(section)

      _ ->
        nil
    end)
  end

  defp org_archived?(org_id) do
    case Platform.Tenancy.get_org(org_id) do
      %Platform.Tenancy.Org{archived_at: nil} -> false
      %Platform.Tenancy.Org{} -> true
      # A destination that no longer resolves is not somewhere to file a
      # channel either, so refuse on the same branch.
      _ -> true
    end
  end

  # Every section a channel can be moved TO: the rail minus where it already
  # is. Built from the channel's `org_id` rather than the section it renders
  # under so a personal placement override cannot offer a no-op destination.
  defp reassign_destinations(sidebar_sections, org_id) do
    sidebar_sections
    |> Enum.map(& &1.section)
    |> Enum.reject(&(&1.org_id == org_id))
    |> Enum.map(
      &%{
        section_id: &1.id,
        org_id: &1.org_id,
        name: Section.display_name(&1),
        dot: section_dot_class(&1.color)
      }
    )
  end

  # A name clash is the ORDINARY failure of this action, not an edge case.
  # `chat_spaces_unique_org_slug` is a partial unique index on
  # `(org_id, slug) WHERE org_id IS NOT NULL` (migration 20260618220754,
  # declared on `Chat.Space.changeset/2`), and two channels called "general"
  # in two different orgs is the normal shape of the data — so moving one
  # onto the other is a thing admins will hit in routine use. The old generic
  # "Could not move the channel." told them nothing actionable.
  #
  # Matched on the CONSTRAINT NAME, not on the `:slug` key. `Space.changeset/2`
  # declares four unique constraints plus a required-slug validation, all of
  # which surface under `:slug`. Only this one can fire from an org_id-only
  # update today, but `chat_spaces_null_scope_channel_slug` starts firing the
  # day a "move to no organisation" destination exists — and matching the key
  # would then name an org in a message about a channel that has none.
  defp reassign_error_message(%Ecto.Changeset{errors: errors}, to_name) do
    slug_taken? =
      Enum.any?(errors, fn
        {:slug, {_msg, opts}} ->
          Keyword.get(opts, :constraint_name) == "chat_spaces_unique_org_slug"

        _ ->
          false
      end)

    if slug_taken? do
      "A channel in #{to_name} already uses that name. Rename one of them first."
    else
      "Could not move the channel."
    end
  end

  defp reassign_error_message(_reason, _to_name), do: "Could not move the channel."

  # The scope tokens are the recolor palette — whitelist-validate the
  # inbound color so a forged payload can't write an arbitrary string onto a
  # section's `color` (defense-in-depth on top of the admin gate).
  #
  # The palette is the five compiled sibling tokens plus the section's OWN
  # org token (task 01a116de stage 3). The root org has no compiled token:
  # it is install data, so its swatch is read off its row and an admin can
  # always put a section back on its own org's colour.
  @sibling_scope_tokens ~w(soylent wayne-tech sxi paragon cyberdyne)

  @doc false
  @spec sibling_scope_tokens() :: [String.t()]
  def sibling_scope_tokens, do: @sibling_scope_tokens

  defp valid_scope_token?(color, section_id, sidebar_sections) do
    color in @sibling_scope_tokens or color == own_scope_token(sidebar_sections, section_id)
  end

  defp own_scope_token(sidebar_sections, section_id) do
    Enum.find_value(sidebar_sections, fn
      %{section: %{id: ^section_id} = section} -> section_own_token(section)
      _ -> nil
    end)
  end

  @doc """
  The CSS-form colour token a section wears when it follows its own org: the
  org slug as stored with `_` -> `-`, the same rule `Sidebar` seeds `color`
  with. `nil` when the section was loaded without its org.
  """
  @spec section_own_token(map()) :: String.t() | nil
  def section_own_token(section), do: section |> Map.get(:org_slug) |> css_slug()

  @doc """
  The `data-scope` value that colours a section's header dot through the
  slug-agnostic var path (`PlatformWeb.Components.ScopeColorStyles`), or
  `nil` when the dot takes a compiled `bg-<token>-dot` class instead or the
  section wears a colour that is not its own org's.

  This is how the root org's dot is coloured: it has no compiled class, so
  its colour comes from its own row (`color_hue` / `color_chroma` /
  `color_lightness`), whatever the root is called on this install.
  """
  @spec section_dot_scope(map()) :: String.t() | nil
  def section_dot_scope(section) do
    color = Map.get(section, :color)
    org_slug = Map.get(section, :org_slug)

    if is_nil(section_dot_class(color)) and is_binary(org_slug) and
         css_slug(org_slug) == color,
       do: org_slug,
       else: nil
  end

  # Shared tail for every successful admin-default write: broadcast the
  # shared-defaults invalidation to all OTHER sessions (so non-admin users and
  # the admin's other tabs converge live), then rebuild the acting admin's own
  # rail from the now-updated default layer.
  #
  # RE-FETCHES `@channels` rather than re-resolving the ones already in the
  # assign (task 019ffcad). One of the five writes routed through here
  # (`confirm_channel_reassign`) changes a CHANNEL and not only a section: it
  # writes `chat_spaces.org_id`. `Sidebar.resolve/3` buckets each channel by
  # the `org_id` on the struct it is handed (`default_section_id/3`), so
  # re-resolving the stale assign filed the moved row straight back under its
  # old section and the move read as a failure to the admin who performed it.
  # This comment used to assert that channels were unchanged here; that
  # assumption WAS the defect.
  #
  # A re-fetch rather than patching the moved struct into `@channels` in place:
  # the rail then renders what the database holds rather than what this process
  # believed a moment ago, it goes through `rail_channels/1` so an external
  # user's scope is re-applied on the way (the invariant that helper exists to
  # carry), and it stays correct for any future admin write that touches a
  # channel row. The cost is one `Chat.list_spaces` per admin default write.
  # Four of the five call sites do not need it and pay for it anyway: all five
  # are rare, human-driven admin actions over a tens-of-rows table, which is
  # not a price worth a second code path to avoid.
  defp recompute_sidebar_after_admin_write(socket) do
    ChatPubSub.broadcast_sidebar_defaults_changed_from(self())
    refresh_chat_containers(socket)
  end

  # Uncollapse the section a channel was just moved INTO, for the acting admin
  # only (task 019ffcad stage 3, design canvas "signature element").
  #
  # Stages 1 and 2 make the rail repaint. They are not enough on their own, and
  # the render path is why. Collapse is a flag rather than a filter: the
  # resolver stamps `collapsed?` and hands the section its full channel list, so
  # `section_channel_rows/3` is what decides, and on a collapsed section it
  # draws only the rows carrying unread. A channel filed into an org a moment
  # ago has none, so the moved row is absent from the DOM entirely. The rail
  # repaints perfectly and the admin sees nothing, which is the reported bug
  # surviving its own fix.
  #
  # Ordered BEFORE the recompute: `Sidebar.resolve_for_user/2` re-reads
  # preferences from the database on every recompute, so the write has to land
  # first for the resolver to stamp `collapsed?: false` on the destination.
  #
  # Scope. This writes the ACTING user's own preference and no one else's.
  # `set_section_collapsed/3` is keyed on `socket.assigns.user_id`, and the
  # `:sidebar_defaults_changed` broadcast that follows makes every other session
  # re-resolve against ITS OWN prefs, so this admin's other tabs converge on the
  # expansion for free and nobody else's fold state moves. Writing a preference
  # on a user's behalf is acceptable here only because the section chevron puts
  # it back in one click.
  #
  # Unconditional rather than read-then-write-if-collapsed: `set_section_collapsed/3`
  # takes the desired next state and is idempotent, and this runs once per
  # human-driven admin move.
  #
  # The second clause is the degrade path. `section_summary/2` always populates
  # `section_id`, so it should be unreachable; it exists so that a destination
  # assign lacking it costs the admin one chevron click rather than the move.
  defp expand_destination_section(socket, section_id) when is_binary(section_id) do
    _ = Sidebar.set_section_collapsed(socket.assigns.user_id, section_id, false)
    socket
  end

  defp expand_destination_section(socket, _section_id), do: socket

  # Say what just happened, at the foot of the rail (task 019ffcad stage 4,
  # design canvas "Type" and "Layout").
  #
  # Stages 1 to 3 put the row in its new section and make it visible there. The
  # admin is looking at the SOURCE section they filed the channel out of, where
  # the only observable event is a row leaving, and a row leaving reads as a
  # deletion before it reads as a relocation. So the rail says the sentence.
  #
  # BOTH names or nothing. "Moved #gen-migration." leaves the reader checking
  # where it went, which is the work this line exists to save, and the
  # destination half is the half a person actually needs.
  #
  # No action button. The move already carries a two-step confirmation and the
  # row's own menu moves the channel back in one click, so this stage renders the
  # reused toast shape with the message alone. Marlowe's separate decision to offer
  # an Undo here is task 01a01052-3155-7c15-8c48-9ff8955b9b70.
  #
  # Auto-clears on the hide toast's pattern exactly: a `Process.send_after/3`
  # paired with a `{:clear_move_toast, channel_id}` handler that only nils the
  # assign while the toast still names THIS channel, so a second move inside the
  # window replaces the line and the earlier timer's fire becomes a no-op. No
  # timer refs to track or cancel.
  #
  # The guard is the degrade path, and it degrades to silence rather than to a
  # half-sentence: `request_channel_reassign` populates both names, so a missing
  # one means the confirm assign was not built by that handler, and "Moved  to
  # ." is worse than no line at all.
  defp raise_move_toast(socket, channel_id, channel_name, section_name)
       when is_binary(channel_name) and is_binary(section_name) do
    Process.send_after(self(), {:clear_move_toast, channel_id}, @move_toast_ms)

    assign(socket, :move_toast, %{
      channel_id: channel_id,
      channel_name: channel_name,
      section_name: section_name
    })
  end

  defp raise_move_toast(socket, _channel_id, _channel_name, _section_name), do: socket

  defp apply_save_edit(socket, message_id, body) do
    participant = socket.assigns.current_participant

    with %Platform.Chat.Message{} = msg <- Platform.Chat.get_message(message_id),
         {:ok, original} <- {:ok, msg},
         :ok <- Chat.authorize_author(msg, participant) do
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

  defp frozen_toast_message(freezing_action) do
    case freezing_action do
      %{participant_display_name: name} when is_binary(name) and name != "" ->
        "#{name} began work on this message while you were editing — your edit was not saved."

      _ ->
        "An agent began work on this message while you were editing — your edit was not saved."
    end
  end

  # ── Upload staging dialog events ──────────────────────────────────────

  defp handle_upload_progress(_upload_name, _entry, socket) do
    {:noreply, socket}
  end

  # Agents goal surface (task 01a0b491 stage 4): a leader swap repaints both
  # avatars with no reload. Matches ONLY the `agents_leader` role — every other
  # role broadcasts on the same topic and must fall through untouched, which
  # the catch-all clause below does.
  #
  # Both assigns are recomputed, not patched: the rail block and the header
  # panel each carry their own copy of the leader, and refreshing one of them
  # is how the two faces would come to disagree.
  @impl true
  def handle_info({:role_assignment_changed, %{role_key: role_key}}, socket) do
    if role_key == Sidebar.agents_leader_role() do
      {:noreply,
       socket
       |> assign_agents_block(Sidebar.agents_rail_block())
       |> assign(:goal_panel, Sidebar.goal_panel(socket.assigns.active_space))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:settings_closed}, socket) do
    {:noreply, assign(socket, :show_settings, false)}
  end

  def handle_info({:members_closed}, socket) do
    {:noreply, assign(socket, :show_members, false)}
  end

  def handle_info({:members_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
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
    #
    # Task 01a011d4: through the SAME subscribe-scope decision `do_mount/3`
    # builds the mount-time set from and `rail_subscribe_space_ids/1` derives
    # the held set from, so all three sites agree by construction. Without the
    # guard an external session picked up the topic of every internal-only
    # channel created after it mounted. `presence_subscribe_space_ids/2` is a
    # pass-through for internal and anonymous sessions, so the workspace-wide
    # internal rail and its unread badges are unchanged.
    #
    # Evaluated once, at creation time: a user granted access to a channel
    # AFTER it was created gets no subscription from THIS clause. Task 01a017a3
    # closed that gap on the `:sidebar_changed` reconcile rather than here,
    # because the grant is a different event from the creation and the grant
    # choke points (`ExternalGrants.apply_grant/2`,
    # `ExternalGrants.add_space_participants/2`, `Chat.do_add_participant/2`)
    # already emit a per-user sidebar invalidation.
    #
    # No paired `unsubscribe` anywhere. Phoenix.PubSub's registry runs with
    # `keys: :duplicate` and `unsubscribe/2` drops ALL of a pid's registrations
    # for a topic at once, so a paired call here would silently kill another
    # code path's subscription with no error and no log.
    socket =
      if space.id in presence_subscribe_space_ids(
           [space],
           socket.assigns.user_id,
           socket.assigns[:access_scope]
         ) do
        subscribe_space(socket, space.id, :chat_rail)
      else
        socket
      end

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
         socket.assigns.pinned_space_ids,
         socket.assigns.hidden_channel_ids,
         socket.assigns.closed_dm_at
       )
     )
     |> assign(
       :sidebar_sections,
       resolve_sidebar_sections(
         socket.assigns.user_id,
         channels,
         socket.assigns.hidden_channel_ids,
         socket.assigns.agents_block
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
      socket =
        if connected?(socket), do: subscribe_space(socket, space_id, :chat_rail), else: socket

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
  # Expiry of the `?message=` arrival ring (task 019fabe8 stage 2).
  # Guarded on the highlight STILL pointing at the anchor: a search jump
  # landing inside the window would otherwise have its own highlight
  # stolen when this timer fires. Same shape as `:clear_undo_toast`
  # below — the guard makes the late fire a no-op, so no timer refs need
  # tracking or cancelling.
  #
  # `:anchor_message_id` deliberately survives: the scroll hook (stage 3)
  # keys its once-per-id guard off that attribute, and re-clearing it
  # would hand the message list back to the bottom-snap behaviour the
  # anchor exists to suppress.
  def handle_info({:clear_anchor_highlight, message_id}, socket) do
    if socket.assigns[:highlighted_message_id] == message_id do
      {:noreply, SearchHooks.set_highlights(socket, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:clear_undo_toast, space_id}, socket) do
    case socket.assigns.undo_toast do
      %{space_id: ^space_id} -> {:noreply, assign(socket, :undo_toast, nil)}
      _ -> {:noreply, socket}
    end
  end

  # Auto-clear the move confirmation 4s after a move (task 019ffcad stage 4).
  # Guarded on the line still naming THIS channel, same reason as the hide
  # toast's clear above: a second move inside the window replaces the line, and
  # the first timer firing here would otherwise wipe the newer one early.
  #
  # Keyed on `channel_id` and reading `:move_toast`, so this and the hide toast's
  # clear cannot reach each other's state even when both timers are in flight.
  def handle_info({:clear_move_toast, channel_id}, socket) do
    case socket.assigns.move_toast do
      %{channel_id: ^channel_id} -> {:noreply, assign(socket, :move_toast, nil)}
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
    {:noreply, refresh_rail(socket)}
  end

  # Shared org-DEFAULT invalidation (chat sidebar Stage 6). Fired on the
  # `chat:sidebar:defaults` topic when a root-org admin curates the default layer
  # (rename / recolor / reorder / reassign). EVERY connected session receives
  # this (except the acting admin's own tab, which recomputed synchronously)
  # and refreshes its rail so the admin's default change is visible to all
  # users without a refresh.
  #
  # RE-FETCHES `@channels`, via the same `refresh_chat_containers/1` the acting
  # tab uses in `recompute_sidebar_after_admin_write/1` (task 019ffcad stage 2).
  # An earlier version of this comment claimed the resolver reads the updated
  # default sections from the DB and that re-resolving the cached channel list
  # was therefore enough. True for rename, recolor and reorder, which write the
  # SECTION row. False for reassign, which writes `chat_spaces.org_id` and
  # leaves the section rows alone: `Sidebar.resolve/3` buckets each channel by
  # the `org_id` on the struct it is handed, so a session re-resolving its
  # cached `@channels` filed the moved row back under the source section and
  # kept it there until the reader re-mounted.
  #
  # The two paths are deliberately identical. Splitting them by event so the
  # other three writes skip the fetch would need the broadcast to carry which
  # kind of write fired it, and would leave the next channel-touching admin
  # write silently stale in every session but one. The cost is one
  # `Chat.list_spaces` per connected session per admin default write; those are
  # rare, human-driven actions over a tens-of-rows table.
  def handle_info(:sidebar_defaults_changed, socket) do
    {:noreply, refresh_chat_containers(socket)}
  end

  # Task 01a0181f: release the space subscription when the viewer LOSES access
  # to it. `:sidebar_changed`'s reconcile above is ADD-ONLY on purpose, so
  # without this clause a revoked session keeps the registration for the rest of
  # its life: the rail row disappears on the next reload, the topic does not.
  # Message bodies do not leak (MessagesHooks halts for any non-active space),
  # but `{:participant_joined, _}` keeps writing strangers into
  # `@participants_map` — and so into the @-mention autocomplete of the space
  # the viewer IS in — and `{:pin_added, _}` keeps writing foreign rows into
  # `@pins`. Releasing the registration closes both at the choke point instead
  # of bolting a space guard onto each handler.
  #
  # The predicate is LOSS OF ACCESS, never "my participant row was deleted".
  # `presence_subscribe_space_ids/2` returns its input unchanged for an internal
  # or anonymous session, so this clause is inert for them: internal users see
  # every workspace channel in the rail with or without a participant row, and
  # keying on identity would kill live chat for any internal user removed from a
  # channel they can still open.
  #
  # The deviation this clause used to document — that its unsubscribe reached
  # across the ADR 0013 ownership boundary and destroyed ShellLive's
  # registration for the same topic on this shared pid — is CLOSED (task
  # 01a01a1b). Both surfaces now go through `PlatformWeb.SpaceTopics`, so this
  # releases only chat's own two holds and ShellLive's are released by ShellLive
  # alone, off its own `:roster_resolved` / `:presence_spaces_resolved` paths.
  #
  # Both holds, not one: losing access must drop this module's interest in the
  # space entirely, which was the existing intent when a single unsubscribe did
  # the job. Whether the registration itself survives is now correctly a
  # question about the OTHER surfaces' holds.
  def handle_info({:participant_left, %{participant_type: "user"} = participant}, socket) do
    socket =
      if participant.participant_id == socket.assigns.user_id and
           participant.space_id not in presence_subscribe_space_ids(
             [%{id: participant.space_id}],
             socket.assigns.user_id,
             socket.assigns[:access_scope]
           ) do
        socket
        |> unsubscribe_space(participant.space_id, :chat_rail)
        |> unsubscribe_space(participant.space_id, :chat_active)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "Refresh this socket's rail after ShellLive rebuilds its access scope."
  def on_access_changed(socket) do
    socket = socket |> refresh_rail() |> release_revoked_rail_topics()

    space = socket.assigns[:active_space]

    if socket.assigns[:embedded] or is_nil(space) or
         Platform.Access.can?(socket.assigns[:access_scope], "chat.read", space) do
      socket
    else
      socket
      |> unsubscribe_space(space.id, :chat_active)
      |> put_flash(:error, "You no longer have access to that channel.")
      |> push_navigate(to: "/chat")
    end
  end

  defp refresh_rail(socket) do
    if socket.assigns.embedded do
      socket
    else
      # `rail_channels/1`, not a bare `Chat.list_spaces/1` (task 019ffebf-4745).
      # This arm runs in the acting user's OTHER tabs, so an unscoped read here
      # re-broadened an external user's rail to every channel in the workspace
      # on any sidebar change they made elsewhere.
      channels = rail_channels(socket)
      archived_channels = rail_archived_channels(socket)

      # Task 01a01ccf. Being ADDED to an existing DM or group conversation is a
      # sidebar change like any other — `Chat.do_add_participant/2` already
      # emits this event for it — but until now the handler re-read only the
      # two channel lists, so `@dm_conversations` stayed frozen at its
      # mount-time value. The conversation therefore had no rail row AND no
      # subscription (`rail_subscribe_space_ids/1` unions this assign), so the
      # messages arriving in it were missed with no badge, no row and no other
      # signal until the viewer happened to reload.
      #
      # It is assigned BEFORE `recompute_pinned/1` below and that order is
      # load-bearing: `recompute_pinned/1` builds `@channel_sections` off
      # `socket.assigns.dm_conversations`, so assigning after it would
      # subscribe the topic and still not draw the row — the same silent miss,
      # one layer down.
      dm_conversations = rail_dm_conversations(socket)

      # `recompute_pinned/1` covers the `@sidebar_sections` re-resolve this
      # handler used to do inline, and adds the pin refresh. The topic is
      # per-user (`chat:sidebar:<user_id>`) and the broadcast excludes the
      # acting process, so this arm runs in the SAME user's other tabs — which
      # is exactly where a pin has to converge. Without the pin half, tab B
      # kept rendering a stale Pinned block until its next navigation.
      #
      # `@closed_dm_at` is re-read here for the same reason and from the same
      # place, the user's preferences (task 019ffc5f, Marlowe's pinned-close
      # report). Close now writes the pin AND the close together, so a tab that
      # refreshed only the pin list would take the row out of the Pinned block
      # and leave it in Direct Messages: half the action applied, which is the
      # shape of the bug being fixed. Safe to overwrite because every writer of
      # this assign already sets it from the store, so the assign is a cache of
      # that store and never holds an optimistic value.
      #
      # The re-read lives here, not inside `recompute_pinned/1`: its other two
      # callers act on the tab that just wrote, where the assign is already
      # fresh, and would pay a preferences read for nothing.
      socket =
        socket
        |> assign(:channels, channels)
        |> assign(:archived_channels, archived_channels)
        |> assign(:dm_conversations, dm_conversations)
        |> assign(:closed_dm_at, Accounts.get_closed_dm_at(socket.assigns.user_id))
        |> recompute_pinned()

      # Task 01a017a3: reconcile the PubSub subscribe set against the REFRESHED
      # rail. A session granted access to a channel that already existed gets
      # no `{:space_created, _}` (that fired when the channel was created, and
      # its guard correctly declined), so without this the channel appeared in
      # the rail with a badge that could never move.
      #
      # This is where it belongs rather than on a bespoke grant event: nine
      # sites already emit `:sidebar_changed`, every one of them changes what
      # the viewer can see, and a grant path added later that forgets a second
      # bespoke broadcast would re-create this exact defect one layer up.
      reconcile_rail_subscriptions(socket)
    end
  end

  defp release_revoked_rail_topics(socket) do
    desired = rail_subscribe_space_ids(socket)

    socket.assigns[:chat_space_holders]
    |> Enum.reduce(socket, fn {space_id, holders}, acc ->
      if MapSet.member?(holders, :chat_rail) and not MapSet.member?(desired, space_id),
        do: unsubscribe_space(acc, space_id, :chat_rail),
        else: acc
    end)
  end

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
  # The list itself now lives on `Platform.Chat.reserved_slug_prefix?/1` —
  # `ExternalUserScope` needs the SAME answer this LiveView uses, and a second
  # private copy is how the plug came to deny an invited member the very
  # meeting space this LiveView would have rendered them.

  # Gate on the deep-link param (task 019fabe8 stage 4). Present => refuse to
  # auto-create; the caller's `is_nil(space)` branch then clears the stale
  # route-resume entry and lands the reader on `/chat`.
  defp maybe_bootstrap_space(%{"message" => msg} = _params, _slug, _org_id, _socket)
       when is_binary(msg) and msg != "",
       do: nil

  defp maybe_bootstrap_space(_params, slug, org_id, socket),
    do: bootstrap_space(slug, org_id, socket.assigns.user_id, not fenced_session?(socket))

  # A FENCED session (task 01a14721 stage 4: an internal member of sub-orgs
  # only, `Access.org_fence/1` != :unfenced) never MINTS a channel on a slug
  # miss. Before this, `/chat/<slug of a root-org channel>` missed the
  # org-scoped lookup (the row is in the root org), fell through to the mint
  # below, and created a NEW channel in the member's own org with them seated
  # as admin, so the fence only ever saw a space it admits. The refusal is
  # applied on EVERY miss, not only when the slug exists elsewhere: a random
  # slug and a foreign one take the same `is_nil(space)` branch in
  # `handle_params/3` (push_navigate to /chat), so the refusal is not an
  # existence oracle. Unfenced sessions (root members, admins, zero-membership
  # users, guests, whom `org_fence/1` reports :unfenced) mint exactly as before.
  # Adopting an existing ORG-LESS row is left alone: it writes nothing, and the
  # fence still decides on the adopted row through `internal_read_denied?/2`.
  defp fenced_session?(socket),
    do: is_binary(socket.assigns.user_id) and Access.org_fence(access_scope(socket)) != :unfenced

  # `user_id` is the navigating user, who is this channel's creator by every
  # definition we have (task 01a0fd62): stamping it as `created_by` makes
  # `Chat.create_space/1` seat them as admin, and `ensure_participant/2` then
  # finds that row and inserts nothing.
  defp bootstrap_space(slug, org_id, user_id, mint?) when is_binary(slug) do
    cond do
      # Never bootstrap for UUIDs — those are fetched directly
      valid_uuid?(slug) ->
        nil

      # Refuse system-managed slug prefixes regardless of pattern match
      Chat.reserved_slug_prefix?(slug) ->
        nil

      # Only bootstrap slugs that look like real channel slugs
      not String.match?(slug, @slug_pattern) ->
        nil

      # ADOPT an existing ORG-LESS row rather than minting a second one (task
      # 01a00910 stage 5). The caller has already missed on the ORG-SCOPED
      # `get_space_by_slug(slug, org_id: ...)`, and an org-less row is invisible
      # to that lookup — which is how navigating to an existing channel could
      # silently INSERT a duplicate of it. The lookup is `org_id IS NULL`
      # specifically, NOT the unscoped oldest-row branch, so ADR-0042 per-org
      # slug scoping ("#general" in Acme vs in SXI) is untouched: a channel
      # belonging to ANOTHER org still bootstraps a fresh one for this org.
      #
      # The adopted row is returned AS IS, not stamped with the active org.
      # Writing `org_id` is `Sidebar.reassign_channel/3`'s job — an admin act,
      # behind the "Move to organisation…" confirmation, because it re-grants
      # canvas access across orgs. A page mount must not perform it silently.
      space = Chat.get_orgless_space_by_slug(slug) ->
        space

      # A fenced session never mints (see `fenced_session?/1`).
      not mint? ->
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
          |> maybe_put_created_by(user_id)

        case Chat.create_space(attrs) do
          {:ok, space} -> space
          {:error, _} -> Chat.get_space_by_slug(slug, org_id: org_id)
        end
    end
  end

  defp bootstrap_space(_, _, _, _), do: nil

  defp maybe_put_created_by(attrs, user_id) when is_binary(user_id),
    do: Map.put(attrs, :created_by, user_id)

  defp maybe_put_created_by(attrs, _), do: attrs

  # Safety-net lookup for system-managed slug prefixes (exec, meeting, dm,
  # group). These spaces are minted by orchestration code paths and MAY
  # have `org_id = NULL` (exec spaces created before the org_id backfill
  # migration; meeting/dm/group spaces intentionally cross-org). The
  # org-scoped `get_space_by_slug/2` filters them out; fall back to an
  # unscoped lookup, guarded by the reserved-prefix list so the ADR-0042
  # per-org channel-slug scoping ("#general" in Acme vs "#general" in SXI)
  # is NEVER weakened for user-created channel slugs.
  defp system_prefix_fallback(slug) when is_binary(slug) do
    if Chat.reserved_slug_prefix?(slug) do
      Chat.get_space_by_slug(slug, [])
    end
  end

  defp system_prefix_fallback(_), do: nil

  # ── The socket-path half of the external admission gate (task 01a011ed) ─────
  #
  # `PlatformWeb.Plugs.ExternalUserScope` decides which space an external user
  # may open, and a plug runs on HTTP requests only. A client-sent `live_patch`
  # frame reaches `handle_params/3` without passing any plug, so until this
  # shipped the socket re-resolved and loaded any space an external user could
  # name. Both LiveView resolution points now clear the SAME predicate the plug
  # clears. Do not grow a third copy of the rule here — stage 1 lifted it out of
  # the plug precisely because two gates answering one question drift apart.
  #
  # The `nil` space is the CALLER's branch, not this one. Both call sites treat
  # "does not resolve" and "not yours" identically, and `authorized_space?/2`
  # answers false for nil anyway.
  #
  # `user_id` is a bare binary in this LiveView; `authorized_space?/2` reads
  # `user.id`, so it is wrapped here rather than taught about binaries.
  defp external_space_denied?(socket, space) do
    external_session?(socket) and
      not Platform.Chat.ExternalScope.authorized_space?(%{id: socket.assigns.user_id}, space)
  end

  defp access_scope(socket, user_id \\ nil) do
    case socket.assigns[:access_scope] do
      %Scope{} = scope -> scope
      _ -> Scope.for_user(Accounts.get_user(user_id || socket.assigns.user_id))
    end
  end

  defp restricted_channel_ids(socket, channels, archived_channels, user_id \\ nil) do
    ids = Enum.map(channels ++ archived_channels, & &1.id)
    Access.restricted_space_ids(access_scope(socket, user_id), ids)
  end

  defp channel_listing_scope(false, _user_id), do: nil

  defp channel_listing_scope(true, user_id),
    do: Platform.Chat.ExternalScope.for_user(user_id)

  # URL-open gate for an INTERNAL session (task 01a14721 stage 1): the org
  # fence and an explicit `chat.read` deny refuse the space. Asked through
  # `Access.within?/4` with the existing admission (`implicit_join_denied?/2`,
  # which has already admitted) standing in for the role-rule allow: the
  # Scope's participant ids are a BUILD-TIME snapshot, so `can?/3` would
  # refuse a DM created after this socket mounted. The STRUCT is passed, so
  # an unjoined channel in the member's own org stays openable. (The stage
  # text named `can?/3`; `within?/4` was accepted by the stack owner for
  # exactly this snapshot reason.)
  defp internal_read_denied?(socket, space) do
    not external_session?(socket) and
      not Access.within?(access_scope(socket), "chat.read", space, true)
  end

  defp include_restricted_channels(readable, listed, restricted_ids) do
    (readable ++ Enum.filter(listed, &MapSet.member?(restricted_ids, &1.id)))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp restricted_space_denied?(socket, %{id: id, kind: "channel"}) do
    scope = access_scope(socket)

    MapSet.member?(Access.restricted_space_ids(scope, [id]), id) and
      not Access.can?(scope, "chat.read", id)
  end

  defp restricted_space_denied?(_socket, _space), do: false

  # Space kinds an INTERNAL user may open — and therefore implicitly join —
  # without a `chat_participants` row already existing (task 01a01d0e).
  #
  # This list is NOT a judgement call, and it is deliberately wider than the
  # filing ticket proposed. Every entry below is behaviour some other test in
  # this suite already pins, and each one was added here because removing it
  # turned that test red:
  #
  #   * `channel` — `Chat.list_spaces(kind: "channel", scope: nil)` applies NO
  #     membership filter, so the rail already renders every workspace channel
  #     to every internal user, and the click that follows must be able to join
  #     them. Task 01a0181f established that this is deliberate rather than its
  #     own leak.
  #   * `system` — the per-agent system-event spaces (created under the
  #     `system-<agent-slug>` name by the agents layer; deliberately not named
  #     here, because `system_event_scheduler_t6_e2e_test.exs` guards that no
  #     `_web/live/` file mentions those modules even in prose).
  #     `handle_params/3` has a dedicated `system_prefix_fallback/1` branch for
  #     reaching them by slug, so they are navigable on purpose and carry
  #     operational log output rather than anyone's private correspondence.
  #   * `execution` — the ticket named these as part of the exposure. The
  #     codebase disagrees, explicitly and in tests: PR #548 stage 3 propagates
  #     a task pin to every @-mentioned participant, and
  #     `ChatLiveTest`'s "mentioned bystander opens pinned exec space via rail
  #     row" and "resolves cross-org exec-space slug for @-mentioned bystander"
  #     both open an exec space for a user who has a PIN row and no participant
  #     row — the second across orgs, on purpose. Reachability of an exec space
  #     by a mentioned bystander is a shipped feature, so it is not this
  #     ticket's leak to close. If it should be narrowed, that is a separate
  #     decision about the pin-propagation rule, not a scope check bolted on
  #     here.
  #
  # That leaves `dm`, `group`, `meeting` and `guest_meeting` requiring
  # membership that already exists — and each has an explicit join seam that
  # creates it: `Chat.find_or_create_dm/4` for a DM the user actually starts,
  # and `Meetings.Membership.ensure_chat_space_participant/3` off the meeting
  # join lifecycle. Closing the implicit path removes a bypass around those
  # seams; it does not remove the only way in.
  @implicitly_joinable_kinds ~w(channel system execution)

  # EXTERNAL sessions are adjudicated by `external_space_denied?/2` and its
  # per-org DM allowlist, which admits a DM the external user has no
  # participant row in yet (`ExternalScope.authorized_space?/2` — admission is
  # deliberately WIDER than the read scope). Running the internal membership
  # rule on top of it would veto that allowlist and re-break the surface task
  # 01a011ed built, so this gate declines to answer for them.
  defp implicit_join_denied?(socket, space) do
    not external_session?(socket) and internal_join_denied?(socket, space)
  end

  defp internal_join_denied?(_socket, %{kind: kind})
       when kind in @implicitly_joinable_kinds,
       do: false

  defp internal_join_denied?(socket, %{id: space_id}) do
    not space_member?(space_id, socket.assigns[:user_id])
  end

  # Membership as `ensure_participant/2` itself defines it: ANY participant row
  # for this user, `left_at` included. A user who left a DM keeps their row and
  # so keeps their way back in — `maybe_reopen_dm/2` in the success branch is
  # built on exactly that, and tightening it here would silently change the
  # re-entry behaviour of a conversation the user was legitimately part of.
  # That is a different question from this ticket's.
  defp space_member?(space_id, user_id) when is_binary(space_id) and is_binary(user_id) do
    space_id
    |> Chat.list_participants()
    |> Enum.any?(fn p -> p.participant_type == "user" and p.participant_id == user_id end)
  end

  # No user id (anonymous / pre-membership mount) is not a member of anything.
  defp space_member?(_space_id, _user_id), do: false

  # Is this an EXTERNAL session? Two sources, because the two surfaces derive
  # externality differently and the difference is load-bearing.
  #
  #   * Standalone: `do_mount/3` already derived `@external?` from IDENTITY via
  #     `ExternalScope.for_user/1`. Reuse it, so an internal nav short-circuits
  #     on an assign with no query and the internal `handle_params/3` path keeps
  #     its exact query profile.
  #   * Embedded: `do_mount/3` hard-codes `external_scope = nil`, and therefore
  #     `@external? = false`, for EVERY embedded session — internal or not. That
  #     assign is a RENDER decision (the meeting pane paints no rail and must
  #     never show external chrome). Reusing it as the gate would leave the
  #     embedded gate unable to fire for the only user it exists to stop, so ask
  #     identity instead: one `Repo.exists?`, once per pane mount.
  #
  # An INVITED external user reaching the pane is unaffected:
  # `Meetings.invite_external_user/3` seats the invitee in
  # `meeting.chat_space_id`, so `authorized_space?/2` finds their participant
  # row. Token guests never reach here at all — the chat panel is `@shell?`
  # gated and the guest surface has none.
  defp external_session?(%{assigns: %{embedded: true}} = socket),
    do: Platform.Tenancy.external_user?(%{id: socket.assigns.user_id})

  defp external_session?(socket), do: socket.assigns.external?

  defp maybe_put_org_id(attrs, nil), do: attrs
  defp maybe_put_org_id(attrs, org_id), do: Map.put(attrs, :org_id, org_id)

  # Platform.UUID.valid?/1, NOT a bare Ecto.UUID.cast/1. :522 and :589 pass the
  # ORIGINAL `slug_or_id` — the `/chat/:slug` URL PATH SEGMENT — to
  # `Chat.get_space/1` when this returns true. A bare cast accepts any 16-byte
  # binary, so a 16-character channel slug cleared the guard and raised inside
  # `Repo` on the mount path. Same live failure as external_user_scope.ex; the
  # PR #613 family. Do not "simplify" this back to a bare cast.
  defp valid_uuid?(string), do: Platform.UUID.valid?(string)

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

  # Screen-share name masking (task 01a00c66 stage 5).
  #
  # The browser tab is the surface that most needs this and was the last to get
  # it. A rail reading `Workspace B` next to a tab reading `# wayne-tech` has not
  # masked anything — worse, it gives the presenter false confidence. The tab
  # also survives WINDOW-share mode, where the rail may not be captured at all,
  # so it is the one surface that can leak on a share that shows nothing else.
  #
  # `mask` is the `{context, sections}` pair from `space_mask/1`. Only the
  # CHANNEL clause masks: a DM or group title is a person's name, which this
  # feature does not claim to cover.
  defp space_page_title(%{kind: "channel", name: name}, _participants, _user_id, mask) do
    "# #{mask_space_name(mask, name)}"
  end

  defp space_page_title(space, participants, user_id, _mask) do
    Chat.display_name_for_space(space, participants, user_id)
  end

  @doc false
  # The `{context, sections}` pair every out-of-rail surface masks a channel
  # name through. Derived from `assigns` rather than threaded as a variable
  # BECAUSE the surfaces are scattered: the tab title, both breakpoints of the
  # chat header, the composer placeholder and the mobile pills strip are five
  # sites in three scopes, and a threaded variable is how the fifth one gets
  # missed. Taking `assigns` means a new site is one call, not one call plus a
  # `<% %>` binding someone has to remember to add.
  def space_mask(assigns) do
    sections = assigns[:sidebar_sections] || []

    {Platform.Chat.SidebarMask.context(
       sections,
       assigns[:mask_names?] == true,
       assigns[:revealed_section_ids] || MapSet.new()
     ), sections}
  end

  @doc false
  # Mask one channel name for a surface that has no rail section in hand.
  def masked_space_name(assigns, name) when is_binary(name),
    do: mask_space_name(space_mask(assigns), name)

  def masked_space_name(_assigns, name), do: name

  # Re-derive the tab title after the mask mode or the reveal set changes.
  # Without this the title keeps whatever spelling it had when the channel was
  # opened, and turning masking ON leaves the real name in the tab — the exact
  # failure the mode is switched on to prevent.
  defp refresh_page_title(socket) do
    case socket.assigns[:active_space] do
      nil ->
        socket

      space ->
        assign(
          socket,
          :page_title,
          space_page_title(
            space,
            socket.assigns[:space_participants] || [],
            socket.assigns.user_id,
            space_mask(socket.assigns)
          )
        )
    end
  end

  defp clear_unread(socket, space_id) do
    update(socket, :unread_counts, &Map.delete(&1, space_id))
  end

  # ADR 0027: default_attention_mode/1 and default_attention_label/1 removed
  # (agent_attention field no longer exists on Space)

  # ADR 0038: participant rows represent current membership only — no
  # soft-delete to reconcile. If the user is in the space they get their
  # existing row; otherwise a fresh row is inserted.
  # Task 019e95ea stage 2: UI mirror of the context-layer archive/unarchive
  # authorization (root-org admin or space creator). Affordance only — the real
  # gate is `with_space_lifecycle_authz/3` inside `Chat.unarchive_space/2`.
  defp can_unarchive?(space, user_id) do
    Platform.Tenancy.root_admin?(%{id: user_id}) or space.created_by == user_id
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

  # `format_message_date/1` was deleted here in task 01a01041 stage 2. Dead
  # after the day-divider refactor, not a call that went missing: the
  # "Today" / "Yesterday" / `%a, %b %-d` labelling of a message day-bucket now
  # lives in the component that renders the divider,
  # `PlatformWeb.Components.ChatMessage` (chat_message.ex:745), which is what
  # the templates call. This copy had no caller in `lib/` or `test/` and was
  # the stale duplicate of the two.

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
  #         "Root Org" => [Space.t()],    # the root org's own name: catch-all for anything unmatched
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
  #   3. Channel's `org_id` resolves to an org → that org's bucket.
  #   4. Anything else (`org_id: nil`, or an org that no longer exists) →
  #      the root org's own `name`, read from its row; `Channels` when the
  #      install has no root row. See `default_bucket/1`.
  #
  # Sub-org bucket keys are stable string keys; the map preserves a key for
  # EVERY org even when the bucket is empty, so the template can render
  # section headers without conditionals. Alphabetical render order is the
  # template's responsibility (`sub_org_order/0`).
  #
  # Post-MT/RBAC seam: CLOSED by task 01a00910 stage 3. `channel_scope/2` now
  # resolves the channel's `org_id` through `org_bucket_index/0`, a single read
  # of `Platform.Tenancy.list_orgs/0` per `channel_sections/5` call. The old
  # `@sub_org_slug_to_bucket` / `@sub_org_buckets` module attributes matched the
  # CHANNEL's own slug against a hardcoded six-org list and are DELETED — they
  # were two of four hardcoded org lists that had already drifted apart (the
  # bucket list was missing Cyberdyne while the three sibling maps had it).
  # Do not reintroduce a literal org list here: a new org must need no code
  # change to appear. The historical comment naming `Platform.Orgs` was stale;
  # that module never existed. The real API is `Platform.Tenancy`.
  #
  # `pinned_space_ids` is the user's ordered pin list from
  # `Sidebar.list_pinned_space_ids/1` (task 019fd80f). It covers CHANNELS AND
  # DMs: both are `chat_spaces` rows and the Pinned block holds them in one
  # flat list, ordered by when the user pinned them. A `MapSet` is also
  # accepted, in which case the block falls back to input order.
  # The bucket a channel lands in when its `org_id` is nil (personal / unscoped
  # spaces) or names an org that no longer exists: the ROOT org's own `name`,
  # read from the same `list_orgs/0` call as the other buckets, so it merges
  # with the root's org bucket (the `Enum.uniq/1` in `bucket_names/2`). When
  # there is no root row the literal below names the bucket. Pinned by
  # Fixture E in chat_live_section_grouping_test.exs (task 01a116de stage 3:
  # this used to be a compiled org name, which gave every install's rail a
  # section named after one client).
  @no_root_bucket "Channels"

  @doc """
  Group the user's channel + DM list into the sectioned-rail shape consumed
  by the chat sidebar (Stage 1 of chat plan v2).

  See module-level comment for the return shape, classification precedence,
  and the post-MT/RBAC migration seam (`channel_scope/1`).
  """
  @spec channel_sections(
          [Platform.Chat.Space.t()],
          [Platform.Chat.Space.t()],
          [String.t()] | MapSet.t(String.t()),
          MapSet.t(String.t()),
          %{optional(String.t()) => DateTime.t()}
        ) :: %{
          pinned: [Platform.Chat.Space.t()],
          dms: [Platform.Chat.Space.t()],
          sub_orgs: %{String.t() => [Platform.Chat.Space.t()]},
          hidden_sub_orgs: %{String.t() => [Platform.Chat.Space.t()]},
          bucket_orgs: %{String.t() => bucket_org()}
        }
  def channel_sections(
        channels,
        dm_conversations,
        pinned_space_ids \\ MapSet.new(),
        hidden_channel_ids \\ MapSet.new(),
        closed_dm_at \\ %{}
      )
      when is_list(channels) and is_list(dm_conversations) do
    # Three partitions rather than one, because the block is a single list
    # ordered by pin time across BOTH kinds while the two leftovers go to
    # different places. Partitioning the concatenation gives the block its
    # cross-kind order; the two narrow passes give each home section its
    # remainder. Lists here are tens of rows, so the extra passes are free.
    {pinned, _} = PinnedSpaces.partition(channels ++ dm_conversations, pinned_space_ids)
    {_, unpinned_channels} = PinnedSpaces.partition(channels, pinned_space_ids)
    {_, unpinned_dms} = PinnedSpaces.partition(dm_conversations, pinned_space_ids)

    # ONE org read per call, hoisted out of the per-channel reduce below.
    # `channel_sections/5` has 11+ call sites and fires on every sidebar
    # recompute; a `Tenancy.get_org/1` inside the loop would be one query per
    # channel per render. Same shape as `Sidebar.place_channels/4`, which
    # builds its `org_to_section` index once (sidebar.ex:484).
    #
    # The same read also yields `bucket_orgs` (task 01a0938b stage 1): the org
    # ROW behind each bucket, so the rail can render a bucket's scope pill from
    # the org's slug and name instead of a closed map keyed on six display
    # names. Do NOT add a second `list_orgs/0` call for it.
    {org_buckets, bucket_orgs, default_bucket} = org_indexes()
    empty_buckets = Map.new(bucket_names(org_buckets, default_bucket), fn name -> {name, []} end)

    sub_orgs =
      unpinned_channels
      |> Enum.reduce(empty_buckets, fn channel, acc ->
        bucket = channel_scope(channel, org_buckets, default_bucket)
        Map.update(acc, bucket, [channel], fn existing -> existing ++ [channel] end)
      end)

    # Drop hidden ids from sub-org buckets and DMs (Pinned is non-hideable
    # per Stage 2 plan — pinned stays whole as defense-in-depth even if a
    # pinned channel id somehow ended up in the user's hidden set).
    # Stage 3: also expose the per-bucket hidden list under `hidden_sub_orgs`
    # so the header `Hidden (N)` chip and the inline unhide list can render
    # without re-doing the bucketing/filter in the template.
    #
    # The hidden filter runs on the UNPINNED DM remainder, so a pinned DM has
    # already left this bucket. Lifting happens before hiding for the same
    # reason it does for channels: the block is the conversation's one place.
    {visible_dms, _hidden_dms} = HiddenChannels.filter(unpinned_dms, hidden_channel_ids)

    # The DM Close action (task 019ffc5f), applied to the SAME remainder and
    # for the same reason: a pinned DM has already left this bucket, and the
    # Pinned block is the conversation's one place.
    #
    # `ClosedDms.filter/2` is a timestamp comparison, not a set membership —
    # a closed DM whose `last_activity_at` is newer than the stored close has
    # already earned its way back and never reaches the closed half. That is
    # the whole reason Close needs no drawer to reverse it, unlike Hide.
    {open_dms, _closed_dms} = ClosedDms.filter(visible_dms, closed_dm_at)

    bucketed =
      Map.new(sub_orgs, fn {bucket, spaces} ->
        {visible, hidden} = HiddenChannels.filter(spaces, hidden_channel_ids)
        {bucket, %{visible: visible, hidden: hidden}}
      end)

    visible_sub_orgs = Map.new(bucketed, fn {bucket, %{visible: v}} -> {bucket, v} end)
    hidden_sub_orgs = Map.new(bucketed, fn {bucket, %{hidden: h}} -> {bucket, h} end)

    %{
      pinned: pinned,
      dms: open_dms,
      sub_orgs: visible_sub_orgs,
      hidden_sub_orgs: hidden_sub_orgs,
      bucket_orgs: bucket_orgs
    }
  end

  # ── The Pinned block: one list, three kinds of row ─────────────────────
  #
  # The rail used to carry two adjacent pinned blocks — "Pinned Channels"
  # from `channel_sections/4` and "Pinned Tasks" from `@pinned_task_spaces`.
  # Marlowe pinned a task from the Tasks page, went to Chat, and found its
  # execution log in her rail: pinning a task is the same act as pinning a
  # channel, so it is one need and one block.
  #
  # This is the READ-layer union and the only one there will be. The two
  # storage tables stay separate: a backlog task has no space to key on
  # (`ExecutionSpace.find_or_create/1` materialises lazily and most tasks
  # never reach it), and a channel has no task to key on, so neither table
  # can represent the other's rows.
  #
  # Entries carry their own `kind` so the template branches on a field
  # rather than on which assign a row arrived in. That is what keeps the
  # three row shapes from drifting apart again: there is one loop.
  #
  # Called from the template rather than held as an assign, deliberately.
  # `@channel_sections` and `@pinned_task_spaces` are recomputed at five
  # separate sites (mount, `handle_params`, `recompute_pinned/1`,
  # `refresh_pinned_task_spaces/1`, the space-created broadcast); a derived
  # assign would be a sixth thing each of them has to remember, and the
  # failure mode is a silently stale block. Deriving at render costs two
  # list walks over tens of rows.
  @typedoc """
  One row of the Pinned block, tagged with the kind of thing it is.

  `move_index` / `move_count` describe the row's place among the rows it may
  be REORDERED among, which is the conversation half only: a task row carries
  `move_index: nil` and renders no reorder chrome (Marlowe, 2026-08-12). A
  conversation carries its 0-based index within the conversation run and the
  run's length, which is what disables the ▲ on the first conversation and
  the ▼ on the last. Indexing against the whole block instead would disable
  the ▲ on a conversation that has task rows above it but is the top of what
  it can actually move within.

  Annotated here rather than in the template so the desktop rail and the
  mobile drawer read the same numbers from one place; the previous stage on
  this stack shipped rail-only chrome and left the drawer broken.
  """
  @type pinned_entry :: %{
          kind: :channel | :dm | :task,
          space: Platform.Chat.Space.t(),
          move_index: non_neg_integer() | nil,
          move_count: non_neg_integer()
        }

  @doc """
  The Pinned block as ONE ordered list of `%{kind:, space:}` entries.

  Tasks sit at the TOP (Marlowe, 2026-08-11): "if I'm working on a task and I
  deliberately pin, I would want to have that as easiest to access while I'm
  on the go / on my phone." It also makes this list agree with the mobile
  chip strip, which already iterates `@pinned_task_spaces` before
  `@channel_sections.pinned`.

  The two halves cannot be INTERLEAVED, and now they are not meant to be.
  Marlowe, 2026-08-12, choosing between commingling the two pin models and
  keeping them apart: "I lean towards #2 — it's essentially two separate
  lists so makes me think to not commingle the interactions too much." Task
  rows keep their own ordering and are not hand-orderable; hand-ordering
  applies only to the conversations below them. That also means no
  cross-table reorder has to be defined at all: task pins live in
  `task_chat_pins`, conversation pins in the `chat_pinned_spaces`
  preference.

  ## The conversation half renders in STORED order

  It used to render `Enum.reverse/1` of the stored list, because pins are
  stored append-ordered (most-recently-pinned LAST) and the block wanted to
  read newest-first. Hand-ordering ends that: once the user sets an order,
  "newest first" and "the order you dragged it into" are the same list
  asked to be two different things, and a reversing render would display a
  hand-set order backwards from how it is stored.

  So the reverse is gone and rendered order IS stored order. The
  consequence, stated rather than discovered: a newly pinned conversation
  APPENDS, so it arrives at the bottom of the conversation half instead of
  the top, and the user drags it up if they want it there.

  `Sidebar.set_space_pinned/3` keeps its append contract untouched. Making
  it prepend would restore newest-first for NEW pins only — existing stored
  lists stay append-ordered and there is no migration — so it would buy a
  half-fix for a rewrite of that function's stated contract and 25 test
  assertions.

  A user with existing pinned conversations sees that half flip order once,
  on first load. No data is lost and there is no migration.

  The reflow that costs is accepted, not overlooked. A task row removes
  itself when its task hits done or cancelled, so every conversation row
  below it shifts up. Marlowe's call: the row gets no animation, no
  placeholder and no notice.
  """
  @spec pinned_rail_entries([Platform.Chat.Space.t()], [Platform.Chat.Space.t()]) ::
          [pinned_entry()]
  def pinned_rail_entries(pinned_conversations, pinned_task_spaces)
      when is_list(pinned_conversations) and is_list(pinned_task_spaces) do
    move_count = length(pinned_conversations)

    conversations =
      pinned_conversations
      |> Enum.with_index()
      |> Enum.map(fn {space, index} ->
        %{
          kind: conversation_pin_kind(space),
          space: space,
          move_index: index,
          move_count: move_count
        }
      end)

    tasks =
      Enum.map(pinned_task_spaces, fn space ->
        %{kind: :task, space: space, move_index: nil, move_count: move_count}
      end)

    tasks ++ conversations
  end

  @doc """
  The conversation half of the Pinned block, in RENDERED order.

  The drag and the ▲▼ buttons both resolve against this list, never against
  `@channel_sections.pinned` directly. Two reasons, and the second is the
  bug this function exists to prevent:

    * Task rows are in the block but are NOT hand-orderable (Marlowe,
      2026-08-12), so the baseline has to drop them or a conversation could
      be given a destination among them.

    * Rendered order and stored order have to be the SAME sequence for
      `pinned_destination_index/3` to anchor on the right neighbour. They
      are today, because `pinned_rail_entries/2` no longer reverses. Deriving
      the baseline from the render rather than from the stored assign means a
      reversing render can never again make a drag up persist as a move down
      — the two would move together.
  """
  @spec pinned_conversation_entries([Platform.Chat.Space.t()], [Platform.Chat.Space.t()]) ::
          [pinned_entry()]
  def pinned_conversation_entries(pinned_conversations, pinned_task_spaces) do
    pinned_conversations
    |> pinned_rail_entries(pinned_task_spaces)
    |> Enum.reject(&(&1.kind == :task))
  end

  # Tagged from the SOURCE list, not sniffed from the row: task entries can
  # only come from `@pinned_task_spaces`, so only the conversation half needs
  # a kind test at all.
  defp conversation_pin_kind(%{kind: kind}) when kind in ["dm", "group"], do: :dm
  defp conversation_pin_kind(_space), do: :channel

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
          MapSet.t(),
          map() | nil
        ) ::
          [Sidebar.resolved()]
  defp resolve_sidebar_sections(user_id, channels, hidden_ids, agents_block) do
    {visible_channels, _hidden} = HiddenChannels.filter(channels, hidden_ids)

    # The pin exclusion is read HERE rather than threaded in as a fourth
    # argument, and that is deliberate. The client sections render from this
    # function while the Pinned block renders from `channel_sections/4`, so a
    # pinned channel has to be removed in two places or it renders twice.
    # There are five call sites; taking the set from the user id means none
    # of them can forget to pass it, which is the failure mode that would
    # show up as a duplicated row with two unread pills.
    {_pinned, unpinned} =
      PinnedSpaces.partition(visible_channels, Sidebar.pinned_space_ids(user_id))

    # The agents-space exclusion (task 01a0ca8b) IS threaded in, the opposite
    # of the pin choice above, and that is deliberate too. It must exclude
    # exactly the space the rail block renders from `@agents_block` in this
    # process, so it keys on that assign rather than re-querying: a fresh
    # query could disagree with a stale block and drop the channel from BOTH
    # places. The arity makes a call site that forgets it a compile error.
    # `nil` (flag off, or no goal anywhere) leaves the list untouched.
    unpinned = Sidebar.reject_agents_space(unpinned, agents_block)

    Sidebar.resolve_for_user(user_id, unpinned)
  end

  # Re-assign `@agents_block` AND recompute the org list from the NEW block
  # (task 01a0ca8b). The two move together: without the recompute, saving a
  # goal leaves the space listed under its org beside the block, and clearing
  # one leaves it missing from both until some unrelated recompute.
  defp assign_agents_block(socket, agents_block) do
    socket
    |> assign(:agents_block, agents_block)
    |> recompute_sidebar()
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
  def section_scope_atom("wayne-tech"), do: :wayne_tech
  def section_scope_atom("sxi"), do: :sxi
  def section_scope_atom("cyberdyne"), do: :cyberdyne
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
  def section_dot_class("wayne-tech"), do: "bg-wayne-tech-dot"
  def section_dot_class("sxi"), do: "bg-sxi-dot"
  def section_dot_class("cyberdyne"), do: "bg-cyberdyne-dot"
  def section_dot_class(_), do: nil

  # ── The one org index (task 01a00910 stage 3) ──────────────────────────
  #
  # SOURCE OF TRUTH for sub-org bucketing is the orgs table, reached through
  # `Platform.Tenancy`'s public surface — the same context `space_scope_atom/1`
  # already reads for the header pill, so the rail, the drawer and the pill can
  # never disagree about which org a channel belongs to.
  #
  # `org_bucket_index/0` is `org_id => display name`. `bucket_slug_index/0` is
  # the CSS-token form of the org slug => the same display name. Org slugs are
  # stored UNDERSCORE-form (`wayne_tech`); section colour tokens and CSS classes
  # are HYPHEN-form (`wayne-tech`), so every lookup normalizes `_` -> `-` at the
  # boundary. Skipping that replace misses on exactly one org, which reads as
  # "works for five, mysteriously broken for the sixth".
  @spec org_bucket_index() :: %{binary() => String.t()}
  defp org_bucket_index do
    {org_buckets, _bucket_orgs, _default_bucket} = org_indexes()
    org_buckets
  end

  # What `channel_sections/5` knows about the org behind a bucket. `scope` is
  # the value `scope_pill`'s `scope` attr takes — see `org_scope/1`.
  @type bucket_org :: %{slug: String.t(), name: String.t(), scope: atom() | String.t()}

  # BOTH org indexes, and the default bucket, from ONE `Tenancy.list_orgs/0`
  # read:
  #
  #   * `org_buckets` — `org_id => display name`, what a channel buckets by.
  #   * `bucket_orgs` — `display name => bucket_org()`, the row behind each
  #     bucket, so a bucket's pill reads the org's slug and name rather than
  #     a closed name-keyed map (task 01a0938b stage 1).
  #   * `default_bucket` — the root org's own `name` (structural:
  #     `parent_org_id` is nil), or `@no_root_bucket` when there is none.
  #
  # Keyed by name because the bucket key IS the name. Two orgs sharing a name
  # already share a bucket in `org_buckets`; `bucket_orgs` inherits that
  # collision rather than introducing a new one.
  @spec org_indexes() ::
          {%{binary() => String.t()}, %{String.t() => bucket_org()}, String.t()}
  defp org_indexes do
    orgs = Platform.Tenancy.list_orgs()

    {
      Map.new(orgs, fn org -> {org.id, org.name} end),
      Map.new(orgs, fn org -> {org.name, bucket_org(org)} end),
      default_bucket(orgs)
    }
  end

  @doc false
  # The root org's own name off its row, else `@no_root_bucket`. Public for
  # the grouping tests; never a compiled org name.
  @spec default_bucket([map()]) :: String.t()
  def default_bucket(orgs) do
    Enum.find_value(orgs, @no_root_bucket, fn
      %{parent_org_id: nil, name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end)
  end

  defp bucket_org(org), do: %{slug: org.slug, name: org.name, scope: org_scope(org.slug)}

  @doc false
  # An org slug -> the value `scope_pill`'s `scope` attr takes (task 01a0938b
  # stage 1). The six shipped slugs keep their existing atoms; every other org
  # gets its slug BINARY AS STORED (`"new_client"`).
  #
  # Why not a binary for all of them: `@scope_filter` holds atoms (the
  # `parse_scope/1` whitelist) and the header computes
  # `active={@scope_filter == header_scope}`, so turning the six into binaries
  # would silently break their active-filter state.
  #
  # NEVER `String.to_atom/1` / `String.to_existing_atom/1` a slug here: slugs
  # are runtime data, and the atom table is not garbage-collected.
  #
  # KNOWN LIMITATION: filtering BY a runtime org is out of scope. Its pill is
  # clickable, `parse_scope/1` returns nil for its slug, and the scope_filter
  # handler therefore clears any filter rather than applying one.
  @spec org_scope(String.t() | nil) :: atom() | String.t() | nil
  def org_scope(slug) when is_binary(slug) do
    section_scope_atom(css_slug(slug)) || slug
  end

  def org_scope(_), do: nil

  # The org destinations the "+ New channel" dialog offers (task 01a00910
  # stage 5). Two reads, and the split is deliberate:
  #
  #   * WHICH orgs — `Tenancy.list_active_tenants_for_user/1`, the
  #     viewer-scoped read. A picker is a user-facing surface that renders org
  #     NAMES, and the unscoped reads carry an explicit warning that doing so
  #     discloses the existence and name of orgs the viewer isn't in. Archived
  #     orgs are excluded there too, matching `org_archived?/1`'s refusal on
  #     the "Move to organisation…" path.
  #   * WHAT THEY ARE CALLED — `org_bucket_index/0`, the one org index the rail
  #     buckets by. Labelling from the same map is what stops the dialog and
  #     the rail from disagreeing about an org's name.
  @spec new_channel_org_options(binary() | nil) :: [%{id: binary(), name: String.t()}]
  defp new_channel_org_options(user_id) when is_binary(user_id) do
    names = org_bucket_index()

    %{id: user_id}
    |> Platform.Tenancy.list_active_tenants_for_user()
    |> Enum.map(&%{id: &1.id, name: Map.get(names, &1.id, &1.name)})
  end

  defp new_channel_org_options(_user_id), do: []

  @spec bucket_slug_index() :: %{String.t() => String.t()}
  defp bucket_slug_index do
    Platform.Tenancy.list_orgs()
    |> Map.new(fn org -> {css_slug(org.slug), org.name} end)
  end

  defp css_slug(slug) when is_binary(slug),
    do: slug |> String.downcase() |> String.replace("_", "-")

  defp css_slug(_), do: nil

  # Every bucket key the rail can render: one per org, plus the default bucket
  # so the `org_id: nil` fallback always has somewhere to land even on an
  # install with no root row. With a root row the default IS the root's name,
  # so the two merge here.
  @spec bucket_names(%{binary() => String.t()}, String.t()) :: [String.t()]
  defp bucket_names(org_buckets, default_bucket) do
    org_buckets
    |> Map.values()
    |> then(&[default_bucket | &1])
    |> Enum.uniq()
  end

  # Bucket a channel by the org it actually belongs to. Takes the pre-built
  # index rather than reading the DB — see the hoist in `channel_sections/5`.
  defp channel_scope(%{org_id: org_id}, org_buckets, default_bucket) when is_binary(org_id) do
    # An org_id naming an org that no longer exists takes the same explicit
    # fallback as a nil one, below.
    Map.get(org_buckets, org_id, default_bucket)
  end

  # DELIBERATE, not a catch-all fall-through: a space with no org (personal
  # spaces, DMs that reached this path, anything unscoped) keeps landing in the
  # root org's bucket, which is exactly where it landed before this stage.
  # Fixture E in chat_live_section_grouping_test.exs pins this; if that test
  # changes, DM/personal behaviour was altered by accident.
  defp channel_scope(%{org_id: nil}, _org_buckets, default_bucket), do: default_bucket

  defp channel_scope(_channel, _org_buckets, default_bucket), do: default_bucket

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
  def sub_org_order do
    {org_buckets, _bucket_orgs, default_bucket} = org_indexes()
    org_buckets |> bucket_names(default_bucket) |> Enum.sort()
  end

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

  # Map a Space to the scope atom the `scope_pill` component takes.
  #
  # SOURCE OF TRUTH is the space's `org_id` (post-ADR-0042). We load the
  # owning org and map its slug to a scope atom — the SAME org the sidebar
  # rail buckets channels on (`Platform.Chat.Sidebar`), so the header pill and
  # the rail can never disagree about which org a channel belongs to.
  #
  # Do NOT go back to matching the *channel's own* slug here: that made every
  # channel whose name wasn't a literal org slug (e.g. "orion") fall through
  # to a compiled root-org default and mislabel its org (task 019fa0ac).
  #
  # Org slugs are stored underscore-form (`wayne_tech`); `section_scope_atom/1`
  # speaks the CSS-token form (`wayne-tech`), so normalize `_` -> `-` at the
  # boundary. DMs/groups (`kind in ["dm", "group"]`) and any space whose org
  # can't be resolved return `nil`, so the caller suppresses the pill rather
  # than showing a wrong one.
  #
  # Resolved at assign time only (see `assign_active_space/2`) — never inline
  # in the template — because `Platform.Tenancy.get_org/1` is a DB read and the
  # chat header re-renders on every message.
  #
  # Task 01a0938b stage 1: the slug goes through `org_scope/1`, not straight
  # into `section_scope_atom/1`, so a runtime-created org yields its slug
  # binary instead of nil (the six shipped orgs keep their atoms).
  @doc false
  @spec space_scope_atom(map() | nil) :: atom() | String.t() | nil
  def space_scope_atom(space), do: space |> space_org() |> org_scope_of()

  # The org row a space belongs to, or nil for DMs/groups and any space whose
  # org can't be resolved. The ONE `Tenancy.get_org/1` read behind both
  # `@active_space_scope` and `@active_space_org`.
  @spec space_org(map() | nil) :: Platform.Tenancy.Org.t() | nil
  defp space_org(%{kind: kind}) when kind in ["dm", "group"], do: nil

  defp space_org(%{org_id: org_id}) when is_binary(org_id) do
    case Platform.Tenancy.get_org(org_id) do
      %{slug: slug} = org when is_binary(slug) -> org
      _ -> nil
    end
  end

  defp space_org(_), do: nil

  defp org_scope_of(%{slug: slug}), do: org_scope(slug)
  defp org_scope_of(_), do: nil

  defp active_org_summary(%{slug: slug, name: name}), do: %{slug: slug, name: name}
  defp active_org_summary(_), do: nil

  # Assign the active space AND its resolved org scope atom together. Every
  # write to `:active_space` MUST go through here so `@active_space_scope`
  # (read by the header pill) can never drift from the space it labels — the
  # drift between the slug-guessing header and the org_id-driven rail is
  # exactly what caused task 019fa0ac. `nil` space -> `nil` scope.
  @spec assign_active_space(Phoenix.LiveView.Socket.t(), map() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp assign_active_space(socket, space) do
    # One org read feeds both the pill's scope and the org it names (task
    # 01a0938b stage 1). `@active_space_org` (`%{slug, name}` or nil) is what
    # the header labels the pill with, so it rides this funnel for the same
    # reason the scope does: it must never describe a space no longer open.
    org = space_org(space)

    socket
    |> assign(:active_space, space)
    |> assign(:active_space_scope, org_scope_of(org))
    # Whether the New canvas form offers Prototype: the install switch and
    # publish policy for THIS space's org, so it rides the space funnel.
    |> assign(
      :can_publish_prototype?,
      PrototypeUpload.allowed?(space, Map.get(socket.assigns, :user_id))
    )
    |> assign(:active_space_org, active_org_summary(org))
    # The agents goal panel (task 01a0b491 stage 4) rides the SAME funnel as
    # the scope atom and for the same reason: it is derived from the space,
    # and a second write path is how it would come to describe a space that
    # is no longer open. `goal_panel/1` returns nil when the feature flag is
    # off, so with the flag unset this is an unconditional nil.
    #
    # The edit form closes on every space change. An edit box left open over
    # a different space's goal would save this space's text onto that one.
    |> assign(:goal_panel, Sidebar.goal_panel(space))
    |> assign(:goal_edit, false)
    |> assign(:goal_cadence_form, nil)
    |> assign(:goal_scope_options, [])
    |> assign(:goal_scope_error, nil)
    # `and` short-circuits: non-admins never run the predicate's query.
    |> assign(
      :goal_invite?,
      Map.get(socket.assigns, :can_edit_goal?, false) and Sidebar.first_goal_offered?(space)
    )
    # A new conversation starts at its own tip: this state is about the space
    # you are leaving, so carrying it across would show a stale pill in the
    # space you just opened (task 01a03c76 stage 1).
    #
    # BOTH position booleans are reset too (task 01a0419a stage 4). Zeroing
    # the count alone used to be enough because visibility was
    # `@jump_away_from_bottom` and the hook re-reports within ~110ms of the
    # patch, so at worst a countless pill flickered. Now `:jump_deep_in_history`
    # makes the control visible ON ITS OWN, so a reader deep in space A who
    # switches to space B would see a pill for B's tip — a control offering to
    # take them somewhere they already are — until the hook caught up. Reset
    # here rather than trusting the round trip.
    |> assign(:jump_away_from_bottom, false)
    |> assign(:jump_deep_in_history, false)
    |> assign(:jump_new_message_count, 0)
  end

  # The URL nav target for a space link. Behaviour is unchanged; the RULE now
  # lives in ONE place — `Platform.Chat.space_path_segment/1` — because the web
  # layer and the context layer had already drifted: this function routed
  # org-scoped spaces by ID while the @mention inbox producer (chat.ex) built
  # its url from `space.slug` raw, so DM/group mentions emitted "/chat/" and
  # resolved to the reader's first channel (task 019fabe8 stage 4).
  #
  # Kept as a public web-layer alias — templates and components already call
  # `PlatformWeb.ChatLive.space_nav_target/1` (settings_component.ex:122/:235,
  # new_channel_component.ex:46, ~20 call sites in chat_live.html.heex) and
  # renaming them buys nothing. Do NOT reimplement the rule here.
  @doc false
  @spec space_nav_target(map()) :: String.t()
  def space_nav_target(space), do: Chat.space_path_segment(space)

  # Parse the inbound `scope_filter` payload's string scope name back into
  # an atom. Returns nil for any value not in the canonical scope set so
  # a stale/malformed client payload silently clears the filter rather than
  # crashing the LV. Whitelist (no String.to_existing_atom) keeps the surface
  # impervious to atom-table flooding.
  @doc false
  @spec parse_scope(String.t()) :: atom() | nil
  def parse_scope("paragon"), do: :paragon
  def parse_scope("soylent"), do: :soylent
  def parse_scope("wayne_tech"), do: :wayne_tech
  def parse_scope("sxi"), do: :sxi
  def parse_scope("cyberdyne"), do: :cyberdyne
  def parse_scope(_), do: nil

  # `section_slug/1` (bucket-name → slug) was retired in Stage 4: the
  # resolver-driven rail sets `data-section-slug` directly from a section's
  # `color` token (already in CSS slug form, e.g. "wayne-tech"), so the
  # name→slug mapping is no longer needed. Its inverse `bucket_from_slug/1`
  # is kept below — the Stage 3 `section_reordered` handler still translates
  # the JS hook's slug payload back to the section name.

  # `bucket_from_slug/1`: translates the SectionReorder hook's slug payload
  # back to the bucket display name used by the `section_reordered` handler.
  # Task 01a00910 stage 3: reads `bucket_slug_index/0` — the SAME orgs-table
  # read `channel_scope/2` buckets on — instead of the deleted
  # `@sub_org_slug_to_bucket` attribute. This was the second consumer of that
  # map (the architecture review flagged it); leaving it behind would have kept
  # the stale hardcoded list alive in the reorder path while the tests went
  # green on the bucketing path.
  @doc false
  @spec bucket_from_slug(String.t()) :: String.t() | nil
  def bucket_from_slug(slug) when is_binary(slug) do
    Map.get(bucket_slug_index(), css_slug(slug))
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

  # ── Check progress cadence (task 01a0e882 stage 3) ─────────────────────────
  # The logic lives in `GoalCadenceForm`; this only maps its refusal to a flash.
  defp maybe_save_goal_cadence(socket, params) do
    %{goal_panel: panel, goal_cadence_form: form, goal_time_zone: zone, user_id: id} =
      socket.assigns

    case GoalCadenceForm.save(%{id: id}, panel, form, zone, params) do
      :ok -> socket
      {:error, message} -> put_flash(socket, :error, message)
    end
  end
end
