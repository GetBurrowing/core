defmodule PlatformWeb.ChatLive.MeetingHooks do
  @moduledoc """
  Lifecycle hook for the Meeting feature in `PlatformWeb.ChatLive`.

  See ADR 0035. This module owns the LIVE meeting path that uses
  `MeetingClient` (client-side LiveKit) + `MeetingState` broadcasts.

  ## Historical context

  ChatLive briefly hosted two parallel meeting UIs — `@in_meeting` (this
  one, the live path) and `@meeting_active` (an earlier DB-participant
  model that was never fully wired up and whose broadcast path had no
  real-world trigger). The dead path is gone — this module is the
  single source of truth.

  ## Assigns owned

    * `:in_meeting` — user is actively in the LiveKit room
    * `:meetings_enabled` — feature flag from `Platform.Meetings.enabled?/0`
    * `:mic_enabled`, `:camera_enabled`, `:screen_share_enabled` — local
      media state mirrored from the MeetingClient JS hook
    * `:meeting_counts` — sidebar badges (space_id → participant count)
    * `:quickmeet_meeting_id` / `:quickmeet_meeting` — the joined
      meeting, set on a successful quickmeet join and cleared on leave.
      Before task 01a05b14 stage 6 this module assigned NO meeting id at
      all, which is why the quickmeet panel could not render a rail: not
      because the markup was missing, but because there was nothing to
      read it from.
    * `:agent_activity` — `%Platform.Meetings.AgentActivity{}`, hydrated
      at join and folded from `{:agent_activity, …}` on the meeting
      shell topic
    * `:agents_by_id`, `:meeting_candidates`,
      `:meeting_candidates_closed`, `:meeting_candidate_events`,
      `:candidate_error` — the rail's People and Canvas panes
    * `:active_meeting_tab`, `:quickmeet_rail_open` — rail tab and the
      `<lg` sheet's open state

  ## Events

    * `"meeting_join"` — ensure DB room, generate token, push_event to
      `MeetingClient` JS hook, broadcast via `MeetingState`
    * `"meeting_leave"` — broadcast via `MeetingState`, reset media
      state, push_event `"leave-meeting"` to the JS hook
    * `"meeting_left"` — from `meeting_client.js` on
      `RoomEvent.Disconnected` (same effect as `meeting_leave` but
      without the push_event)
    * `"meeting_toggle_mic"` / `"meeting_toggle_camera"` /
      `"meeting_toggle_screen_share"` — flip local state and push to JS
    * `"meeting_screen_share_state"` — from `MeetingShareButton` JS hook;
      mirrors the post-toggle screen-share enabled-state back to the
      server WITHOUT pushing another browser event (the hook ran the
      LiveKit work itself inside the click handler to keep the user-
      activation flag alive for `getDisplayMedia`).

  ## Info handled

    * `{:meeting_presence_update, %{space_id, active, count}}` — update
      sidebar count map
    * `{:meeting_presence_summary, %{space_id}}` — refresh full
      `meeting_counts` from DB

  ## Usage

      # In ChatLive.mount/3, when connected?(socket):
      socket = PlatformWeb.ChatLive.MeetingHooks.attach(socket, all_space_ids)

      # In ChatLive.terminate/2:
      PlatformWeb.ChatLive.MeetingHooks.on_terminate(socket)
  """

  require Logger

  import Phoenix.Component, only: [assign: 3, assign_new: 3, update: 3]

  import Phoenix.LiveView,
    only: [
      attach_hook: 4,
      detach_hook: 3,
      push_event: 3,
      put_flash: 3,
      connected?: 1,
      get_connect_params: 1
    ]

  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.Membership, as: MeetingsMembership
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.Room
  alias Platform.Meetings.State, as: MeetingState
  alias Platform.Tenancy

  @doc """
  Attach Meeting handlers. Call from `ChatLive.mount/3`.

  If `space_ids` is non-empty, subscribes to per-space presence topics
  for the sidebar badges and eagerly loads the current counts.
  """
  @spec attach(Phoenix.LiveView.Socket.t(), [binary()]) :: Phoenix.LiveView.Socket.t()
  def attach(socket, space_ids \\ []) do
    socket =
      socket
      |> assign(:in_meeting, false)
      |> assign(:meetings_enabled, Meetings.enabled?())
      |> assign(:mic_enabled, true)
      |> assign(:camera_enabled, true)
      |> assign(:screen_share_enabled, false)
      |> assign(:meeting_counts, %{})
      |> assign(:meeting_participants, [])
      # `assign_new`, not `assign`: on `/meetings` this runs AFTER
      # `MeetingLive.mount` has already built both from the roster, and a
      # plain assign here blanked the People tab on first render.
      |> assign_new(:invite_rows, fn -> [] end)
      |> assign_new(:invitable_agents, fn -> [] end)
      |> assign_call_shell_defaults()
      |> attach_hook(:meeting_events, :handle_event, &handle_event/3)
      |> attach_hook(:meeting_info, :handle_info, &handle_info/2)

    socket = assign(socket, :meeting_reconnect?, reconnect_mount?(socket))

    # V3 fix (task 019ee06b): subscribe ChatLive's MeetingHooks to its own
    # user's `meeting:state:{user_id}` topic so bar-side toggles (which
    # broadcast `:meeting_media_state` here) update the chat-side
    # `:mic_enabled` / `:camera_enabled` assigns. Without this, only
    # ShellLive subscribed — ChatLive kept its initial defaults and the
    # next in-chat toggle click flipped against stale state (resulting in
    # the bar going dark, then bouncing back on the next bar tap).
    socket =
      if connected?(socket) do
        case socket.assigns[:user_id] do
          uid when is_binary(uid) -> MeetingState.subscribe(uid)
          _ -> :ok
        end

        socket
      else
        socket
      end

    if connected?(socket) and space_ids != [] do
      Enum.each(space_ids, &MeetingsPubSub.subscribe_presence/1)
      MeetingsPubSub.subscribe_presence_summary()

      assign(socket, :meeting_counts, Meetings.active_meeting_counts(space_ids))
    else
      socket
    end
  end

  # A reconnect mount is one LiveView has re-established after a transient
  # socket drop (Rowan's 1006). LiveView increments the `_mounts` connect
  # param on every reconnect, so `> 0` distinguishes a reconnect from a
  # fresh first mount. A first mount (`_mounts == 0` or absent, or a
  # disconnected/static render) must still require the explicit Join
  # button — only a reconnect auto-restores the user into the live meeting.
  defp reconnect_mount?(socket) do
    connected?(socket) and
      case get_connect_params(socket) do
        %{"_mounts" => mounts} when is_integer(mounts) -> mounts > 0
        _ -> false
      end
  end

  @doc """
  Attach a guest-flavored variant of the meeting event hook for the
  guest ingress path in `PlatformWeb.MeetingLive` (task 019f498d
  stage 3).

  The guest surface has `:user_id = nil` (no authenticated account).
  Calling the standard `attach/2` would install `handle_event/3`
  clauses whose leave paths call `MeetingState.broadcast_left/1` and
  `stamp_local_left/1` — both of which crash on a nil user_id
  (`broadcast_left/1` is `is_binary`-guarded; `stamp_local_left/1`
  requires a durable participant row to stamp). This variant installs
  the same media-toggle + screen-share + leave surface but skips the
  user_id-dependent side effects when `:user_id` is nil.

  Seeds the same media-state assigns `attach/2` seeds so the top-bar
  controls render with sane defaults — with `:in_meeting` deliberately
  `false` here; MeetingLive's guest mount flips it to `true` after the
  `join-meeting` push_event lands. Does NOT subscribe to
  `MeetingState.topic(user_id)` (there is no user_id), does NOT prime
  `:meeting_counts` from durable membership (the guest surface has no
  sidebar count map to feed), and does NOT install the `:meeting_info`
  handler (guest LV owns its own presence/canvas handlers via
  MeetingLive's `handle_info/2`).
  """
  @spec attach_guest(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach_guest(socket) do
    socket
    |> assign(:in_meeting, false)
    |> assign(:meetings_enabled, Meetings.enabled?())
    |> assign(:mic_enabled, true)
    |> assign(:camera_enabled, true)
    |> assign(:screen_share_enabled, false)
    |> assign(:meeting_counts, %{})
    |> assign(:meeting_participants, [])
    |> assign_new(:invite_rows, fn -> [] end)
    |> assign_new(:invitable_agents, fn -> [] end)
    |> assign_call_shell_defaults()
    # Idempotent hook install: the guest surface calls attach_guest/1
    # once at mount (`:name_entry` state seeds the shell tree) and again
    # on the `:name_entry → :in_meeting` transition (submit_name event).
    # `attach_hook/4` raises on duplicate id; detach first so both
    # entry points are safe to call.
    |> detach_hook(:meeting_events, :handle_event)
    |> attach_hook(:meeting_events, :handle_event, &handle_guest_event/3)
  end

  @doc """
  Release the three meetings-family topics the guest surface subscribed on
  entry (task `01a02c4e` stage 4), and clear the record.

  ## Which defect this closes, and which it does NOT

  Stage 1 MEASURED the `:guest_meeting` route and found it holds **zero**
  `chat:space:<id>` registrations — `ChatPubSub` is called exactly once in
  `meeting_live.ex`, from the `handle_params/3` `:show` body the guest never
  reaches (the guest mount clause seeds `:state` and the `:state`-guarded
  no-op returns first). So no `chat:space` hold was invented here to match
  the originating ticket's prose. Route B's real leak is the MEETINGS family
  taken by `MeetingLive.enter_guest_topics/2`:
  `MeetingsPubSub.subscribe_presence/1`, `subscribe_meeting/1` and
  `subscribe_room/1` — all three of which already ship a matching
  `unsubscribe_*`, so this needs no new PubSub API.

  ## Why release matters even though process death would clean up

  Two reasons, and only the second is about leaving:

    * **Re-entry.** `"submit_name"` re-enters `enter_meeting_as_guest/3`, so
      a guest who submits a name while already `:in_meeting` would subscribe
      a SECOND time on a live subscription. `Phoenix.PubSub` runs its
      registry `keys: :duplicate` and `subscribe/3` is a bare
      `Registry.register/3`, so that is a genuine duplicate registration and
      a doubled delivery — not an idempotent no-op.
    * **Explicit leave.** The guest's Leave button and the JS
      `RoomEvent.Disconnected` echo both land in `handle_guest_event/3`
      below, and the LiveView keeps running afterwards. Without this the
      process stays subscribed to a meeting it has left.

  Idempotent: `Phoenix.PubSub.unsubscribe/2` is `Registry.unregister/2`,
  which is `:ok` on a topic the pid never held. Safe on a socket that never
  entered (no `:guest_topic_subs`), which is why the fallthrough clause is a
  plain passthrough.
  """
  @spec release_guest_topics(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def release_guest_topics(socket) do
    case socket.assigns[:guest_topic_subs] do
      %{space_id: space_id, meeting_id: meeting_id} ->
        room_id = socket.assigns[:subscribed_room_id]

        if is_binary(space_id), do: MeetingsPubSub.unsubscribe_presence(space_id)
        if is_binary(meeting_id), do: MeetingsPubSub.unsubscribe_meeting(meeting_id)
        if is_binary(room_id), do: MeetingsPubSub.unsubscribe_room(room_id)

        socket
        |> assign(:guest_topic_subs, nil)
        |> assign(:subscribed_room_id, nil)

      _ ->
        socket
    end
  end

  @doc """
  Reconnect-aware meeting restore. Call from the host LiveView once the
  active space is established (`ChatLive.handle_params/3`), passing the
  active space struct.

  When this mount is a reconnect (`attach/1` recorded `:meeting_reconnect?`
  via the `_mounts` connect param) AND the user still has an active live
  participant row in the space's current meeting, we treat it as a
  reconnect-into-live-meeting: re-assign `:in_meeting=true` and re-push
  `join-meeting` via `do_join/1` so the JS hook (stage 1) adopts the
  surviving room or reconnects with a fresh token. A fresh first mount, or
  a user who is not in the meeting, is left untouched (still requires the
  explicit Join button).

  Idempotent: a no-op when already `:in_meeting`, when not a reconnect, or
  when no active participant row exists. The `:meeting_reconnect?` flag is
  consumed (cleared) after the first attempt so a later `handle_params`
  (space switch) does not re-trigger it.
  """
  @spec maybe_restore_on_reconnect(Phoenix.LiveView.Socket.t(), map() | nil) ::
          Phoenix.LiveView.Socket.t()
  def maybe_restore_on_reconnect(socket, space)

  def maybe_restore_on_reconnect(socket, %{id: space_id} = _space) do
    user_id = socket.assigns[:user_id]

    cond do
      socket.assigns[:meeting_reconnect?] != true ->
        socket

      socket.assigns[:in_meeting] ->
        assign(socket, :meeting_reconnect?, false)

      not is_binary(user_id) ->
        assign(socket, :meeting_reconnect?, false)

      Meetings.active_participant_for_user_in_space(space_id, user_id) ->
        socket
        |> assign(:meeting_reconnect?, false)
        |> do_join()

      true ->
        assign(socket, :meeting_reconnect?, false)
    end
  end

  def maybe_restore_on_reconnect(socket, _space), do: socket

  @doc """
  Clean up on LV termination.

  Task 019e4b3e stage 2: a LiveView process dying does NOT mean the user
  left the meeting. Phoenix tears the LV process down on a transient socket
  drop (Rowan's 1006), and the LiveKit room is now kept alive across that
  reconnect (stage 1). Broadcasting "left" here would evict a participant
  who is merely reconnecting — the exact "I'm not in the participant list"
  symptom for the reconnect case.

  The authoritative leave signal is the LiveKit `participant_left` webhook
  (wired in 8251a49) as a backup, plus the EXPLICIT `meeting_leave` /
  `meeting_left` event handlers which now STAMP `left_at` on the durable
  participant row server-side (v4 case-2 fix, see `stamp_local_left/1`) and
  broadcast "left". `on_terminate/1` does NEITHER — it must not stamp
  `left_at` (that would evict a merely-reconnecting participant) and must
  not broadcast. It is intentionally a no-op for the meeting path; only an
  explicit, user-initiated leave decrements the roster.
  """
  @spec on_terminate(Phoenix.LiveView.Socket.t()) :: :ok
  def on_terminate(_socket), do: :ok

  @doc """
  Programmatically trigger a meeting join from outside the hook's own
  `handle_event/3` path (e.g. an auto-join `handle_info/2` in
  `PlatformWeb.MeetingLive`). Mirrors the `"meeting_join"` event handler
  byte-for-byte — both call into this so the LiveKit lifecycle (token
  mint, JS-hook push_event, `MeetingState` broadcast) stays in one
  place.

  Returns the new socket.
  """
  @spec join(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def join(socket), do: do_join(socket)

  @doc """
  Reset every meeting-local assign — media state AND the call shell the
  quickmeet hydrated at join (task 01a05b14 stage 6).

  Public for the same reason `join/1` is: `"meeting_leave"` and
  `"meeting_left"` both funnel through it, and the teardown contract —
  notably that the `<lg` rail sheet comes back DOWN and the meeting
  topic is unsubscribed so a rejoin does not double-subscribe — is
  worth naming in a test rather than reaching through a hook callback.
  """
  @spec reset_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_state(socket), do: reset_meeting_state(socket)

  @doc """
  Flip the local `:mic_enabled` assign, push `toggle-mic` to the
  MeetingClient JS hook, AND broadcast the authoritative post-toggle
  media-state pair to all subscribers on `MeetingState.topic(user_id)`.

  Public so the broadcast contract can be unit-tested directly; the
  private `handle_event("meeting_toggle_mic", ...)` hook clause is a thin
  delegate. The broadcast carries both `:mic_enabled` AND `:camera_enabled`
  so consumers never have to stitch partial updates — every event keeps
  the bar + in-chat controls in lockstep (see `MeetingState` moduledoc).
  """
  @spec toggle_mic(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_mic(socket) do
    new_mic = !socket.assigns.mic_enabled

    socket
    |> assign(:mic_enabled, new_mic)
    |> push_event("toggle-mic", %{})
    |> broadcast_media(new_mic, socket.assigns.camera_enabled)
  end

  @doc """
  Flip the local `:camera_enabled` assign, push `toggle-camera` to the
  MeetingClient JS hook, AND broadcast the authoritative post-toggle
  media-state pair to all subscribers on `MeetingState.topic(user_id)`.

  Symmetric companion to `toggle_mic/1` — same broadcast contract.
  """
  @spec toggle_camera(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_camera(socket) do
    new_camera = !socket.assigns.camera_enabled

    socket
    |> assign(:camera_enabled, new_camera)
    |> push_event("toggle-camera", %{})
    |> broadcast_media(socket.assigns.mic_enabled, new_camera)
  end

  # Fan out the authoritative media-state pair if we know whose state it
  # is. No user_id → no broadcast (anonymous mount, defensive); the
  # `:mic_enabled`/`:camera_enabled` booleans must already be the
  # post-toggle truth, not nil/strings.
  defp broadcast_media(socket, mic, camera)
       when is_boolean(mic) and is_boolean(camera) do
    case socket.assigns[:user_id] do
      user_id when is_binary(user_id) ->
        MeetingState.broadcast_media_state(user_id, %{
          mic_enabled: mic,
          camera_enabled: camera
        })

      _ ->
        :ok
    end

    socket
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("meeting_join", _params, socket) do
    {:halt, do_join(socket)}
  end

  defp handle_event("meeting_leave", _params, socket) do
    stamp_local_left(socket)
    MeetingState.broadcast_left(socket.assigns.user_id)

    {:halt,
     socket
     |> reset_meeting_state()
     |> push_event("leave-meeting", %{})}
  end

  # Fired from meeting_client.js on RoomEvent.Disconnected (including
  # client-initiated leaves that already happened).
  defp handle_event("meeting_left", _params, socket) do
    stamp_local_left(socket)
    MeetingState.broadcast_left(socket.assigns.user_id)
    {:halt, reset_meeting_state(socket)}
  end

  defp handle_event("meeting_toggle_mic", _params, socket) do
    {:halt, toggle_mic(socket)}
  end

  defp handle_event("meeting_toggle_camera", _params, socket) do
    {:halt, toggle_camera(socket)}
  end

  defp handle_event("meeting_toggle_screen_share", _params, socket) do
    {:halt,
     socket
     |> assign(:screen_share_enabled, !socket.assigns.screen_share_enabled)
     |> push_event("toggle-screen-share", %{})}
  end

  # Client-side mirror from `MeetingShareButton` (task 019e420f stage 2).
  # The JS hook calls `setScreenShareEnabled` *inside* the click handler
  # to preserve the browser's user-activation flag, then pushes the
  # resulting boolean back here. We simply assign it — no push_event,
  # because the JS has already done the LiveKit work.
  defp handle_event("meeting_screen_share_state", %{"enabled" => enabled}, socket)
       when is_boolean(enabled) do
    {:halt, socket |> assign(:screen_share_enabled, enabled) |> maybe_switch_to_screen(enabled)}
  end

  # Right-rail tab select. DELIBERATELY the same event name
  # `MeetingLive` already ships (`"meeting_tab_select"`) rather than a
  # quickmeet-flavoured second name: `CallShell.call_rail/1` takes the
  # event as an attr precisely so both surfaces can speak one
  # vocabulary, and a second name would mean a reader of the rail's
  # markup could not tell which handler a click reaches.
  #
  # `{:halt, …}` is safe on `/meetings` too — `MeetingLive`'s own
  # clause performs the identical assign, so halting here costs
  # nothing. The value is NOT validated: `call_rail/1` normalises an
  # unrecognised tab to People itself, so a stale `?tab=` costs the tab
  # and not the pane.
  # The `<lg` call-rail sheet. Server state rather than a `JS.toggle/1`
  # because the overlay header's toggle and the sheet's own close button
  # are in two different breakpoint subtrees, and because the sheet must
  # come back DOWN when the user leaves the call — `leave_call_shell/1`
  # resets it. A client-only toggle would strand it open over the chat.
  defp handle_event("quickmeet_toggle_rail", _params, socket) do
    {:halt, assign(socket, :quickmeet_rail_open, !socket.assigns[:quickmeet_rail_open])}
  end

  # The People tab's Invite button on the quickmeet (task 01a0691d stage
  # 2). The body is `invite_agent_into_call/3` — the same `with` chain and
  # the same flashes `/meetings` runs — against the space this chat surface
  # is in a call on, then the roster refresh that turns the clicked row
  # `:pending`. Halted: `ChatLive` has no clause for this event and the
  # flash is already on the socket.
  defp handle_event("quickmeet_invite_agent", %{"agent-id" => agent_id}, socket)
       when is_binary(agent_id) do
    space_id = active_space_id(socket)

    socket =
      socket
      |> invite_agent_into_call(space_id, agent_id)
      |> maybe_refresh_roster(space_id)

    {:halt, socket}
  end

  defp handle_event("meeting_tab_select", %{"tab" => tab}, socket) when is_binary(tab) do
    {:halt, assign(socket, :active_meeting_tab, tab)}
  end

  # Active speakers from the viewer's own LiveKit client. The `MeetingRoom`
  # JS hook is mounted on BOTH surfaces (`chat_live.html.heex` and
  # `meeting_live.html.heex`) and a hook's `pushEvent` ignores `phx-target`,
  # so the push lands on whichever root LiveView owns the page. Before this
  # clause existed `ChatLive` had no handler at all: every speaker change
  # in a quickmeet was a `FunctionClauseError`, the process crash-remounted,
  # and the remount dropped transient rail state (`:typing`) that only
  # arrives over PubSub — which is how the quickmeet read `Idle` where
  # `/meetings` read `Writing` (task 01a05b14 stage 5). `{:halt, …}` is the
  # same implementation `/meetings` runs, so halting there costs nothing.
  defp handle_event("active_speakers", params, socket) do
    {:halt, apply_active_speakers(socket, params)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ── Guest-flavored event surface (task 019f498d stage 3) ────────────────
  #
  # Same event names as the authenticated handlers above but with the
  # user_id-dependent side effects (`broadcast_media` / `broadcast_left` /
  # `stamp_local_left`) elided. Called from `attach_guest/1` for the
  # guest ingress path in `PlatformWeb.MeetingLive` (chrome_mode: :none),
  # which has `:user_id = nil`.

  defp handle_guest_event("meeting_toggle_mic", _params, socket) do
    new_mic = !socket.assigns.mic_enabled

    {:halt,
     socket
     |> assign(:mic_enabled, new_mic)
     |> push_event("toggle-mic", %{})}
  end

  defp handle_guest_event("meeting_toggle_camera", _params, socket) do
    new_camera = !socket.assigns.camera_enabled

    {:halt,
     socket
     |> assign(:camera_enabled, new_camera)
     |> push_event("toggle-camera", %{})}
  end

  defp handle_guest_event("meeting_toggle_screen_share", _params, socket) do
    {:halt,
     socket
     |> assign(:screen_share_enabled, !socket.assigns.screen_share_enabled)
     |> push_event("toggle-screen-share", %{})}
  end

  defp handle_guest_event("meeting_screen_share_state", %{"enabled" => enabled}, socket)
       when is_boolean(enabled) do
    {:halt, socket |> assign(:screen_share_enabled, enabled) |> maybe_switch_to_screen(enabled)}
  end

  # Explicit leave from the top-bar Leave button. No durable participant row
  # to stamp (`stamp_local_left/1` requires `:user_id` binary), no
  # `MeetingState.broadcast_left/1` (also `is_binary`-guarded). Just reset
  # local media state and tell the JS hook to disconnect.
  #
  # Also drops the three meetings-family subscriptions taken on entry (task
  # `01a02c4e` stage 4) — the LiveView survives the leave, so without this
  # it keeps receiving presence/room/meeting broadcasts for a meeting it is
  # no longer in. See `release_guest_topics/1`.
  defp handle_guest_event("meeting_leave", _params, socket) do
    {:halt,
     socket
     |> release_guest_topics()
     |> reset_meeting_state()
     |> push_event("leave-meeting", %{})}
  end

  # Fired from meeting_client.js on RoomEvent.Disconnected. Symmetric to the
  # authenticated `meeting_left` path minus the user_id-dependent writes.
  # Releases the entry subscriptions too: this is the path a guest takes when
  # the connection drops rather than the button being clicked, and it is
  # reached WITHOUT `"meeting_leave"` having run. `release_guest_topics/1` is
  # idempotent, so the button path running both is fine.
  defp handle_guest_event("meeting_left", _params, socket) do
    {:halt, socket |> release_guest_topics() |> reset_meeting_state()}
  end

  defp handle_guest_event("active_speakers", params, socket) do
    {:halt, apply_active_speakers(socket, params)}
  end

  defp handle_guest_event(_event, _params, socket), do: {:cont, socket}

  # Screen-share-not-displaying fix: when a share STARTS on `/meetings`, flip
  # the center stage to Screen mode so `[data-screen-share-slot]` + the
  # `MeetingScreenShare` hook are actually in the DOM to render the track.
  #
  # The top-bar share button (`MeetingShareButton`) is present in EVERY stage
  # mode, but the published track only has a render target in Screen mode. A
  # sharer in the default Gallery mode therefore published the track into a
  # slot that wasn't mounted and saw nothing. This event is the
  # `MeetingShareButton` mirror, and on `/meetings` it's routed through THIS
  # attached hook (which `:halt`s before MeetingLive's own clause), so the
  # stage switch has to live here to run on the surface that has stage modes.
  #
  # Guarded on `:current_stage_mode` being assigned: only MeetingLive assigns
  # it. On the `/chat` quick-meet surface there are no stage modes (its
  # always-mounted `[data-quickmeet-screen-share-slot]` renders the share
  # without a switch), so this is a no-op there.
  #
  # We only auto-switch on the enable edge; on disable we leave the stage
  # where the user put it (no jarring jump back). `meeting_stage_mode_changed`
  # is pushed so the page-level `MeetingClient` hook re-docks the local
  # self-view into the new mode's strip dock, parity with `set_stage_mode`.
  defp maybe_switch_to_screen(socket, true) do
    case Map.get(socket.assigns, :current_stage_mode) do
      nil ->
        socket

      :screen ->
        socket

      _other ->
        socket
        |> assign(:current_stage_mode, :screen)
        |> push_event("meeting_stage_mode_changed", %{mode: "screen"})
    end
  end

  defp maybe_switch_to_screen(socket, false), do: socket

  # Return `{:cont, socket}` so the event continues to the host LV's own
  # `handle_info({:meeting_presence_update, _}, socket)` (notably
  # `PlatformWeb.MeetingLive`, which uses this event to (a) re-subscribe to
  # the now-active room topic and (b) refresh the server-presence roster on
  # `/meetings`). Halting here previously starved MeetingLive of presence
  # updates, so the room topic was never subscribed after activation and
  # subsequent joiners' `{:participant_joined, p}` broadcasts never reached
  # the existing viewers — symptom: a 2nd person joining your meeting got
  # audio but no tile until you reloaded.
  defp handle_info(
         {:meeting_presence_update, %{space_id: space_id, active: active, count: count}},
         socket
       ) do
    counts =
      if active do
        Map.put(socket.assigns.meeting_counts, space_id, count)
      else
        Map.delete(socket.assigns.meeting_counts, space_id)
      end

    socket =
      socket
      |> assign(:meeting_counts, counts)
      |> maybe_refresh_roster(space_id)

    {:cont, socket}
  end

  defp handle_info({:meeting_presence_summary, %{space_id: _space_id}}, socket) do
    space_ids = socket.assigns[:spaces] |> List.wrap() |> Enum.map(& &1.id)
    counts = Meetings.active_meeting_counts(space_ids)
    {:halt, assign(socket, :meeting_counts, counts)}
  end

  # V3 fix (task 019ee06b): keep ChatLive's local `:mic_enabled` /
  # `:camera_enabled` assigns in lockstep with the authoritative post-toggle
  # truth broadcast on `MeetingState.topic(user_id)`. Before this clause,
  # only ShellLive subscribed — so a bar-side mic tap broadcast on the topic
  # updated the bar but ChatLive's stale assigns stayed put, and the next
  # in-chat toggle flipped against stale state (apparent bug: the bar mic
  # icon went dark then bounced back on the next bar tap).
  #
  # The actual assign-update is delegated to `apply_media_state/2` so the
  # contract can be unit-tested directly (this private handle_info clause is
  # hook plumbing — the public delegate is the contract).
  defp handle_info(
         {:meeting_media_state, %{user_id: uid, mic_enabled: mic, camera_enabled: camera}},
         socket
       ) do
    {:cont, apply_media_state(socket, %{user_id: uid, mic_enabled: mic, camera_enabled: camera})}
  end

  # Agent activity for the quickmeet's People pane (task 01a05b14 stage
  # 6). ONE fold, not two: the transition semantics live in
  # `AgentActivity.put/4` and this clause is the same three-line shape
  # `MeetingLive.handle_info/2` uses, deliberately not a reimplementation.
  #
  # `{:cont, …}`, and the guard is what makes that safe. `MeetingLive`
  # mounts THIS module's hooks and keeps its own top-level clause for
  # the same message; the guard below fires only when
  # `:quickmeet_meeting_id` is set, which `join_call_shell/2` does only
  # on a socket with no `:meeting` assign — i.e. never on `/meetings`.
  # So exactly one fold runs per surface, and continuing lets
  # `MeetingLive`'s clause see the message it has always seen.
  defp handle_info(
         {:agent_activity,
          %{meeting_id: meeting_id, agent_id: agent_id, signal: signal, active?: active?}},
         socket
       ) do
    {:cont,
     apply_agent_activity(socket, %{
       meeting_id: meeting_id,
       agent_id: agent_id,
       signal: signal,
       active?: active?
     })}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  @doc """
  Fold an `active_speakers` push from the `MeetingRoom` JS hook into
  `:speaking_identities`.

  VIEWER-LOCAL presentation state: each connected client runs its own
  LiveKit room and reports what IT hears, so this is never persisted and
  never broadcast. The payload is `%{"identities" => ["user:…", "agent:…"]}`;
  anything else — a missing key, a non-list, non-binary members — is
  tolerated rather than crashed on, because a malformed push must not
  take the LiveView down (the hook debounces, but a crash-remount loop
  loses every transient assign the surface holds). Identical for
  `/meetings` (`MeetingLive` delegates here) and the quickmeet.
  """
  @spec apply_active_speakers(Phoenix.LiveView.Socket.t(), term()) ::
          Phoenix.LiveView.Socket.t()
  def apply_active_speakers(socket, %{"identities" => ids}) when is_list(ids) do
    next = ids |> Enum.filter(&is_binary/1) |> MapSet.new()
    current = socket.assigns[:speaking_identities] || MapSet.new()

    if MapSet.equal?(next, current) do
      socket
    else
      assign(socket, :speaking_identities, next)
    end
  end

  def apply_active_speakers(socket, _params), do: socket

  @doc """
  Fold an `{:agent_activity, …}` payload into `:agent_activity`.

  Public for the same reason `apply_media_state/2` is: the
  `handle_info/2` clause above is hook plumbing, and the CONTRACT — the
  meeting guard plus the `AgentActivity.put/4` fold — is what a test
  should be able to name directly.

  The guard is on `:quickmeet_meeting_id`, which only
  `join_call_shell/2` sets and only on a socket with no `:meeting`
  assign. That is what keeps `/meetings` — which mounts this module's
  hooks AND keeps its own top-level clause for this message — from
  folding the same transition twice.
  """
  @spec apply_agent_activity(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_agent_activity(socket, %{
        meeting_id: meeting_id,
        agent_id: agent_id,
        signal: signal,
        active?: active?
      }) do
    if socket.assigns[:quickmeet_meeting_id] == meeting_id do
      update(socket, :agent_activity, &AgentActivity.put(&1, signal, agent_id, active?))
    else
      socket
    end
  end

  @doc """
  Fold an `{:agent_typing, …}` broadcast into the quickmeet's
  `:agent_activity`.

  Task 01a05b14 stage 5, round 2. `MeetingLive` had this fold and the
  quickmeet did not, so the rail row for a replying agent read "Idle"
  on the chat surface while `/meetings` read "Writing" and the composer
  on the SAME page showed "X is thinking…" — three consumers of one
  broadcast, one of them unwired.

  Deliberately NOT a `handle_info/2` clause of this module. `ChatLive`
  attaches `PresenceHooks` BEFORE `MeetingHooks`, and `PresenceHooks`
  HALTS `{:agent_typing, …}` for the active space (it owns the
  composer's typing state), so a clause here would never run in exactly
  the case a quickmeet cares about. `PresenceHooks` calls this from its
  own clause instead, before it decides whether to halt.

  The guard is what makes that call safe on every socket: it fires only
  when `:quickmeet_meeting` is a meeting bound to the broadcast's space,
  which `join_call_shell/2` sets only on the quickmeet — never on
  `/meetings`, which keeps its own top-level clause — so exactly one
  fold runs per surface. Never raises: a payload that is not the
  canonical shape is returned untouched, and the participant bridge
  inside `AgentActivity.put_typing/3` leaves the value alone for a
  human or unknown id.
  """
  @spec apply_agent_typing(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def apply_agent_typing(
        socket,
        %{space_id: space_id, participant_id: participant_id, typing: typing}
      ) do
    if quickmeet_bound_to_space?(socket, space_id) do
      update(socket, :agent_activity, &AgentActivity.put_typing(&1, participant_id, typing))
    else
      socket
    end
  end

  def apply_agent_typing(socket, _payload), do: socket

  defp quickmeet_bound_to_space?(
         %{assigns: %{quickmeet_meeting_id: id, quickmeet_meeting: %{chat_space_id: space_id}}},
         space_id
       )
       when is_binary(id) and is_binary(space_id),
       do: true

  defp quickmeet_bound_to_space?(_socket, _space_id), do: false

  @doc """
  Apply a `:meeting_media_state` payload to the socket assigns.

  Guarded on `user_id` matching `socket.assigns.user_id` so events meant
  for a different user (defensive — the subscription is per-user, but the
  guard makes the contract explicit) don't trample our state. The full
  `{mic_enabled, camera_enabled}` pair is always assigned together,
  matching the broadcast contract (`MeetingState.broadcast_media_state/2`)
  so consumers never stitch partial updates.

  Public so the bar→chat lockstep contract can be unit-tested directly.
  """
  @spec apply_media_state(Phoenix.LiveView.Socket.t(), %{
          required(:user_id) => binary(),
          required(:mic_enabled) => boolean(),
          required(:camera_enabled) => boolean()
        }) :: Phoenix.LiveView.Socket.t()
  def apply_media_state(socket, %{user_id: uid, mic_enabled: mic, camera_enabled: camera})
      when is_binary(uid) and is_boolean(mic) and is_boolean(camera) do
    if uid == socket.assigns[:user_id] do
      socket
      |> assign(:mic_enabled, mic)
      |> assign(:camera_enabled, camera)
    else
      socket
    end
  end

  # ── Internals ────────────────────────────────────────────────────────

  # Room lifecycle (task 019e4b3e v4 stage 1): `Meetings.activate_room/1`
  # previously had ZERO callers, so `ensure_room/1` left rooms at the
  # schema default `status="idle"`. `get_active_room/1` filters
  # `status=="active"`, so `active_participants_for_space/1` (and the
  # presence rail on BOTH the /meetings and /chat surfaces) always saw an
  # empty list. A room must become "active" exactly when the first real
  # participant joins — and `do_join/1` is the single shared join
  # entrypoint (ChatLive `meeting_join` + MeetingLive `:auto_join` both
  # route here), so activating here fixes presence sourcing on both
  # surfaces in one place and keeps room-active + has-participant atomic.
  #
  # We gate on `status != "active"` so an already-active room skips the
  # redundant write and the spurious `:room_activated`/presence broadcast.
  #
  # Deactivation symmetry lives in the LiveKit `room_finished` webhook
  # (livekit_webhook_controller.ex), which calls `finish_room/1` when
  # LiveKit reports the room emptied — so rooms don't leak as "active"
  # forever. Explicit per-user leaves still flow through
  # `meeting_leave`/`meeting_left` + the `participant_left` webhook.
  defp activate_room_on_join(%{status: "active"} = room), do: {:ok, room}
  defp activate_room_on_join(room), do: Meetings.activate_room(room)

  # v4 case-2 fix: an EXPLICIT user-initiated leave (`meeting_leave` button
  # OR `meeting_left` from RoomEvent.Disconnected) must STAMP the durable
  # `meeting_participants` row's `left_at` server-side — not merely broadcast
  # a presence COUNT signal. This is the symmetric gap to the join fix: join
  # inserts the row via `upsert_live_participant/2` instead of relying on the
  # LiveKit `participant_joined` webhook, so leave must stamp `left_at`
  # instead of relying on the `participant_left` webhook — which (a) cannot
  # reach the ephemeral dev container and (b) is fragile for clean leaves in
  # prod. Without this, `active_participants_for_space/1` (which filters
  # `left_at IS NULL`) keeps returning the leaver and the roster never
  # decrements on other clients.
  #
  # The `participant_left` webhook stays as the idempotent backup for hard
  # disconnects: stamping an already-left row resolves no active row and
  # returns `{:error, :not_found}`, a safe no-op.
  #
  # CRITICAL asymmetry with `on_terminate/1`: a LiveView process dying (a
  # transient 1006 socket blip) is NOT an explicit leave and must NOT stamp
  # `left_at` — the v3/v4 reconnect design depends on the participant row
  # surviving the remount so `maybe_restore_on_reconnect/2` can find it and
  # restore `:in_meeting`. So ONLY this explicit-leave path stamps; the
  # process-death path (`on_terminate/1`) remains a deliberate no-op.
  #
  # Public so the explicit-leave decrement contract can be unit-tested
  # directly (the `handle_event/3` leave callbacks are private hook plumbing).
  #
  # Task 019ee06b stage 1 (pure refactor): the cleanup body now lives on
  # `Platform.Meetings.leave_for_user/2` so the same decrement is
  # reachable from surfaces that aren't a chat LV (notably the persistent
  # meeting mini-bar in `ShellLive` — stage 2 wires that). We keep this
  # socket-facing shim so the existing `handle_event/3` plumbing and the
  # `meeting_hooks_test.exs` v4-case-2 regressions stay byte-for-byte
  # identical: pull `space_id` + `user_id` from assigns, hand off.
  @doc false
  @spec stamp_local_left(Phoenix.LiveView.Socket.t()) :: :ok
  def stamp_local_left(socket) do
    with space when not is_nil(space) <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- socket.assigns[:user_id] do
      Meetings.leave_for_user(space.id, user_id)
    end

    :ok
  end

  # v4 stage 3: build the server-presence roster for the /chat quick-meet
  # rail. Delegates to `MeetingLive.build_meeting_participants/1` (the
  # verified-working presence builder) so BOTH surfaces source the rail from
  # ONE place: `Meetings.active_participants_for_space/1` (LiveKit-webhook-fed,
  # `left_at`-filtered, identity-resolved). Returns the same view-model maps
  # (`:id`, `:participant_id`, `:participant_type`, `:display_name`,
  # `:avatar_url`) the rail renders — never the literal "User".
  defp meeting_participants(space_id) when is_binary(space_id) do
    PlatformWeb.MeetingLive.build_meeting_participants(space_id)
  end

  defp meeting_participants(_), do: []

  @doc """
  v4 stage 3: when a `:meeting_presence_update` arrives for the space whose
  quick-meet panel this viewer is in, re-pull the server-presence roster so
  the rail live-updates as a 2nd user (or a webhook-driven participant) joins
  or leaves. This is what makes the rail SERVER-presence-sourced — the
  `_ensureTile` client tiles only know the LiveKit participants THIS browser
  has subscribed, so a webhook-written row would otherwise never appear in
  another viewer's rail (the v3 e2e gap). A no-op when the viewer is not in a
  meeting or the update is for a different space.

  Public so the presence-refresh contract can be unit-tested directly
  (the `handle_info/2` hook itself is private hook-callback plumbing).
  """
  @spec maybe_refresh_roster(Phoenix.LiveView.Socket.t(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_refresh_roster(socket, space_id) do
    if socket.assigns[:in_meeting] and active_space_id(socket) == space_id do
      assign_roster(socket, space_id)
    else
      socket
    end
  end

  # The rail's roster assigns move together (task 01a0691d stage 2), as
  # `MeetingLive.assign_invite_rows/3` moves them on `/meetings`: the
  # participants, the invite rows built from them, and the clickable
  # projection `invite_agent_into_call/3` resolves a click against. One
  # roster read per refresh, and the button list can never disagree with
  # the row list about the same agent.
  defp assign_roster(socket, space_id) do
    participants = meeting_participants(space_id)
    rows = PlatformWeb.MeetingLive.invite_rows(space_id, participants)

    socket
    |> assign(:meeting_participants, participants)
    |> assign(:invite_rows, rows)
    |> assign(:invitable_agents, PlatformWeb.MeetingLive.invitable_agents_from_rows(rows))
  end

  defp active_space_id(socket) do
    case socket.assigns[:active_space] do
      %{id: id} -> id
      _ -> nil
    end
  end

  @doc """
  The `"meeting_invite_agent"` body, shared by `PlatformWeb.MeetingLive` and
  the quickmeet panel (task 01a0691d stage 1; moved here verbatim from
  `MeetingLive.invite_agent_into_call/2`, where task 01a04c2f wrote it).

  Every failure ends in a flash rather than a raise: this control lives on a
  page that is open for the whole call, so an agent can leave the roster or
  the call can end between the render and the click. Those are real runtime
  outcomes, not caller bugs.

  Two assigns are read, and both surfaces carry them:

    * `:invitable_agents` — the server-built CLICKABLE list this socket just
      rendered. The agent id is resolved against it rather than against the
      `agents` table, so a forged or stale `agent-id` is a miss (the
      catch-all flash), never a cross-space reach. An agent that
      `MeetingLive.invite_rows/2` lists as `:incapable` or `:in_call` is not
      in this list, which is what makes "not offered" hold on the server and
      not only in the markup.
    * `:current_user_record` — the viewer, seeded by `ShellLive`'s on_mount
      on both views; `Meetings.invite_agent/3` authorizes it.

  `space_id` is the meeting's chat space. The caller owns what happens to
  its roster afterwards: `MeetingLive` runs `refresh_participants/1`, which
  reads its own `:meeting` assign and so cannot live here.

  The success flash says "Invited", not "is joining" (task 01a0554f). A
  successful return from `invite_agent/3` means the join was BROADCAST, and
  `Phoenix.Endpoint.broadcast/3` returns `:ok` into a topic with no
  subscriber just as readily as into a live one — the hazard
  `Meetings.invite_agent/3` documents at length. Arrival is reported by the
  `{:agent_join_failed, _}` path and by the participant rail when the worker
  actually publishes.
  """
  @spec invite_agent_into_call(Phoenix.LiveView.Socket.t(), binary() | nil, binary()) ::
          Phoenix.LiveView.Socket.t()
  def invite_agent_into_call(socket, space_id, agent_id) do
    with space_id when is_binary(space_id) <- space_id,
         %Agent{} = agent <-
           Enum.find(socket.assigns[:invitable_agents] || [], &(&1.id == agent_id)),
         %Room{} = room <- Meetings.get_active_room(space_id),
         {:ok, _participant} <-
           Meetings.invite_agent(room, agent, socket.assigns[:current_user_record]) do
      put_flash(socket, :info, invite_flash(agent, room, socket.assigns[:user_id]))
    else
      {:error, :forbidden} ->
        put_flash(socket, :error, "You do not have permission to invite an agent here.")

      # Distinguished from the catch-all because it is the one failure a
      # human can act on: the agent is real and on the roster, but no
      # runtime is connected to it, so nothing could receive the join.
      # Before task 01a04f31 this case returned `{:ok, participant}` and
      # flashed success.
      {:error, :no_runtime} ->
        put_flash(
          socket,
          :error,
          "That agent has no connected runtime, so it cannot join the meeting."
        )

      # Task 01a06686: the agent's voice worker has its own runtime row, and
      # it is that row — not the brain — that is not connected. Named apart
      # from `:no_runtime` because the remedy differs: the brain may be
      # online and answering chat while the mouth is down.
      {:error, :voice_runtime_offline} ->
        put_flash(
          socket,
          :error,
          "#{voice_offline_agent_name(socket, agent_id)}'s voice worker is offline, so it cannot join the meeting."
        )

      _ ->
        put_flash(socket, :error, "That agent could not be invited.")
    end
  end

  # Task 01a06925 stage 3, moved here verbatim by task 01a0691d stage 1 when
  # the invite body left `MeetingLive`. Runs only AFTER `invite_agent/3` has
  # delivered the join, and can only ever lengthen the success flash: the
  # roster row that makes the page show the inviter as present is written
  # server-side before the browser connects, so this asks LiveKit who is
  # actually in the media room and says so — the one fact the 21:16Z incident
  # could not be diagnosed from the page without. `:unavailable` keeps the
  # copy as it was; a diagnostic never turns a delivered invite into an error.
  defp invite_flash(agent, room, user_id) do
    base = "Invited #{agent.name} — waiting for it to join."
    presence = Meetings.media_room_presence(room.livekit_room_name, "user:#{user_id}")

    Logger.info(
      "[Meetings] invite agent=#{agent.slug} room=#{room.livekit_room_name} " <>
        "sfu=#{sfu_summary(presence, "user:#{user_id}")}"
    )

    case presence do
      :unavailable ->
        base

      %{viewer_present?: true, others: others} ->
        base <> " LiveKit sees you and #{length(others)} other(s) in the media room."

      %{viewer_present?: false} ->
        base <>
          " LiveKit does not see you in the media room yet; the agent will be speaking to nobody. Check your call connection."
    end
  end

  defp sfu_summary(:unavailable, _viewer), do: "unavailable"

  defp sfu_summary(%{viewer_present?: present?, others: others}, viewer) do
    case if(present?, do: [viewer | others], else: others) do
      [] -> "(nobody)"
      identities -> Enum.join(identities, ",")
    end
  end

  # The `with` above has already bound `agent` by the time `invite_agent/3`
  # can answer `:voice_runtime_offline`, but an `else` clause cannot see the
  # bindings of the `with` chain, so the name is looked up again from the
  # same list the chain read.
  defp voice_offline_agent_name(socket, agent_id) do
    case Enum.find(socket.assigns[:invitable_agents] || [], &(&1.id == agent_id)) do
      %Agent{name: name} when is_binary(name) and name != "" -> name
      _ -> "That agent"
    end
  end

  defp do_join(socket) do
    # Stage 4 (task 019e2d1a) bugfix: the participant-row check used to
    # gate this `with`, which meant a fresh user — one who has never
    # touched the meeting's bound chat space and therefore has no
    # `:current_participant` assign — silently no-op'd here. The
    # Membership bridge then never ran, the LiveKit join never fired,
    # and the e2e reviewer saw `data-gallery-tile-count='0'`.
    #
    # The fix inverts the guard: we require `user_id` (always present
    # for authenticated mounts) + `:active_space`, then call
    # `Membership.ensure_chat_space_participant/3` FIRST. That call is
    # the canonical insert path AND a find-or-insert, so it doubles as
    # the participant resolver — its return value becomes the
    # `:current_participant` assign for the rest of the lifecycle.
    # Only after that do we mint the LiveKit token and push to the JS
    # hook.
    with space when not is_nil(space) <- socket.assigns[:active_space],
         user_id when is_binary(user_id) <- socket.assigns[:user_id],
         :ok <- authorize_join(space.id, user_id),
         display_name = resolve_display_name(socket),
         {:ok, participant} <-
           MeetingsMembership.ensure_chat_space_participant(space.id, user_id, display_name),
         {:ok, room} <- Meetings.ensure_room(space.id),
         {:ok, room} <- activate_room_on_join(room),
         identity = "user:#{user_id}",
         # Prefer the hardened resolved name over a stale/blank participant
         # row name (legacy rows may carry the literal "User") so the
         # LiveKit-published tile shows the real name immediately.
         name = grant_name(participant.display_name, display_name),
         # v4 fix: insert the joiner's `meeting_participants` row HERE, on the
         # real join — not only via the LiveKit `participant_joined` webhook.
         # `upsert_live_participant/2` is the ONLY writer of that table, and
         # the webhook (livekit_webhook_controller) can't reach the ephemeral
         # dev container, so the server-presence roster
         # (`active_participants_for_space/1`, shared by /chat quick-meet AND
         # /meetings) was always empty for a genuine local join. Dual-path,
         # safe by design: this insert is deterministic + dev-testable, and
         # the webhook stays as the idempotent backup for SFU-reported and
         # remote participants. `upsert_live_participant/2` is
         # find-or-reactivate keyed on (room_id, user_id), so when the prod
         # `participant_joined` webhook later fires for the same `user:<id>`
         # identity it returns the SAME row — no duplicate. The insert path
         # broadcasts `{:participant_joined, p}` + presence_change internally,
         # so the roster live-updates for this joiner and other subscribers
         # without a second broadcast here.
         {:ok, _live_participant} <-
           Meetings.upsert_live_participant(room, %{identity: identity, name: name}),
         {:ok, token} <- Meetings.generate_token(room, %{identity: identity, name: name}) do
      socket =
        socket
        |> assign(:current_participant, participant)
        |> assign(:in_meeting, true)
        |> assign_roster(space.id)
        |> push_event("join-meeting", %{
          token: token,
          url: Meetings.livekit_url(),
          room_name: room.livekit_room_name,
          space_slug: space.slug
        })

      # ONE lookup, two consumers. The mini-bar's Return-to-call deep
      # link needs the slug; the call shell needs the whole row (its id
      # is the PubSub topic and the key to every rail-facing query).
      # Two `get_live_meeting_for_space/1` calls a few lines apart could
      # also return two DIFFERENT rows if a meeting flipped live between
      # them, which is how a rail ends up hydrated for a meeting the
      # slug does not point at.
      live_meeting = Meetings.get_live_meeting_for_space(space.id)

      meeting_slug =
        case live_meeting do
          %{slug: slug} when is_binary(slug) -> slug
          _ -> space.slug
        end

      socket = join_call_shell(socket, live_meeting)

      MeetingState.broadcast_joined(user_id, space.id, space.name, space.slug, meeting_slug)

      # A fresh bar mount that just adopted us on `:meeting_joined` has no
      # mic/camera signal yet — emit the initial truth (both enabled per
      # `reset_meeting_state/1`) so consumers don't render a stale snapshot.
      # `:meeting_left` on leave already drives consumers to reset, so we
      # do NOT emit a media_state event from `reset_meeting_state/1`.
      MeetingState.broadcast_media_state(user_id, %{
        mic_enabled: socket.assigns.mic_enabled,
        camera_enabled: socket.assigns.camera_enabled
      })

      socket
    else
      # Refusal, not failure. `authorize_join/2` already emitted the
      # access_blocked telemetry; this arm exists so the refusal does not
      # land in the "meeting_join failed" warning stream below, and so the
      # socket comes back byte-identical to the one that went in — no
      # participant row, no room, no token, no push_event, no broadcast.
      # A partial join (row written, token withheld) would be worse than
      # none: the roster would show a person who is not in the call.
      {:error, :join_not_permitted} ->
        socket

      {:error, reason} ->
        Logger.warning("[ChatLive] meeting_join failed: #{inspect(reason)}")
        socket

      nil ->
        socket

      _ ->
        socket
    end
  end

  # ── The join gate ────────────────────────────────────────────────────────
  #
  # Loading a meeting page and joining its call are DIFFERENT gates, and
  # until task 019fb955-f8b1 stage 4 only the first one existed.
  # `Meetings.generate_token/2` performs no membership check of its own, and
  # this seam is reached from more than the meeting page: `chat_live.html.heex`
  # renders a "Meet" button gated on `@meetings_enabled && !@in_meeting` — NOT
  # on `!@external?` — and `ChatLive` attaches these same hooks. The LiveKit
  # room is keyed off the space (`room_name_for_space/1`), so both surfaces
  # land in the SAME room. An external user seated in a meeting's bound chat
  # space could therefore join the call from the chat host without ever
  # touching the meet host.
  #
  # So the gate lives HERE, once, where every surface passes through it,
  # rather than being duplicated per caller. Hiding the button (stage 5) is
  # cosmetics; this is the fence.
  defp authorize_join(space_id, user_id) do
    if join_permitted?(space_id, user_id) do
      :ok
    else
      emit_join_blocked(space_id, user_id)
      {:error, :join_not_permitted}
    end
  end

  # An external user may join only a call whose space they hold a live invite
  # to. Internal users are unaffected — and pay no query for the privilege:
  # the account is loaded only inside the external branch, so the internal
  # path is behaviourally identical to the one before this gate existed.
  #
  # `Tenancy.external_user?/1` is the same predicate the request-path plug and
  # `Chat.ExternalScope` already use. Do not grow a second one.
  defp join_permitted?(space_id, user_id) do
    if Tenancy.external_user?(%{id: user_id}) do
      Meetings.invited_to_space?(space_id, Accounts.get_user(user_id))
    else
      true
    end
  end

  # The refusal is silent to the user by design — no distinguishing flash, so
  # the socket cannot be used to probe which spaces back a meeting. It is not
  # silent to the operator: this feeds `Platform.Audit` through the same
  # `[:platform, :auth, :access_blocked]` event the request-path denials use.
  defp emit_join_blocked(space_id, user_id) do
    :telemetry.execute(
      [:platform, :auth, :access_blocked],
      %{system_time: System.system_time()},
      %{
        action: "blocked",
        actor_id: user_id,
        actor_type: "user",
        resource_type: "chat_space",
        resource_id: space_id,
        reason: "external_meeting_join_denied"
      }
    )
  end

  # Pick the best available display name without depending on a
  # pre-existing participant row. Order of preference:
  #   1. existing `:current_participant.display_name` (set by MeetingLive
  #      mount when the viewer already had a row),
  #   2. `:current_user_display_name` if the host LV bothered to assign one,
  #   3. the real user's `name`, then `email`, looked up by `:user_id`,
  #   4. a neutral `"Guest"` default.
  #
  # This name is handed to LiveKit as the token `name` grant (do_join/1),
  # so the published video tile shows the real name in the sub-second
  # window BEFORE the `participant_joined` webhook lands and the rail
  # re-resolves from the DB row. Returning "User" here would leak that
  # literal onto the tile, which is exactly the bug v2 closes — so this
  # falls all the way through to the user's name/email first.
  defp resolve_display_name(socket) do
    cond do
      is_binary(name = participant_display_name(socket.assigns[:current_participant])) and
          name != "" ->
        name

      is_binary(name = socket.assigns[:current_user_display_name]) and name != "" ->
        name

      is_binary(name = user_name_or_email(socket.assigns[:user_id])) and name != "" ->
        name

      true ->
        "Guest"
    end
  end

  defp participant_display_name(%{display_name: name}), do: name
  defp participant_display_name(_), do: nil

  # Choose the LiveKit `name` grant. The participant row's display_name
  # wins only when it is a real, non-"User" name; otherwise fall back to
  # the hardened resolved name.
  defp grant_name(participant_name, _resolved)
       when is_binary(participant_name) and participant_name != "" and participant_name != "User",
       do: participant_name

  defp grant_name(_participant_name, resolved), do: resolved

  defp user_name_or_email(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) and email != "" -> email
      _ -> nil
    end
  end

  defp user_name_or_email(_), do: nil

  # ── Call shell (task 01a05b14 stage 6) ───────────────────────────────────
  #
  # The quickmeet panel renders `CallShell.call_rail/1`, the same rail
  # `/meetings` renders. The MARKUP was never the hard part — before
  # this stage `attach/2` assigned no meeting id, no agent activity, no
  # candidates and no tab, so there was simply nothing for a rail to
  # read. These helpers are that missing data plane.
  #
  # `assign_new/3` throughout, and that is load-bearing rather than
  # stylistic: `MeetingLive` assigns `:agent_activity`,
  # `:active_meeting_tab`, `:agents_by_id` and the candidate board
  # BEFORE it calls `attach/2`. Plain `assign/3` here would blank every
  # one of them on `/meetings` — a silent regression of stages 2-5 that
  # no quickmeet test would ever see.
  defp assign_call_shell_defaults(socket) do
    socket
    |> assign_new(:quickmeet_meeting_id, fn -> nil end)
    |> assign_new(:quickmeet_meeting, fn -> nil end)
    |> assign_new(:quickmeet_rail_open, fn -> false end)
    |> assign_new(:active_meeting_tab, fn -> "people" end)
    |> assign_new(:agent_activity, fn -> AgentActivity.new() end)
    |> assign_new(:agents_by_id, fn -> %{} end)
    |> assign_new(:meeting_candidates, fn -> [] end)
    |> assign_new(:meeting_candidates_closed, fn -> [] end)
    |> assign_new(:meeting_candidate_events, fn -> %{} end)
    |> assign_new(:candidate_error, fn -> nil end)
    |> assign_new(:speaking_identities, fn -> MapSet.new() end)
  end

  # Hydrate the rail for the meeting this socket just joined.
  #
  # NO-OP when `:meeting` is assigned. That assign is `MeetingLive`'s
  # and only `MeetingLive`'s, so it is the exact discriminator for "this
  # socket is /meetings, which already did all of this at
  # handle_params". Without the guard, `/meetings` auto-join (which runs
  # through `do_join/1`) would subscribe to `meeting_topic/1` a SECOND
  # time from the same pid — Phoenix.PubSub then delivers every message
  # on that topic twice, which is a far worse bug than a missing rail
  # and would show up as duplicated intent rows rather than as anything
  # named "double subscribe".
  #
  # DOCUMENTED LIMITATION, not an oversight: `AgentActivity.hydrate/1`
  # restores `:computing` from the live intent queue and CANNOT restore
  # `:typing`. `:typing` is a transient keystroke toggle broadcast on
  # `chat:space:<id>`; it is written to no row, so a socket joining
  # mid-meeting has nowhere to read it back from and starts with an
  # empty `:typing` set until the next `{:agent_activity, …}` arrives.
  # A joiner therefore may not see a `Writing` badge that a socket
  # present since the start is showing. Stated here rather than papered
  # over with a fabricated default.
  defp join_call_shell(%{assigns: %{meeting: %{}}} = socket, _live_meeting), do: socket

  defp join_call_shell(socket, %{id: meeting_id} = live_meeting) when is_binary(meeting_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Platform.PubSub, MeetingsPubSub.meeting_topic(meeting_id))
    end

    participants = socket.assigns[:meeting_participants] || []

    socket
    |> assign(:quickmeet_meeting_id, meeting_id)
    |> assign(:quickmeet_meeting, live_meeting)
    |> assign(:active_meeting_tab, socket.assigns[:active_meeting_tab] || "people")
    |> assign(:agent_activity, AgentActivity.hydrate(meeting_id))
    |> assign(:agents_by_id, PlatformWeb.MeetingLive.load_agents_by_id(participants))
    |> PlatformWeb.MeetingLive.assign_candidate_board(meeting_id)
  end

  # No live `meetings` row for this space — the room came up through raw
  # LiveKit. The panel still renders; the rail shows the server-presence
  # roster and empty Canvas/Transcript panes, which is the truth.
  defp join_call_shell(socket, _live_meeting), do: socket

  # Symmetric teardown. Unsubscribing matters: without it a user who
  # leaves and rejoins subscribes twice, and the third join thrice.
  # Guarded on our OWN assign, so a `/meetings` socket — which never set
  # it — cannot unsubscribe the topic `MeetingLive` still depends on.
  defp leave_call_shell(socket) do
    case socket.assigns[:quickmeet_meeting_id] do
      meeting_id when is_binary(meeting_id) ->
        if connected?(socket) do
          Phoenix.PubSub.unsubscribe(Platform.PubSub, MeetingsPubSub.meeting_topic(meeting_id))
        end

        socket
        |> assign(:quickmeet_meeting_id, nil)
        |> assign(:quickmeet_meeting, nil)
        |> assign(:quickmeet_rail_open, false)
        |> assign(:agent_activity, AgentActivity.new())
        |> assign(:agents_by_id, %{})
        |> assign(:meeting_candidates, [])
        |> assign(:meeting_candidates_closed, [])
        |> assign(:meeting_candidate_events, %{})

      _ ->
        socket
    end
  end

  defp reset_meeting_state(socket) do
    socket
    |> leave_call_shell()
    |> assign(:in_meeting, false)
    |> assign(:speaking_identities, MapSet.new())
    |> assign(:mic_enabled, true)
    |> assign(:camera_enabled, true)
    |> assign(:screen_share_enabled, false)
  end
end
