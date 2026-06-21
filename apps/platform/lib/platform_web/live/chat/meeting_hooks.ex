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

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [attach_hook: 4, push_event: 3, connected?: 1, get_connect_params: 1]

  alias Platform.Accounts
  alias Platform.Meetings
  alias Platform.Meetings.Membership, as: MeetingsMembership
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.State, as: MeetingState

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

  defp handle_event(_event, _params, socket), do: {:cont, socket}

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

  defp handle_info(_msg, socket), do: {:cont, socket}

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
      assign(socket, :meeting_participants, meeting_participants(space_id))
    else
      socket
    end
  end

  defp active_space_id(socket) do
    case socket.assigns[:active_space] do
      %{id: id} -> id
      _ -> nil
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
        |> assign(:meeting_participants, meeting_participants(space.id))
        |> push_event("join-meeting", %{
          token: token,
          url: Meetings.livekit_url(),
          room_name: room.livekit_room_name,
          space_slug: space.slug
        })

      # Meeting slug for deep-linking the mini-bar's Return-to-call: prefer
      # the live `meetings` row's slug; fall back to the space slug if no
      # Meeting row exists yet (room came up via raw LiveKit, no DB row).
      meeting_slug =
        case Meetings.get_live_meeting_for_space(space.id) do
          %{slug: slug} when is_binary(slug) -> slug
          _ -> space.slug
        end

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
      {:error, reason} ->
        Logger.warning("[ChatLive] meeting_join failed: #{inspect(reason)}")
        socket

      nil ->
        socket

      _ ->
        socket
    end
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

  defp reset_meeting_state(socket) do
    socket
    |> assign(:in_meeting, false)
    |> assign(:mic_enabled, true)
    |> assign(:camera_enabled, true)
    |> assign(:screen_share_enabled, false)
  end
end
