defmodule PlatformWeb.ChatLive.PresenceHooks do
  @moduledoc """
  Lifecycle hook module for Presence + participant identity in
  `PlatformWeb.ChatLive`.

  See ADR 0035. Presence is cross-cutting — its state feeds almost
  every other feature's render (MessageList, Threads, Mentions, etc.).
  It owns the WRITES; cross-feature READS happen via the shared socket
  assigns (`@participants_map`, `@agent_participant_ids`,
  `@agent_slots_map`, …) and through the template helpers exposed
  here (`sender_name/2`, `avatar_initial/2`, …).

  ## Assigns owned

    * `:space_participants` — raw list of chat participants
    * `:participants_map` — id → identity struct for render
    * `:agent_participant_ids` — MapSet of agent participant ids
    * `:agent_slots_map` — agent participant id → palette slot id, the
      `data-agent-slot` an agent row wears (task 01a1557a rung 3 stage 2)
    * `:has_agent_participant`
    * `:online_count` — count of online participants, or `nil` when presence
      could not be reached (see `:presence_status`)
    * `:presence_status` — `:ok` when the tracker answered, `:unavailable` when
      a guarded read failed. `:unavailable` + a `nil` `:online_count` is the
      honest "we could not ask"; a `0` count would be the different claim that
      nobody is here. Same two-fact distinction `Platform.Chat.Presence`'s
      `safe_*` helpers and `list_online_for_viewer/1` encode, carried one layer
      up — do not introduce a third vocabulary for it.
    * `:agent_presence` — native agent presence map (bootable, reachable, …)
    * `:agent_status` — :online | :offline | :thinking | …
    * `:agent_typing_pids` — MapSet of currently-typing agent participant ids

  ## Info handled

    * `{:participant_joined, participant}`
    * `{:participant_left, participant}`
    * `%Phoenix.Socket.Broadcast{event: "presence_diff"}`
    * `:refresh_agent_presence`
    * `{:agent_typing, %{space_id: id, typing: bool, participant_id: id}}`
      — the `space_id` was added for BACKLOG #9: because `ChatLive.mount/3` subscribes to
      every space the user is in (for unread-count updates), typing
      broadcasts from unrelated spaces would otherwise drive the active
      space's "thinking" indicator. Messages whose `space_id` does not
      match `socket.assigns.active_space.id` are dropped here, and so is
      a payload carrying no `:space_id` at all — the predicate fails
      closed. (A rolling-deploy shim accepted keyless payloads until
      2026-08-18; see the comment on `space_scoped_to_active?/2`.)

  ## Usage

      # In ChatLive.mount/3:
      socket = PlatformWeb.ChatLive.PresenceHooks.attach(socket)

      # In ChatLive.handle_params/3, before the space changes:
      socket = PlatformWeb.ChatLive.PresenceHooks.leave_space(socket, prev_space_id)

      # After the new space is resolved:
      socket = PlatformWeb.ChatLive.PresenceHooks.enter_space(
        socket, space, participant, participants
      )
  """

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts
  alias Platform.Agents.WorkspaceBootstrap
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo
  alias PlatformWeb.ChatLive.MeetingHooks
  alias PlatformWeb.ChatLive.MessagesHooks

  @agent_presence_refresh_ms 30_000

  @doc "Attach Presence handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:space_participants, [])
    |> assign(:participants_map, %{})
    |> assign(:agent_participant_ids, MapSet.new())
    |> assign(:agent_slots_map, %{})
    |> assign(:online_count, 0)
    |> assign(:presence_status, :ok)
    |> assign(:agent_presence, default_agent_presence())
    |> assign(:has_agent_participant, false)
    |> assign(:agent_status, :offline)
    |> assign(:agent_typing_pids, MapSet.new())
    # M10 (presence/typing scope, rbac-external-users): the allowlisted set of
    # space_ids an EXTERNAL user may receive presence/typing for. `nil` means
    # internal / no-restriction (the common case) — the consumer guards below
    # short-circuit to today's behavior on nil, so no internal session
    # regresses. Seeded here at mount (before any presence_diff / agent_typing
    # can arrive) so the guards are armed for the whole session, not only after
    # the first `enter_space/4`.
    |> assign(:external_scope_space_ids, external_scope_for(socket.assigns[:user_id]))
    # `ShellLive` halts every `presence_diff` for views that do not ask for
    # it; this one does, because the Members sheet re-reads presence on each
    # diff (task 01a1557a-8f80 stage 3).
    |> assign(:presence_diff_downstream?, true)
    |> attach_hook(:presence_info, :handle_info, &handle_info/2)
  end

  # M10: compute the external presence/typing scope for a mounting user. An
  # internal user (or the anonymous/generated session id) yields `nil` — no
  # restriction. An external user yields a `MapSet` of the spaces they are a
  # chat_participant of. Reuses `Platform.Tenancy.external_user?/1` (M1) as the
  # single external predicate — this stage does NOT redefine it.
  defp external_scope_for(user_id) when is_binary(user_id) do
    if Platform.Tenancy.external_user?(%{id: user_id}) do
      ChatPresence.external_scope_space_ids(user_id)
    else
      nil
    end
  end

  defp external_scope_for(_user_id), do: nil

  @doc "Untrack the current user from a space. Call before navigating away."
  @spec leave_space(Phoenix.LiveView.Socket.t(), binary() | nil) :: Phoenix.LiveView.Socket.t()
  def leave_space(socket, nil), do: socket

  def leave_space(socket, prev_space_id) do
    # Call site 4 of 4: navigate-away. A dead tracker must not take the
    # LiveView down on the way out of a space either.
    if connected?(socket) do
      case ChatPresence.safe_untrack_in_space(self(), prev_space_id, socket.assigns.user_id) do
        :ok -> socket
        {:error, _reason} -> mark_presence_unavailable(socket)
      end
    else
      socket
    end
  end

  # The single writer of the `:presence_status` / `:online_count` pair. A
  # guarded read that failed means we could not ask, which is NOT the same
  # fact as a count of zero — so the count becomes `nil`, never `0`.
  defp mark_presence_unavailable(socket) do
    socket
    |> assign(:presence_status, :unavailable)
    |> assign(:online_count, nil)
  end

  @doc """
  Enter a space — track presence, (re)build participant maps, load the
  native agent presence, and schedule the refresh timer. Returns the
  updated socket with all Presence-owned assigns populated.

  `participants` is the pre-loaded list of `Chat.list_participants/1`;
  the parent already needs this list for other reasons, so we accept
  it rather than re-querying.
  """
  @spec enter_space(Phoenix.LiveView.Socket.t(), map(), map() | nil, [map()]) ::
          Phoenix.LiveView.Socket.t()
  def enter_space(socket, space, participant, participants) do
    user_id = socket.assigns.user_id
    agent_presence = ensure_native_agent_presence(space.id)

    # M10: an external user must not surface in the presence roster of a space
    # that is not in their allowlisted scope, even if they somehow reached it as
    # active_space. `space_in_external_scope?/2` is `true` for internal (nil
    # scope) sessions, so this only ever narrows external users — no regression.
    # Call site 1 of 4: the mount-path track. This is the crash this task is
    # filed for — an unguarded tracker call here took down every chat route.
    track_result =
      if connected?(socket) && participant && space_in_external_scope?(socket, space.id) do
        display_name = resolve_display_name(user_id, participant)

        ChatPresence.safe_track_in_space(self(), space.id, user_id, %{
          display_name: display_name,
          participant_type: "user"
        })
      else
        :skipped
      end

    # Explicit archived-user override (task 019f671f Stage 3): the
    # `enter_space` participant map is the identity source for EVERY
    # currently-rendered chat message, including historical messages whose
    # author has since been archived. Without `include_archived: true` the
    # default `Accounts.get_users_map/1` (Stage 1) would drop the archived
    # user, leaving `sender_name/2` to fall back to the ADR 0038 author
    # snapshot ("User" for pre-snapshot rows). Mirror `Platform.Org.Context`
    # / `resolve_authors/1` semantics from Stage 2 — historical attribution
    # MUST resolve. Attention routing suppression for archived users is
    # handled one layer up in `AttentionRouter.route/1`.
    users_by_id =
      participants
      |> Enum.filter(&(&1.participant_type == "user"))
      |> Enum.map(& &1.participant_id)
      |> Accounts.get_users_map(include_archived: true)

    # Agent avatars live on the `agents` row, not on the participant row, so
    # they are resolved here and threaded into the identity map. Built once
    # per presence rebuild — see `build_participant_identity_map/3`.
    agent_avatars_map = Chat.agent_avatar_map_for_participants(participants)

    participants_map =
      build_participant_identity_map(participants, users_by_id, agent_avatars_map)

    agent_participant_ids =
      participants |> Enum.filter(&(&1.participant_type == "agent")) |> MapSet.new(& &1.id)

    agent_slots_map = Chat.agent_slot_map_for_participants(participants)
    has_agent_participant = Enum.any?(participants, &(&1.participant_type == "agent"))

    # Call site 2 of 4: the same exposure one line later, hit on every mount.
    count_result =
      if connected?(socket), do: ChatPresence.safe_online_count(space.id), else: {:ok, 0}

    {presence_status, online_count} =
      case {track_result, count_result} do
        {{:error, _}, _} -> {:unavailable, nil}
        {_, {:error, _}} -> {:unavailable, nil}
        {_, {:ok, count}} -> {:ok, count}
      end

    socket
    |> assign(:space_participants, participants)
    |> assign(:participants_map, participants_map)
    |> assign(:agent_participant_ids, agent_participant_ids)
    |> assign(:agent_slots_map, agent_slots_map)
    |> assign(:has_agent_participant, has_agent_participant)
    |> assign(:online_count, online_count)
    |> assign(:presence_status, presence_status)
    |> assign(:agent_presence, agent_presence)
    |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
    |> assign(:agent_typing_pids, MapSet.new())
    |> reinsert_rendered_messages(space.id)
    |> schedule_refresh()
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_info({:participant_joined, participant}, socket) do
    user =
      if participant.participant_type == "user" do
        Accounts.get_user(participant.participant_id)
      else
        nil
      end

    # An agent seated mid-session isn't in the mount-time avatar snapshot, so
    # resolve just this one row rather than leaving it faceless until the next
    # presence rebuild. Users don't need this — their avatar comes off the
    # `%User{}` loaded directly above.
    agent_avatars =
      if participant.participant_type == "agent" do
        Chat.agent_avatar_map_for_participants([participant])
      else
        %{}
      end

    {:halt,
     socket
     |> update(:participants_map, fn map ->
       Map.put(map, participant.id, participant_identity(participant, user, agent_avatars))
     end)
     |> reinsert_rendered_messages(MessagesHooks.active_space_id(socket))
     |> refresh_members_panel()}
  end

  # The viewer's OWN removal continues down the chain; everybody else's stops
  # here. This hook owns the roster render and has nothing to do on a leave
  # either way — the roster is rebuilt from the DB on the next presence pass —
  # but ChatLive owns the subscription lifecycle (task 01a0181f) and its
  # release clause cannot see an event this hook halts.
  defp handle_info({:participant_left, %{participant_type: "user"} = participant}, socket) do
    socket = refresh_members_panel(socket)

    if participant.participant_id == socket.assigns[:user_id],
      do: {:cont, socket},
      else: {:halt, socket}
  end

  defp handle_info({:participant_left, _participant}, socket),
    do: {:halt, refresh_members_panel(socket)}

  defp handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    if external_active_out_of_scope?(socket) do
      # M10: external session whose active_space is NOT in the allowlisted
      # scope — drop the diff without recomputing online_count. Belt-and-
      # suspenders behind the stage-2 subscribe filter (which should already
      # keep this topic off the process); the count is left untouched.
      {:halt, socket}
    else
      # Call site 3 of 4: the same failure after mount rather than during it.
      # A tracker that dies under an already-mounted LiveView must degrade the
      # count, not kill the process on the first diff.
      result =
        case socket.assigns[:active_space] do
          %{id: space_id} -> ChatPresence.safe_online_count(space_id)
          _ -> {:ok, 0}
        end

      socket =
        case result do
          {:ok, count} -> socket |> assign(:online_count, count) |> assign(:presence_status, :ok)
          {:error, _reason} -> mark_presence_unavailable(socket)
        end

      # Any diff on any subscribed space can move a person between online and
      # away (online means anywhere the viewer can see), so the open Members
      # sheet re-reads rather than patching one space's slice.
      {:halt, refresh_members_panel(socket)}
    end
  end

  defp handle_info(:refresh_agent_presence, socket) do
    case socket.assigns[:active_space] do
      %{id: space_id} ->
        agent_presence = ChatPresence.native_agent_presence(space_id)

        {:halt,
         socket
         |> assign(:agent_presence, agent_presence)
         |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
         |> schedule_refresh()}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_info(
         {:agent_typing, %{typing: typing, participant_id: participant_id} = payload},
         socket
       ) do
    # The quickmeet rail's fold runs HERE, before the scope decision: this
    # hook is attached before `MeetingHooks` and halts below for the
    # active space, so a `MeetingHooks` clause would never see the one
    # broadcast a quickmeet actually cares about (task 01a05b14 stage 5,
    # round 2). Self-guarding — a no-op on any socket that is not in a
    # quickmeet bound to `payload.space_id`.

    socket = MeetingHooks.apply_agent_typing(socket, payload)

    if space_scoped_to_active?(payload, socket) and typing_in_external_scope?(payload, socket) do
      apply_agent_typing(socket, typing, participant_id)
    else
      {:cont, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # Re-render every currently-rendered chat-message row so they pick up
  # the new participants_map / agent_slots_map / agent_participant_ids.
  # Phoenix LiveView streams don't auto-re-render existing rows when a
  # parent assign changes (only stream_insert/delete triggers a re-render),
  # so without this call the rows would silently keep their stale author
  # chip / color / membership data. See task 019e245b audit and
  # 019e273f Stage 4.
  #
  # The `:rendered_message_ids` MapSet is maintained by MessagesHooks
  # (Stage 3 of 019e273f); empty MapSet → no DB call, safe no-op for
  # call sites that fire before the chat is mounted.
  #
  # `space_id` is REQUIRED and is the space whose stream is being written.
  # The MapSet carries no space of its own, so on a space switch it still
  # holds the previous space's ids when `enter_space/4` runs — this hook
  # fires one line before the loader resets the stream, so those rows would
  # land in the new space's DOM and survive the reset (task 01a0119e).
  # `enter_space/4` passes the space it was handed rather than reading
  # `:active_space` back off the socket, so re-ordering the switch pipeline
  # cannot resurrect the defect.
  defp reinsert_rendered_messages(socket, space_id) do
    ids = socket.assigns[:rendered_message_ids] || MapSet.new()
    MessagesHooks.reinsert_stream_messages(socket, MapSet.to_list(ids), space_id: space_id)
  end

  # ── handle_info helpers ──────────────────────────────────────────────

  defp space_scoped_to_active?(%{space_id: broadcast_space_id}, socket) do
    case socket.assigns[:active_space] do
      %{id: ^broadcast_space_id} -> true
      _ -> false
    end
  end

  # Fail closed on a payload we cannot scope. The rolling-deploy shim that
  # used to `do: true` here (78cd3248, 2026-05-01) accepted a :space_id-less
  # payload from ANY topic this session subscribes to — and chat_live
  # subscribes one session to every space in the sidebar — so it inverted the
  # convention every other scope predicate follows. Its own stated removal
  # condition (federation runtimes rebooted) is met: all six in-repo
  # constructions of `{:agent_typing, …}` build the map literally with
  # `space_id:`, and RuntimeChannel never forwards a runtime-supplied payload
  # map, so no sender core can see — internal or external — can produce one.
  defp space_scoped_to_active?(_payload, _socket), do: false

  # ── M10 external presence/typing scope guards ────────────────────────
  #
  # All three predicates treat a `nil` scope (internal / no-restriction) as
  # "always allowed", so internal sessions keep today's behavior exactly. Only
  # an external session (scope is a `MapSet`) is narrowed.

  # `presence_diff`: true when this is an external session whose active_space is
  # NOT in the allowlisted scope, i.e. the diff must be dropped. Public
  # (`@doc false`) only so the scope decision is unit-testable without a full
  # LiveView — same convention as `apply_agent_typing/3` above.
  @doc false
  def external_active_out_of_scope?(socket) do
    case socket.assigns[:external_scope_space_ids] do
      nil ->
        false

      %MapSet{} = scope ->
        case socket.assigns[:active_space] do
          %{id: space_id} -> not MapSet.member?(scope, space_id)
          _ -> false
        end
    end
  end

  # `{:agent_typing, …}`: for an external session, the broadcast only applies
  # when its `:space_id` is in the allowlisted scope. A payload with no
  # `:space_id` (pre-fix rolling-deploy broadcast) cannot be verified, so an
  # external session drops it (fail-closed). Internal (nil) always passes.
  # Public (`@doc false`) for unit testing only.
  @doc false
  def typing_in_external_scope?(payload, socket) do
    case socket.assigns[:external_scope_space_ids] do
      nil ->
        true

      %MapSet{} = scope ->
        case payload do
          %{space_id: space_id} -> MapSet.member?(scope, space_id)
          _ -> false
        end
    end
  end

  # `enter_space/4` presence write: only track an external user into a space
  # that is in their allowlisted scope. Internal (nil) always tracks. Public
  # (`@doc false`) for unit testing only.
  @doc false
  def space_in_external_scope?(socket, space_id) do
    case socket.assigns[:external_scope_space_ids] do
      nil -> true
      %MapSet{} = scope -> MapSet.member?(scope, space_id)
    end
  end

  # Public for unit-test access. Not part of the public API; called only from
  # the `{:agent_typing, …}` `handle_info` clause above.
  @doc false
  def apply_agent_typing(socket, typing, participant_id) do
    socket =
      socket
      |> update(:agent_typing_pids, fn pids ->
        if typing, do: MapSet.put(pids, participant_id), else: MapSet.delete(pids, participant_id)
      end)
      |> assign(
        :agent_status,
        if(typing, do: :thinking, else: PlatformWeb.ShellLive.default_agent_status())
      )

    {:halt, socket}
  end

  # ── Template helpers (used across MessageList, Threads, Mentions) ────

  @doc """
  Display name for a participant.

  Accepts either a bare participant id (legacy — used by search and typing
  indicators) or a message struct. For a message, the live participant map
  is preferred so renames propagate; the author snapshot (ADR 0038) is the
  fallback when the participant is no longer in the space (dismissed).
  """
  def sender_name(participants_map, %{participant_id: pid} = msg) do
    case Map.get(participants_map, pid) do
      %{name: name} when is_binary(name) and name != "" -> name
      name when is_binary(name) and name != "" -> name
      _ -> author_snapshot_name(msg)
    end
  end

  def sender_name(participants_map, participant_id) do
    case Map.get(participants_map, participant_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      name when is_binary(name) and name != "" -> name
      _ -> "User"
    end
  end

  @doc "Avatar URL for a participant or message (nil if none)."
  def sender_avatar_url(participants_map, %{participant_id: pid} = msg) do
    case Map.get(participants_map, pid) do
      %{avatar_url: avatar_url} when is_binary(avatar_url) -> avatar_url
      _ -> author_snapshot_avatar_url(msg)
    end
  end

  def sender_avatar_url(participants_map, participant_id) do
    case Map.get(participants_map, participant_id) do
      %{avatar_url: avatar_url} when is_binary(avatar_url) -> avatar_url
      _ -> nil
    end
  end

  @doc "Deterministic seed for the dicebear avatar."
  def sender_avatar_seed(participants_map, %{participant_id: pid} = msg) do
    case Map.get(participants_map, pid) do
      %{avatar_seed: avatar_seed} when not is_nil(avatar_seed) -> avatar_seed
      %{name: name} when is_binary(name) and name != "" -> name
      name when is_binary(name) and name != "" -> name
      _ -> author_snapshot_name(msg)
    end
  end

  def sender_avatar_seed(participants_map, participant_id) do
    case Map.get(participants_map, participant_id) do
      %{avatar_seed: avatar_seed} when not is_nil(avatar_seed) -> avatar_seed
      %{name: name} when is_binary(name) and name != "" -> name
      name when is_binary(name) and name != "" -> name
      _ -> participant_id || "user"
    end
  end

  defp author_snapshot_name(%{author_display_name: name})
       when is_binary(name) and name != "",
       do: name

  defp author_snapshot_name(_), do: "User"

  defp author_snapshot_avatar_url(%{author_avatar_url: url})
       when is_binary(url) and url != "",
       do: url

  defp author_snapshot_avatar_url(_), do: nil

  @doc "Single-letter initial for an avatar. Accepts id or message struct."
  def avatar_initial(participants_map, participant_or_message) do
    sender_name(participants_map, participant_or_message)
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "U"
      ch -> String.upcase(ch)
    end
  end

  @doc "Comma-joined display names of currently-typing agents."
  def thinking_label(pids, participants_map) do
    pids
    |> MapSet.to_list()
    |> Enum.map(&sender_name(participants_map, &1))
    |> Enum.join(" & ")
  end

  # `primary_agent_label/2` used to live here. Its only caller was the dimmed
  # "{primary} listening" hint in the chat header, deleted in task 019f9790
  # stage 4 along with the other two competing agent controls; the eye that
  # replaced them went in task 01a1557a-8f80 stage 2 (the Agents sheet). The
  # primary is a roster @mention-eligibility role, never a default responder.
  # Its private helper `resolve_agent_name_by_id/1` went with it (no other
  # callers).

  # ── Identity helpers (shared between Presence and other features) ──

  @doc """
  Build the `participant.id => identity` map used across render regions.

  `agent_avatars` is the `participant.id => avatar_url` map from
  `Chat.agent_avatar_map_for_participants/1`. Agent avatars are NOT stored on
  the participant row, so they have to arrive here from the `agents` table;
  see that function for why the column is not backfilled.

  CACHING: this map is a snapshot taken when presence is (re)built — at mount,
  and again whenever the participant list changes. An agent whose avatar is
  changed mid-session keeps showing the old URL to already-connected viewers
  until the next rebuild. That is deliberate and safe: the stored URL carries
  a `?v=` cache token, so a stale map can only serve a stale *snapshot*, never
  a broken link or the wrong agent's face.
  """
  def build_participant_identity_map(participants, users_by_id, agent_avatars \\ %{}) do
    Map.new(participants, fn participant ->
      {participant.id,
       participant_identity(
         participant,
         Map.get(users_by_id, participant.participant_id),
         agent_avatars
       )}
    end)
  end

  @doc "Identity struct for a participant (with optional user for profile data)."
  def participant_identity(participant, user \\ nil, agent_avatars \\ %{})

  def participant_identity(%{participant_type: "agent"} = participant, _user, agent_avatars) do
    name = agent_participant_name(participant)

    %{
      participant_type: "agent",
      name: name,
      display_name: name,
      # The underlying principal id (agent_id). rbac-external-users M5 stage 4
      # reads this so the @-mention filter can reason about the participant by
      # identity; agents are dropped wholesale on the external surface anyway.
      principal_id: participant.participant_id || participant.id,
      # Resolved from the `agents` row, not from `chat_participants.avatar_url`
      # — nothing writes that column for agent rows, so reading it here would
      # be a structurally-guaranteed nil. Absent from the map means "no
      # avatar", which is `nil` (never ""), so the render layer falls back to
      # the single-initial `agent_avatar/1` glyph.
      avatar_url: Map.get(agent_avatars, participant.id),
      avatar_seed: participant.participant_id || participant.id,
      # Agents are never "archived" in the user-lifecycle sense — the flag
      # exists so the Mentions autocomplete filter can be a single map-lookup
      # across user AND agent entries without needing to check
      # `participant_type` first. See task 019f671f validation 1(c) —
      # archived users must NOT appear in @-mention autocomplete, but agents
      # (and the here sentinel) must remain reachable.
      archived: false
    }
  end

  def participant_identity(participant, user, _agent_avatars) do
    name = participant_name(participant, user)

    %{
      participant_type: "user",
      name: name,
      display_name: name,
      # The underlying principal id (user_id). rbac-external-users M5 stage 4
      # reads this so the @-mention filter can check `external_dm_permitted?/3`
      # against the mentioned human — mention scope == DM scope == enforcement.
      principal_id: participant.participant_id,
      avatar_url: participant.avatar_url || (user && user.avatar_url),
      avatar_seed: participant_avatar_seed(participant, user),
      # `participants_map` intentionally still contains archived users so
      # historical messages authored by them render with their real display
      # name (task 019f671f Stage 3 explanatory comment in `enter_space/4`).
      # This flag lets downstream consumers that must NOT surface archived
      # users (mention autocomplete — task 019f671f validation 1(c))
      # reject them without losing the identity for render.
      archived: user_archived?(user)
    }
  end

  # `chat_participants.display_name` is a denormalised cache and is nullable, so
  # a row written by a caller that skipped it renders as the literal "Agent" —
  # in the roster, in presence, and in the @-mention autocomplete, which then
  # offers "Agent" as the only thing you can insert.
  #
  # Fall back to the `agents` row before the literal. The lookup only fires for
  # a blank cache, which the write-side resolution in
  # `Platform.Chat.do_add_participant/2` plus the NULL backfill migration make
  # rare — so this is not an N+1 on the normal path, it is a repair path that
  # should idle at zero queries. "Agent" survives only as the last resort for a
  # participant whose principal no longer exists.
  defp agent_participant_name(participant) do
    case participant.display_name do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        Chat.agent_principal_name(Map.get(participant, :participant_id)) || "Agent"
    end
  end

  defp user_archived?(%{archived_at: %DateTime{}}), do: true
  defp user_archived?(_), do: false

  defp participant_name(%{name: name}, _user) when is_binary(name) and name != "", do: name

  defp participant_name(%{resolved_name: name}, _user) when is_binary(name) and name != "",
    do: name

  defp participant_name(%{display_name: name}, _user) when is_binary(name) and name != "",
    do: name

  defp participant_name(_participant, %{name: name}) when is_binary(name) and name != "", do: name

  defp participant_name(_participant, %{email: email}) when is_binary(email) and email != "",
    do: email

  defp participant_name(_participant, _user), do: "User"

  defp participant_avatar_seed(%{avatar_seed: seed}, _user) when not is_nil(seed), do: seed

  # The cond lives in `Platform.Avatars.user_seed/2` (task 01a12773) so the
  # push notification's `author_avatar_tone` colours a person exactly as the
  # chat does.
  defp participant_avatar_seed(participant, user),
    do: Platform.Avatars.user_seed(participant, user)

  defp resolve_display_name(user_id, participant) do
    participant.display_name || name_for_user(user_id)
  end

  defp name_for_user(user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "User"
    end
  end

  # ── Agent presence bootstrap ─────────────────────────────────────────

  # Bootstrap the native agent's *runtime* on LV mount — sandbox plumbing
  # and a boot kick if unreachable. Does NOT add the agent as a space
  # participant; that is an explicit act (DM creation, admin action, or
  # @-mention per ADR 0038). Auto-adding here is what caused Higgins to
  # reappear after every dismissal.
  defp ensure_native_agent_presence(space_id) do
    status = WorkspaceBootstrap.status()

    # Task 01a089e5 stage 3: both branches were a bare `Task.start` — see
    # `WorkspaceBootstrap.boot_async/1` for why this now runs under
    # `Platform.TaskSupervisor`.
    case status do
      %{configured?: true, agent: %{}} ->
        if status.pid, do: allow_runtime_sandbox(status.pid)

        unless status.reachable? do
          WorkspaceBootstrap.boot_async()
        end

      _ ->
        WorkspaceBootstrap.boot_async()
    end

    ChatPresence.native_agent_presence(space_id)
  end

  defp schedule_refresh(socket) do
    if connected?(socket) && socket.assigns[:active_space] do
      Process.send_after(self(), :refresh_agent_presence, @agent_presence_refresh_ms)
    end

    socket
  end

  def default_agent_presence do
    %{
      configured?: false,
      bootable?: false,
      reachable?: false,
      running?: false,
      workspace_path: nil,
      agent_slug: nil,
      agent_name: nil,
      agent: nil,
      pid: nil,
      error: nil,
      joined?: false,
      participant: nil,
      indicator: :missing
    }
  end

  defp allow_runtime_sandbox(pid) when is_pid(pid) do
    if sandbox_pool?() do
      case Sandbox.allow(Repo, self(), pid) do
        :ok -> :ok
        {:already, :owner} -> :ok
        {:already, :allowed} -> :ok
        _other -> :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp allow_runtime_sandbox(_pid), do: :ok

  defp sandbox_pool? do
    case Repo.config()[:pool] do
      Sandbox -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # The Members sheet (task 01a1557a-8f80 stage 3) lists the roster from the
  # DB and presence from `Chat.space_member_presence/2`, so a join, a leave or
  # a presence diff re-reads it while it is open. Another admin's add in a
  # second window lands here too. Both surfaces refresh: the phone sheet and
  # the desktop popover are two instances of the one component.
  defp refresh_members_panel(socket) do
    if socket.assigns[:show_members] do
      for id <- PlatformWeb.ChatLive.MembersComponent.instance_ids() do
        Phoenix.LiveView.send_update(PlatformWeb.ChatLive.MembersComponent, id: id, refresh: true)
      end
    end

    socket
  end
end
