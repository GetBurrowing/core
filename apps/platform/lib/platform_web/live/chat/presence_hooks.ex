defmodule PlatformWeb.ChatLive.PresenceHooks do
  @moduledoc """
  Lifecycle hook module for Presence + participant identity in
  `PlatformWeb.ChatLive`.

  See ADR 0035. Presence is cross-cutting — its state feeds almost
  every other feature's render (MessageList, Threads, Mentions, etc.).
  It owns the WRITES; cross-feature READS happen via the shared socket
  assigns (`@participants_map`, `@agent_participant_ids`,
  `@agent_colors_map`, …) and through the template helpers exposed
  here (`sender_name/2`, `avatar_initial/2`, …).

  ## Assigns owned

    * `:space_participants` — raw list of chat participants
    * `:participants_map` — id → identity struct for render
    * `:agent_participant_ids` — MapSet of agent participant ids
    * `:agent_colors_map` — participant id → accent color
    * `:has_agent_participant`
    * `:online_count`
    * `:agent_presence` — native agent presence map (bootable, reachable, …)
    * `:agent_status` — :online | :offline | :thinking | …
    * `:agent_typing_pids` — MapSet of currently-typing agent participant ids

  ## Info handled

    * `{:participant_joined, participant}`
    * `{:participant_left, participant}`
    * `%Phoenix.Socket.Broadcast{event: "presence_diff"}`
    * `:refresh_agent_presence`
    * `{:agent_typing, %{space_id: id, typing: bool, participant_id: id}}`
      — also updates `:composite_status` (owned by ShellLive on_mount);
      this cross-LV write is preserved for compatibility. The `space_id`
      was added for BACKLOG #9: because `ChatLive.mount/3` subscribes to
      every space the user is in (for unread-count updates), typing
      broadcasts from unrelated spaces would otherwise drive the active
      space's "thinking" indicator. Messages whose `space_id` does not
      match `socket.assigns.active_space.id` are dropped here. Older
      broadcasts without `:space_id` are accepted (backwards-compatible)
      so in-flight runtimes don't flicker during rollout.

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
  alias Platform.Chat.SpaceAgentPresence
  alias Platform.Repo

  @agent_presence_refresh_ms 30_000

  @doc "Attach Presence handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:space_participants, [])
    |> assign(:participants_map, %{})
    |> assign(:agent_participant_ids, MapSet.new())
    |> assign(:agent_colors_map, %{})
    |> assign(:online_count, 0)
    |> assign(:agent_presence, default_agent_presence())
    |> assign(:has_agent_participant, false)
    |> assign(:agent_status, :offline)
    |> assign(:agent_typing_pids, MapSet.new())
    |> attach_hook(:presence_info, :handle_info, &handle_info/2)
  end

  @doc "Untrack the current user from a space. Call before navigating away."
  @spec leave_space(Phoenix.LiveView.Socket.t(), binary() | nil) :: Phoenix.LiveView.Socket.t()
  def leave_space(socket, nil), do: socket

  def leave_space(socket, prev_space_id) do
    if connected?(socket) do
      ChatPresence.untrack_in_space(self(), prev_space_id, socket.assigns.user_id)
    end

    socket
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

    if connected?(socket) && participant do
      display_name = resolve_display_name(user_id, participant)

      ChatPresence.track_in_space(self(), space.id, user_id, %{
        display_name: display_name,
        participant_type: "user"
      })
    end

    users_by_id =
      participants
      |> Enum.filter(&(&1.participant_type == "user"))
      |> Enum.map(& &1.participant_id)
      |> Accounts.get_users_map()

    participants_map = build_participant_identity_map(participants, users_by_id)

    agent_participant_ids =
      participants |> Enum.filter(&(&1.participant_type == "agent")) |> MapSet.new(& &1.id)

    agent_colors_map = Chat.agent_color_map_for_participants(participants)
    has_agent_participant = Enum.any?(participants, &(&1.participant_type == "agent"))

    online_count =
      if connected?(socket), do: ChatPresence.online_count(space.id), else: 0

    socket
    |> assign(:space_participants, participants)
    |> assign(:participants_map, participants_map)
    |> assign(:agent_participant_ids, agent_participant_ids)
    |> assign(:agent_colors_map, agent_colors_map)
    |> assign(:has_agent_participant, has_agent_participant)
    |> assign(:online_count, online_count)
    |> assign(:agent_presence, agent_presence)
    |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
    |> assign(:agent_typing_pids, MapSet.new())
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

    {:halt,
     update(socket, :participants_map, fn map ->
       Map.put(map, participant.id, participant_identity(participant, user))
     end)}
  end

  defp handle_info({:participant_left, _participant}, socket), do: {:halt, socket}

  defp handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    online_count =
      case socket.assigns[:active_space] do
        %{id: space_id} -> ChatPresence.online_count(space_id)
        _ -> 0
      end

    {:halt, assign(socket, :online_count, online_count)}
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
    if space_scoped_to_active?(payload, socket) do
      apply_agent_typing(socket, typing, participant_id)
    else
      {:cont, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── handle_info helpers ──────────────────────────────────────────────

  defp space_scoped_to_active?(%{space_id: broadcast_space_id}, socket) do
    case socket.assigns[:active_space] do
      %{id: ^broadcast_space_id} -> true
      _ -> false
    end
  end

  # Backwards-compat: pre-fix broadcasts omit :space_id. Accept them so
  # in-flight runtime processes from before the deploy don't have their
  # typing indicators silently dropped. Every in-repo caller has been
  # updated to include :space_id — this clause exists only for the rolling
  # deploy window and can be removed once federation runtimes are known to
  # have rebooted.
  defp space_scoped_to_active?(_payload, _socket), do: true

  defp apply_agent_typing(socket, typing, participant_id) do
    socket =
      socket
      |> update(:agent_typing_pids, fn pids ->
        if typing, do: MapSet.put(pids, participant_id), else: MapSet.delete(pids, participant_id)
      end)
      |> assign(
        :agent_status,
        if(typing, do: :thinking, else: PlatformWeb.ShellLive.default_agent_status())
      )

    any_typing = not MapSet.equal?(socket.assigns.agent_typing_pids, MapSet.new())

    # Cross-LV write: :composite_status is owned by ShellLive on_mount.
    socket =
      if socket.assigns[:principal_name] do
        if any_typing do
          assign(socket, :composite_status, :busy)
        else
          case socket.assigns[:active_space] do
            %{id: space_id} ->
              composite = SpaceAgentPresence.composite_status_for_space(space_id)
              assign(socket, :composite_status, composite)

            _ ->
              socket
          end
        end
      else
        socket
      end

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
      _ -> author_snapshot_name(msg) || pid || "user"
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

  @doc "Build label for the primary agent when in listening mode."
  def primary_agent_label(%{primary_agent_id: nil}, _participants), do: "Agent"

  def primary_agent_label(%{primary_agent_id: primary_agent_id}, participants) do
    case Enum.find(participants, fn p ->
           p.participant_type == "agent" && p.participant_id == primary_agent_id
         end) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> resolve_agent_name_by_id(primary_agent_id)
    end
  end

  # ── Identity helpers (shared between Presence and other features) ──

  @doc "Build the `participant.id => identity` map used across render regions."
  def build_participant_identity_map(participants, users_by_id) do
    Map.new(participants, fn participant ->
      {participant.id,
       participant_identity(participant, Map.get(users_by_id, participant.participant_id))}
    end)
  end

  @doc "Identity struct for a participant (with optional user for profile data)."
  def participant_identity(participant, user \\ nil)

  def participant_identity(%{participant_type: "agent"} = participant, _user) do
    name = participant.display_name || "Agent"

    %{
      participant_type: "agent",
      name: name,
      display_name: name,
      avatar_url: participant.avatar_url,
      avatar_seed: participant.participant_id || participant.id
    }
  end

  def participant_identity(participant, user) do
    name = participant_name(participant, user)

    %{
      participant_type: "user",
      name: name,
      display_name: name,
      avatar_url: participant.avatar_url || (user && user.avatar_url),
      avatar_seed: participant_avatar_seed(participant, user)
    }
  end

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

  defp participant_avatar_seed(participant, user) do
    cond do
      user && is_binary(user.oidc_sub) && user.oidc_sub != "" ->
        user.oidc_sub

      user && is_binary(user.email) && user.email != "" ->
        user.email

      is_binary(participant.participant_id) && participant.participant_id != "" ->
        participant.participant_id

      is_binary(participant.id) && participant.id != "" ->
        participant.id

      true ->
        "user"
    end
  end

  defp resolve_agent_name_by_id(agent_id) do
    case Repo.get(Platform.Agents.Agent, agent_id) do
      %{name: name} when is_binary(name) -> name
      _ -> "Agent"
    end
  end

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

    case status do
      %{configured?: true, agent: %{}} ->
        if status.pid, do: allow_runtime_sandbox(status.pid)

        unless status.reachable? do
          Task.start(fn -> WorkspaceBootstrap.boot() end)
        end

      _ ->
        Task.start(fn -> WorkspaceBootstrap.boot() end)
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
end
