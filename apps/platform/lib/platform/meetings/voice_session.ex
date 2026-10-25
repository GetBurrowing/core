defmodule Platform.Meetings.VoiceSession do
  @moduledoc """
  The Voice tab's 1:1 spoken conversation with an agent (task 01a1557a-eab7).

  Composes the meetings Ask pipeline; it reimplements none of it. Everything
  is keyed by the user<->agent DM space, so no `Meeting` record is needed:

    * `Chat.find_or_create_dm/3` gives the space;
    * `Meetings.ensure_room/1` gives the LiveKit room `"space-<dm id>"`;
    * `Meetings.invite_agent/4` dispatches the voice worker with
      `"mode" => "voice_1to1"` and the chosen `"voice_context"`;
    * `Meetings.generate_token/2` mints the viewer's token;
    * `AskFloor.claim/6` + `Meetings.ask_floor_window_signal/3` open and close
      the worker's listening window, exactly as the meeting press does.

  ## The room is shared with a DM call on purpose

  A call or quick-meet started in the same DM lands in the same room,
  `"space-<dm id>"`. A DM call with the agent and a Voice-tab session are the
  same 1:1 conversation, so there is deliberately no separate room key.

  The room is not a meeting while only the Voice tab uses it, so LiveKit's
  `room_finished` must not finalize it as one (task 01a174e2: no Meeting
  Summary in the DM). The session therefore says so in the room's config
  (`Meetings.set_session_mode/2`, `"voice_1to1"`), and the webhook skips the
  summary path for a stamped room. The rule, because the room is shared:

    * `start/3` stamps the mode right after `ensure_room/1` (before the token
      and the dispatch, so it lands before LiveKit's `room_started`), UNLESS
      the room's status is `"active"`. Only a human call join sets that
      status, never a voice session, so a live call is never relabelled.
    * `Meetings.join_for_user/3`, the one human call join path, always
      clears the mode: the call wins and is summarized.
    * `room_finished` clears the mode after handling.

  So voice then call is summarized as a call, call then voice is summarized
  as a call, and voice alone produces no summary. A stale stamp left by a
  missed `room_finished` is cleared by the next call join. The transcriber is
  still dispatched (it rides on room creation and a later call in the same
  room needs it); the webhook discards what it recorded for the voice session.

  ## Context

  "No context" or ONE space the viewer participates in. Projects and tasks
  are out of scope. The worker is told on dispatch (`voice_context`) and on
  every change (`set_context/2`, topic `"mva.context"`).

  Only the user's own transcribed turns are posted (`post_transcript/3`);
  agent replies stay on the Voice screen.
  """

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.SpaceAccess
  alias Platform.Meetings
  alias Platform.Meetings.AskFloor
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room

  @default_partner_slug "meeting-assistant"
  @context_topic "mva.context"
  @mode "voice_1to1"

  @type context :: nil | :none | %{required(:id) => binary(), optional(:name) => String.t()}

  @type session :: %{
          space_id: binary(),
          room_name: String.t(),
          token: String.t(),
          livekit_url: String.t() | nil,
          agent_id: binary()
        }

  @doc "The topic `set_context/2` sends on."
  def context_topic, do: @context_topic

  @doc "The dispatch `mode` a voice session's worker is started with."
  def mode, do: @mode

  @doc """
  The default voice partner: the viewer-visible agent with slug
  `"meeting-assistant"` (Burrow), or nil.
  """
  @spec default_partner(map()) :: Agent.t() | nil
  def default_partner(user) do
    user
    |> visible_agents()
    |> Enum.find(&(&1.slug == @default_partner_slug))
  end

  @doc """
  Every agent visible to the viewer, Burrow first, each as
  `%{agent: agent, reachable?: boolean}`. `reachable?` is
  `Meetings.voice_reachable?/1`, the same check `invite_agent/3` refuses on.
  """
  @spec partners(map()) :: [%{agent: Agent.t(), reachable?: boolean()}]
  def partners(user) do
    {burrow, others} =
      user
      |> visible_agents()
      |> Enum.split_with(&(&1.slug == @default_partner_slug))

    Enum.map(burrow ++ others, fn agent ->
      %{agent: agent, reachable?: Meetings.voice_reachable?(agent) == :ok}
    end)
  end

  @doc """
  Start (or rejoin) a voice session between `user` and `agent`.

  Idempotent per (user, agent): the DM and room are found, not recreated, and
  the agent is not dispatched again while its participant row in the room is
  live (a worker actually published, i.e. the row carries a LiveKit
  identity). An invite that never arrived is re-dispatched, the same recovery
  `invite_agent/3` documents.
  """
  @spec start(map(), Agent.t(), context()) ::
          {:ok, session()}
          | {:error, :voice_runtime_offline | :no_runtime | :livekit_not_configured | term()}
  def start(%{id: user_id} = user, %Agent{} = agent, context) do
    with :ok <- Meetings.voice_reachable?(agent),
         {:ok, voice_context} <- normalize_context(user, context),
         {:ok, dm} <- Chat.find_or_create_dm(user_id, "agent", agent.id),
         {:ok, %Room{} = room} <- Meetings.ensure_room(dm.id),
         {:ok, %Room{} = room} <- stamp_session_mode(room),
         {:ok, token} <-
           Meetings.generate_token(room, %{identity: identity(user), name: display_name(user)}),
         :ok <- ensure_agent_dispatched(room, agent, user, voice_context) do
      {:ok,
       %{
         space_id: dm.id,
         room_name: room.livekit_room_name,
         token: token,
         livekit_url: Meetings.livekit_url(),
         agent_id: agent.id
       }}
    end
  end

  @doc """
  Open the agent's listening window: `AskFloor.claim/6` on key
  `"voice:" <> dm_space_id`, then the `:open` room-data signal. A repeat
  press by the identity already holding the floor is a no-op that returns
  the original holder and sends nothing.
  """
  @spec press(session(), map()) :: {:ok, AskFloor.holder()} | {:error, term()}
  def press(%{space_id: space_id, agent_id: agent_id}, user) do
    key = floor_key(space_id)
    identity = identity(user)

    case AskFloor.holder(key, agent_id) do
      {:ok, %{identity: ^identity} = holder} ->
        {:ok, holder}

      _ ->
        with {:ok, holder} <-
               AskFloor.claim(key, agent_id, identity, display_name(user), nil, space_id) do
          :ok = Meetings.ask_floor_window_signal(agent_id, space_id, :open)
          {:ok, holder}
        end
    end
  end

  @doc "Close the listening window opened by `press/2`; mirrors it with `:closed`."
  @spec release(session(), map()) :: :ok | {:error, term()}
  def release(%{space_id: space_id, agent_id: agent_id}, user) do
    with :ok <- AskFloor.release(floor_key(space_id), agent_id, identity(user)) do
      Meetings.ask_floor_window_signal(agent_id, space_id, :closed)
    end
  end

  @doc """
  Tell the live worker the conversation's context changed. Sends RELIABLE
  room data on `"mva.context"`: `{"kind": "space", "id", "name"}` or
  `{"kind": "none", "id": null, "name": null}`.

  `context` must already be resolved (a map with `:id`/`:name`, or nil);
  `start/3` and the caller's own membership check are where it is validated.
  """
  @spec set_context(session(), context()) :: :ok | {:error, term()}
  def set_context(%{room_name: room_name}, context) do
    payload = context |> context_payload() |> Jason.encode!()
    Meetings.send_livekit_room_data(room_name, @context_topic, payload)
  end

  @doc """
  Post the user's own transcribed turn into `context_space_id` as the USER's
  participant, with metadata `%{"source" => "voice"}`. Refuses blank text
  (`{:error, :blank}`) and a space the user cannot write to
  (`{:error, :forbidden}`).
  """
  @spec post_transcript(map(), binary(), String.t() | nil) ::
          {:ok, Chat.Message.t()} | {:error, :blank | :forbidden | term()}
  def post_transcript(user, context_space_id, text) do
    content = if is_binary(text), do: String.trim(text), else: ""

    if content == "" do
      {:error, :blank}
    else
      with {:ok, participant} <- SpaceAccess.authorize_writer(context_space_id, user) do
        Chat.post_message(%{
          space_id: context_space_id,
          participant_id: participant.id,
          content_type: "text",
          content: content,
          metadata: %{"source" => "voice"}
        })
      end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp visible_agents(user), do: Chat.dm_agent_candidates(user, "")

  # A live call ("active") owns the room; see the moduledoc's shared-room rule.
  defp stamp_session_mode(%Room{status: "active"} = room), do: {:ok, room}
  defp stamp_session_mode(%Room{} = room), do: Meetings.set_session_mode(room, @mode)

  defp floor_key(space_id), do: "voice:" <> space_id

  defp identity(%{id: id}), do: "user:" <> id

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{email: email}) when is_binary(email), do: email
  defp display_name(_), do: "User"

  # A live row for this agent (the worker published, so the row carries the
  # LiveKit identity `upsert_live_participant/2` stamps) means the agent is
  # already in the room: do not dispatch a second worker into it.
  defp ensure_agent_dispatched(room, agent, user, voice_context) do
    if agent_live_in_room?(room, agent) do
      :ok
    else
      case Meetings.invite_agent(room, agent, user, mode: @mode, voice_context: voice_context) do
        {:ok, _participant} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp agent_live_in_room?(room, agent) do
    room.id
    |> Meetings.active_participants()
    |> Enum.any?(fn
      %Participant{agent_id: agent_id, metadata: %{"identity" => identity}}
      when is_binary(identity) ->
        agent_id == agent.id

      _ ->
        false
    end)
  end

  defp normalize_context(_user, context) when context in [nil, :none], do: {:ok, nil}

  defp normalize_context(user, %{id: space_id} = context) when is_binary(space_id) do
    case SpaceAccess.authorize_writer(space_id, user) do
      {:ok, _participant} ->
        {:ok, %{"kind" => "space", "id" => space_id, "name" => Map.get(context, :name)}}

      {:error, :forbidden} = error ->
        error
    end
  end

  defp normalize_context(_user, _context), do: {:error, :invalid_context}

  defp context_payload(%{id: id} = context) when is_binary(id),
    do: %{"kind" => "space", "id" => id, "name" => Map.get(context, :name)}

  defp context_payload(_none), do: %{"kind" => "none", "id" => nil, "name" => nil}
end
